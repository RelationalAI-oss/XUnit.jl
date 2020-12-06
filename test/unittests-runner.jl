module UnitTests

using Distributed
using Base.Filesystem
@everywhere using Pkg
@everywhere Pkg.activate(joinpath(@__DIR__, "..", "..", ".."))
@everywhere Pkg.instantiate()
@everywhere using XUnit

function run_unittests()
    local tests_exception = nothing
    prev_TESTSET_PRINT_ENABLE = XUnit.TESTSET_PRINT_ENABLE[]
    XUnit.TESTSET_PRINT_ENABLE[] = false
    try
        XUnit.runtests(joinpath(@__DIR__, "unittests.jl"))
    catch e
        # swallow the error
        # @error "XUnit Tests Progress" exception=e
    finally
        XUnit.TESTSET_PRINT_ENABLE[] = prev_TESTSET_PRINT_ENABLE
    end

    @testsuite "unittests tests" begin
        @test isdefined(Main, :XUNIT_UNITTEST_RESULTS)

        test_results = Main.XUNIT_UNITTEST_RESULTS[]

        @test test_results !== nothing

        @test test_results isa XUnit.AsyncTestSuite

        passes, fails, errors, broken, c_passes, c_fails, c_errors, c_broken =
            XUnit._swallow_all_outputs() do
                XUnit.get_test_counts(test_results)
            end
        @test passes == 0
        @test fails == 0
        @test errors == 0
        @test broken == 0
        @test c_passes == 55
        @test c_fails == 11
        @test c_errors == 4
        @test c_broken == 0
    end

    nothing
end

run_unittests()

end
