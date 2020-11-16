# XUnit.jl

`XUnit.jl` is a unit-testing framework for Julia.

It is a drop-in replacement for the test macros of `Base.Test` supporting:
* Basic progress indication
* The ability to
  * run tests sequentially
  * run tests in shuffled mode (sequentially, in random order)
  * run tests in parallel mode (using multiple threads)
  * run tests in distributed mode (using multiple processes)
  * run only a subset of test sets
* XUnit/JUnit style of reporting test results

## Installation

```julia
using Pkg
Pkg.add("XUnit")
```

## Usage

In addition to `@testset` and `@test*` macros provided by `Base.Test` (which were also re-exported from this package), there are two more macros provided:
- `@testsuite`: is very similar to `@testset`, but it does not run the leaf test-cases, but only schedules them. On the contrary, `@testset` does the same, except that the top-level `@testset` (if not included inside a `@testsuite`) also runs all the scheduled tests sequentially. This deferred execution of test-cases is a big differentiator between `XUnit.jl` and `Base.Test`. Even though you can drop-in replace `XUnit.jl` with `Base.Test`, but we strongly recommend also replace your topmost `@testset` with `@testsuite` to benefit from deferred execution in different modes (i.e., shuffled, parallel, or distributed). This is done in the example below.
- `@testcase`: is also very similar to `@testset` (and `@testsuite`), but the body of an `@testcase` is not executed right away. Instead, it gets scheduled for being executed later. As its name suggests, it's meant to encapsulate a test-case. It's suggested that `@testcase`s become the leaf nodes of your test hierarchy. Even though, for now, you can have other `@testset`s, `@testsuite`s or even `@testcase`s under a `@testcase`, where in this case, all those are considered the same (like a `@testset`) and will only impact the reporting, but won't have any impact on the execution of the tests, as still the top-most `@testcase` gets scheduled for deferred execution.

After scheduling the tests (which happens by capturing the output value of the topmost `@testsuite`), you can run the tests using `run_testsuite`, where you pass your desired test-runner as the first argument and your scheduled tests as the second argument. Here are the current test runners:
 - `SequentialTestRunner`: this is the default test-runner, which behaves similarly to `Base.Test` and runs all your tests sequentially using a single thread of execution.
 - `ShuffledTestRunner`: similar to `SequentialTestRunner`, it runs the tests using a single thread of execution, but it shuffles them and runs them in random order.
 - `ParallelTestRunner`: runs your tests in parallel using multiple threads of execution. It runs the tests with all available Julia threads. Please refer to the [Julia documentation](https://docs.julialang.org/en/v1/manual/multi-threading/#Starting-Julia-with-multiple-threads) to know about the possible ways to start Julia with multiple threads.

In the end, the test results are printed to the standard output (similar to `Base.Test`), but you can also get the XUnit/JUnit style of test reports (in `XML` format) by using the `xml_report!(testsuite)` function. After calling this function on your test-suite, the results are available in a file determined by the `xml_output(testsuite)` function.

Here is an example that tries to show the above explanations in practice:

```julia
using XUnit

function schedule_tests()
    @testsuite "Top Parent" begin
        @testset "XTest 1" begin
            @testcase "Child XTest 1" begin
                @test 1 == 1
                @test 2 == 2
                @test 3 == 3
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
            @testset "Child XTest 3" begin
                @testcase "Child XTest 3-1" begin
                    x = 31
                    y = 52
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
            end
        end
    end
end

testsuite = schedule_tests()
# run_testsuite(SequentialTestRunner, testsuite)
# run_testsuite(ShuffledTestRunner, testsuite)
run_testsuite(ParallelTestRunner, testsuite)
xml_report!(testsuite)
run(`open ./$(xml_output(testsuite))`)
```

## Contributing
Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.

Please make sure to update the tests as appropriate.

## License
[MIT](https://choosealicense.com/licenses/mit/)

## Authors

- [Mohammad Dashti](mailto:mohammad.dashti[at]relational[dot]ai)
- [Todd J. Green](mailto:todd.green[at]relational[dot]ai)
