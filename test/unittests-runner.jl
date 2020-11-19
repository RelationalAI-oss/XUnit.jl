module UnitTests

using Distributed
@everywhere using Pkg
@everywhere Pkg.activate(joinpath(@__DIR__, "..", "..", ".."))
@everywhere Pkg.instantiate()
@everywhere using XUnit

XUnit.runtests(joinpath(@__DIR__, "unittests.jl"))


nothing

end
