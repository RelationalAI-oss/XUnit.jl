module MySubDir1Tests

using Random
using XUnit
import ..MacroDefMod

@testcase "subdir1-test1" begin
    include("subdir1-include.jl")
end

MacroDefMod.@my_testcase "subdir1-test2" begin
    include("subdir1-include.jl")
end

end
