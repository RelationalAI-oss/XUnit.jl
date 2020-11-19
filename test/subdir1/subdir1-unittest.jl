using Random

@testcase "subdir1-test1" begin
    include("subdir1-include.jl")
end

@my_testcase "subdir1-test2" begin
    include("subdir1-include.jl")
end
