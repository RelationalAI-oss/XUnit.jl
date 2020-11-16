module UnitTests

using XUnit

function fn_throws()
    throw(KeyError("Test error!"))
end

function fn_nothrows()
    return nothing
end

global_param = "global_p"
extra_param_value = "extra_p"

before_each_fn_gen(fn_name, extra_param=extra_param_value) = () -> println("         >>>> before_each -> $fn_name, $extra_param, $global_param")
after_each_fn_gen(fn_name, extra_param=extra_param_value) = () -> println("         >>>> after_each -> $fn_name, $extra_param, $global_param")

function schedule_tests()
    topname = "ABC"
    bottomname = "XYZ"
    @testsuite "Top XParent $topname" begin
        @testset "XTest 1" before_each=before_each_fn_gen("Child XTest 1") begin
            @testcase "Child XTest 1 $bottomname" begin
                @test 1 == 1
                @test 2 == 2
                @test 3 == 3
            end
            @testset "Child XTest 2" begin
                @test 22 == 22
                @test 33 == 32
                @test 44 == 44
                @testset "Grand Child XTest Suite 2-10" begin
                    @testcase "Grand Grand Child XTest Case 2-10-1" begin
                        @test 221 == 221
                        @test 331 == 321
                        @test 441 == 441

                        @testset "Grand^3 Child XTest Case 2-10-1-1" begin
                            @test 2211 == 2211
                            @test 3311 == 3211
                            @test 4411 == 4411
                            @testset "Grand^4 Child XTest Case 2-10-1-1-4" begin
                                @test 22114 == 22114
                                @test 33114 == 32114
                                @test 44114 == 44114
                                @testcase "Grand^5 Child XTest Case 2-10-1-1-4-6" begin
                                    @test 221146 == 221146
                                    @test 331146 == 321146
                                    @test 441146 == 441146
                                    @testset "Grand^6 Child XTest Case 2-10-1-1-4-6-9" begin
                                        @test 2211469 == 2211469
                                        @test 3311469 == 3211469
                                        @test 4411469 == 4411469

                                        @testset "Grand^7 Child XTest Case 2-10-1-1-4-6-9-3" begin
                                            @test 22114693 == 22114693
                                            @test 33114693 == 32114693
                                            @test 44114693 == 44114693
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
                @testcase "Grand Child XTest Case 2-11 $bottomname" begin
                    @test 222 == 222
                    @test 332 == 322
                    @test 442 == 442
                    include("sub-unittests.jl")
                end
            end
            @testcase "Child XTest 3" begin
                test_println("You should only see me as part of Child XTest 3 output!")
                @test 4 == 4
                @test 5 == 5
                @test 2 * 2 == 5
                @test fn_throws()
                @test 9 == 9
                @test 10 == 10
            end
        end
        @testset "XTest 2" begin
            @testcase "Child XTest 4" begin
                @test 6 == 6
                @test 7 == 7
                @test_throws KeyError fn_throws()
                @test_throws KeyError fn_nothrows()
                @test 8 == 8
                @test 11 == 11
            end
            @testcase "Child XTest 5" begin
                @test 11 == 11
                @test 12 == 12
                @test 13 == 13
            end
            @testcase "Child XTest 12" begin
                @test 1211 == 1211
                @test 1212 == 1212 * 2
                @test 1213 == 1213
            end
        end
        @testset "XTest 3" begin
            @testset "Child XTest 3" xxx=2 before_each=() -> begin
                before_each_fn_gen("Child XTest 3-2")()
            end begin
                @testcase "Child XTest 3-1" begin
                    x = 31
                    y = 52
                    @testset "Grand Child XTest 3-1-1" begin
                        @test x == 31
                        @test y == 52
                        @test x + y == 31 + 52
                    end
                    @assert 5 == 9
                    @test x == 31
                    @test 32 == 32
                    @test y == 33
                end
                @testcase "Child XTest 3-2" begin
                    @test 36 == 36
                    @test 37 == 37
                    @test fn_throws()
                    @test 38 == 38
                end
                @testset "Child XTest 3-3" begin
                    m = 31
                    n = 52
                    @test m == 31
                    @test n == 52
                    @test m + n == 31 + 52
                end
                @testcase "Child XTest 3-4" begin
                    @test 41 == 41
                    @test 42 == 42
                    @test 43 == 43
                end
            end
        end
        @testset "XTest 4" begin
            @testset "Child XTest 4-1" begin
                @testcase "Child XTest 4-1-1" begin
                    @test 4111 == 4111
                    @test fn_throws()
                    @test 4113 == 4113
                end
            end
            @testcase "Child XTest 6" begin
                @test 31 == 31
                @test 32 == 32
                @test 33 == 33
            end
        end
    end
end

function run_tests_and_report()
    XUnit.TESTSET_PRINT_ENABLE[] = true
    println("Running tests with $(Threads.nthreads()) threads")
    testsuite = schedule_tests()
    # run_testsuite(SequentialTestRunner, testsuite)
    # run_testsuite(ShuffledTestRunner, testsuite)
    run_testsuite(ParallelTestRunner, testsuite)
    html_report!(testsuite; show_stdout=XUnit.TESTSET_PRINT_ENABLE[])
    run(`open ./$(html_output(testsuite))`)
end

run_tests_and_report()

nothing

end
