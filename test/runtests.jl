module XUnitTests

using XUnit, Distributed, Random
using XUnit: guardseed, ReportingTestSet

import Logging: Debug, Info, Warn

include("base-tests.jl")
include("regex-tests.jl")

end
