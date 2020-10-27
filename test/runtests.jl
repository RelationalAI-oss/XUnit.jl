module Runtests

# ====================
# Testing the partial regex implementation in XUnit
module RegexTests
using Test  # For testing the behavior
import XUnit  # The behavior to test

@testset "partial regexes" begin
    date_re = XUnit.partial(raw"^\d\d-\d\d-\d\d\d\d")  # DD-MM-YYYY Date specifier

    # Full match
    @test XUnit.pmatch(date_re, "22-02-20") !== nothing
    # Partial matches
    @test XUnit.pmatch(date_re, "22-02") !== nothing
    @test XUnit.pmatch(date_re, "22-") !== nothing
    # Non-matches
    @test XUnit.pmatch(date_re, "-2") === nothing
    @test XUnit.pmatch(date_re, "-22-") === nothing
    @test XUnit.pmatch(date_re, "") === nothing
end
end
# ====================

using XUnit

function test()
    @testset "t" begin
        for ch in ["a","b","c"]
            @testset "$ch" begin
                @test 1==1
                for i in 1:3
                    @testset "$i" begin
                        @test 1==1
                        @test_broken 0==1
                    end
                end
            end
        end
    end
end

function closure(expected::Vector{String})
    cl = Set{String}()
    for path in expected
        segs = split(path, "/")
        s = ""
        first = true
        for seg in segs
            if first
                s = seg
                first = false
            else
                s = s*"/"*seg
            end
            push!(cl, s)
        end
    end
    sort(collect(cl))
end

function case(str::String, test::Function, depth::Int64,
        expected::Vector{String}, args...)
    println(str)
    println("======")
    state = runtests(test, depth, args...)
    println()
    seen = sort(collect(keys(filter(kv -> kv.second, state.seen))))
    expected = sort(closure(expected))
    @test seen == expected
    state
end

case(str::String, test::Function, expected::Vector{String}, args...) =
    case(str, test, typemax(Int64), expected, args...)

@testset "XUnit" begin
    case("Run all tests", test,
        [ "t/a/1", "t/a/2", "t/a/3",
          "t/b/1", "t/b/2", "t/b/3",
          "t/c/1", "t/c/2", "t/c/3" ]
    )

    case("Run everything under 't/a'", test,
        [ "t/a/1", "t/a/2", "t/a/3" ],
         "t/a/.*"
    )

    # "Run 'a/2'"
    case("Run 't/a/2'", test,
        [ "t/a/2" ],
         "t/a/2")

    # "Run 'a/2' and 'b/3'"
    case("Run 't/a/2' and 't/b/3'", test,
        [ "t/a/2", "t/b/3" ],
        "t/a/2", "t/b/3")

    # "Run all except 'b/2' and 'b/3'"
    case("Run all except 't/b/2' and 't/b/3'", test,
        [ "t/a/1", "t/a/2", "t/a/3",
          "t/b/1",
          "t/c/1", "t/c/2", "t/c/3" ],
        "¬t/b/2", "-t/b/3")

    # "Print names of top-level test sets"
    case("Show top-level test sets", test, 2,
        [ "t/a", "t/b", "t/c" ]
    )

    # "Print names of top-level and second-level test sets"
    case("Print names of top-level and second-level test sets", test, 3,
        [ "t/a/1", "t/a/2", "t/a/3",
          "t/b/1", "t/b/2", "t/b/3",
          "t/c/1", "t/c/2", "t/c/3" ]
    )
end

end
