const XUNIT_UNITTEST_RESULTS = Ref{Any}(nothing)

module XUnitTests

using Distributed
@everywhere using Pkg
@everywhere Pkg.activate(joinpath(@__DIR__, "..", "..", ".."))
@everywhere Pkg.instantiate()
@everywhere using XUnit, Distributed, Random
@everywhere using XUnit: guardseed, ReportingTestSet

using XUnit, Distributed, Random
using XUnit: guardseed, ReportingTestSet

import Logging: Debug, Info, Warn

include("unittests-runner.jl")
if VERSION.major == 1 && VERSION.minor == 5
    # The Base.Test tests are expected to only work on Julia 1.5
    include("base-tests.jl")
end
include("regex-tests.jl")

@testset "ENV variable" begin
    @test  !haskey(ENV, "XUNIT_RUNTESTS")
    XUnit.runtests("test_env_variable.jl")
    @test  !haskey(ENV, "XUNIT_RUNTESTS")
end

end
