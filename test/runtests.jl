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
include("base-tests.jl")
include("regex-tests.jl")

end
