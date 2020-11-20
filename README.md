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

`XUnit.jl` allows to organize your tests hierarchically.

There are two concepts used for creating your test hierarchy:
 - `test-suite`: is used for grouping other `test-suite`s and `test-case`s. It is important that a `test-suite` doesn't contain any code related to specific tests directly in its body. You can create a `test-suite` using `@testset` and `@testsuite` macros.
 - `test-case`: is used for declaring a unit-test. You can think of `test-case`s as leaves of your test hierarchy. You can create a `test-case` using `@testcase` macro.

Executing the tests using `XUnit.jl` happens in two phases:
 - Scheduling: when Julia processes test hierarchy macros (`@testsuite` and `@testcase`), it doesn't immediately runs them. Instead, it output a representation of the `test-suite`.
 - Running: After scheduling the tests, you have the choice of running the tests using a `test-runner`. Each `test-runner` has a different strategy for running the tests (explained below).

`XUnit.jl` rewrites/re-exports `@testset` and `@test*` macros provided by `Base.Test` (and you need to use these macros directly from `XUnit` instead of `Test`).

In addition, there are two more macros provided:

 - `@testsuite`: is used for grouping other `@testsuite`s and `@testcase`s. This macro schedules the `@testsuite`s and `@testcase`s in its body (but does not run them). It is important that a `@testsuite` doesn't contain any code related to specific tests directly in its body. For backward compatibility with `Base.Test`, `@testset` is very similar to `@testsuite` with a distinction that a top-level `@testset` (if not included inside a `@testsuite`) also runs all the scheduled tests sequentially. This deferred execution of test-cases is a big differentiator between `XUnit.jl` and `Base.Test`. Even though you can drop-in replace `XUnit.jl` with `Base.Test`, but we strongly recommend also replace your topmost `@testset` with `@testsuite` to benefit from deferred execution in different modes (i.e., shuffled, parallel, or distributed). This is done in the example below.
 - `@testcase`: is used for encapsulate a `test-case`. You can think of `@testcase`s as leaves of your test hierarchy. The body of an `@testcase` is not executed right away. Instead, it gets scheduled for being executed later.

 **Note**: it's suggested that `@testcase`s become the leaf nodes of your test hierarchy. Even though, for now, you can have other `@testset`s, `@testsuite`s or even `@testcase`s under a `@testcase`, where in this case, all those are considered the same (like a `@testset`) and will only impact the reporting, but won't have any impact on the execution of the tests, as still the top-most `@testcase` gets scheduled for deferred execution.

**Note**:the body of a `@testsuite` always gets executed at scheduling time, as it
needs to gather possible underlying `@testcase`s. Thus, it's a good practice to put your
tests under a `@testcase` (instead of putting them under a `@testsuite`), as any tests
defined under a `@testsuite` are executed sequentially at scheduling time.

After scheduling the tests (which happens by capturing the output value of the topmost `@testsuite`), you can run the tests using `run_testsuite`, where you pass your desired test-runner as the first argument and your scheduled tests as the second argument. Here are the current test runners:
 - `SequentialTestRunner`: this is the default test-runner, which behaves similarly to `Base.Test` and runs all your tests sequentially using a single thread of execution.
 - `ShuffledTestRunner`: similar to `SequentialTestRunner`, it runs the tests using a single thread of execution, but it shuffles them and runs them in random order.
 - `ParallelTestRunner`: runs your tests in parallel using multiple threads of execution. It runs the tests with all available Julia threads. Please refer to the [Julia documentation](https://docs.julialang.org/en/v1/manual/multi-threading/#Starting-Julia-with-multiple-threads) to know about the possible ways to start Julia with multiple threads.

In the end, the test results are printed to the standard output (similar to `Base.Test`), but you can also get the XUnit/JUnit style of test reports (in `XML` format) by using the `xml_report!(testsuite)` function. After calling this function on your test-suite, the results are available in a file determined by the `xml_output(testsuite)` function.

Here is an example that tries to show the above explanations in practice:

```julia
using XUnit

testsuite = @testsuite "Top Parent" begin
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

# run_testsuite(SequentialTestRunner, testsuite)
# run_testsuite(ShuffledTestRunner, testsuite)
run_testsuite(ParallelTestRunner, testsuite)
xml_report!(testsuite)
run(`open ./$(xml_output(testsuite))`)
```

Sample output:

```julia
Running Top XParent ABC tests...
  Running Top XParent ABC/XTest 1 tests...
    Scheduling Top XParent ABC/XTest 1/Child XTest 1 XYZ tests...
    Running Top XParent ABC/XTest 1/Child XTest 2 tests...
      Running Top XParent ABC/XTest 1/Child XTest 2/Grand Child XTest Suite 2-10 tests...
        Scheduling Top XParent ABC/XTest 1/Child XTest 2/Grand Child XTest Suite 2-10/Grand Grand Child XTest Case 2-10-1 tests...
      Scheduling Top XParent ABC/XTest 1/Child XTest 2/Grand Child XTest Case 2-11 XYZ tests...
    Scheduling Top XParent ABC/XTest 1/Child XTest 3 tests...
  Running Top XParent ABC/XTest 2 tests...
    Scheduling Top XParent ABC/XTest 2/Child XTest 4 tests...
    Scheduling Top XParent ABC/XTest 2/Child XTest 5 tests...
    Scheduling Top XParent ABC/XTest 2/Child XTest 12 tests...
  Running Top XParent ABC/XTest 3 tests...
    Running Top XParent ABC/XTest 3/Child XTest 3 tests...
      Scheduling Top XParent ABC/XTest 3/Child XTest 3/Child XTest 3-1 tests...
      Scheduling Top XParent ABC/XTest 3/Child XTest 3/Child XTest 3-2 tests...
      Running Top XParent ABC/XTest 3/Child XTest 3/Child XTest 3-3 tests...
      Scheduling Top XParent ABC/XTest 3/Child XTest 3/Child XTest 3-4 tests...
  Running Top XParent ABC/XTest 4 tests...
    Running Top XParent ABC/XTest 4/Child XTest 4-1 tests...
      Scheduling Top XParent ABC/XTest 4/Child XTest 4-1/Child XTest 4-1-1 tests...
    Scheduling Top XParent ABC/XTest 4/Child XTest 6 tests...
-> Running Top XParent ABC/XTest 4/Child XTest 6 test-case (on tid=1)...
-> Running Top XParent ABC/XTest 4/Child XTest 4-1/Child XTest 4-1-1 test-case (on tid=1)...
-> Running Top XParent ABC/XTest 3/Child XTest 3/Child XTest 3-4 test-case (on tid=1)...
         >>>> before_each -> Child XTest 3-2, extra_p, global_p
-> Running Top XParent ABC/XTest 3/Child XTest 3/Child XTest 3-2 test-case (on tid=1)...
         >>>> before_each -> Child XTest 3-2, extra_p, global_p
-> Running Top XParent ABC/XTest 3/Child XTest 3/Child XTest 3-1 test-case (on tid=1)...
         >>>> before_each -> Child XTest 3-2, extra_p, global_p
        Running Top XParent ABC/XTest 3/Child XTest 3/Child XTest 3-1/Grand Child XTest 3-1-1 tests...
-> Running Top XParent ABC/XTest 2/Child XTest 12 test-case (on tid=1)...
-> Running Top XParent ABC/XTest 2/Child XTest 5 test-case (on tid=1)...
-> Running Top XParent ABC/XTest 2/Child XTest 4 test-case (on tid=1)...
-> Running Top XParent ABC/XTest 1/Child XTest 3 test-case (on tid=1)...
         >>>> before_each -> Child XTest 1, extra_p, global_p
-> Running Top XParent ABC/XTest 1/Child XTest 1 XYZ test-case (on tid=1)...
         >>>> before_each -> Child XTest 1, extra_p, global_p
-> Running Top XParent ABC/XTest 1/Child XTest 2/Grand Child XTest Case 2-11 XYZ test-case (on tid=1)...
         >>>> before_each -> Child XTest 1, extra_p, global_p
-> Running Top XParent ABC/XTest 1/Child XTest 2/Grand Child XTest Suite 2-10/Grand Grand Child XTest Case 2-10-1 test-case (on tid=1)...
         >>>> before_each -> Child XTest 1, extra_p, global_p
          Running Top XParent ABC/XTest 1/Child XTest 2/Grand Child XTest Suite 2-10/Grand Grand Child XTest Case 2-10-1/Grand^3 Child XTest Case 2-10-1-1 tests...
            Running Top XParent ABC/XTest 1/Child XTest 2/Grand Child XTest Suite 2-10/Grand Grand Child XTest Case 2-10-1/Grand^3 Child XTest Case 2-10-1-1/Grand^4 Child XTest Case 2-10-1-1-4 tests...
              Running Top XParent ABC/XTest 1/Child XTest 2/Grand Child XTest Suite 2-10/Grand Grand Child XTest Case 2-10-1/Grand^3 Child XTest Case 2-10-1-1/Grand^4 Child XTest Case 2-10-1-1-4/Grand^5 Child XTest Case 2-10-1-1-4-6 tests...
                Running Top XParent ABC/XTest 1/Child XTest 2/Grand Child XTest Suite 2-10/Grand Grand Child XTest Case 2-10-1/Grand^3 Child XTest Case 2-10-1-1/Grand^4 Child XTest Case 2-10-1-1-4/Grand^5 Child XTest Case 2-10-1-1-4-6/Grand^6 Child XTest Case 2-10-1-1-4-6-9 tests...
                  Running Top XParent ABC/XTest 1/Child XTest 2/Grand Child XTest Suite 2-10/Grand Grand Child XTest Case 2-10-1/Grand^3 Child XTest Case 2-10-1-1/Grand^4 Child XTest Case 2-10-1-1-4/Grand^5 Child XTest Case 2-10-1-1-4-6/Grand^6 Child XTest Case 2-10-1-1-4-6-9/Grand^7 Child XTest Case 2-10-1-1-4-6-9-3 tests...
Child XTest 2: Test Failed at ./XUnit/test/unittests.jl:31
  Expression: 33 == 32
   Evaluated: 33 == 32
Grand Grand Child XTest Case 2-10-1: Test Failed at ./XUnit/test/unittests.jl:36
  Expression: 331 == 321
   Evaluated: 331 == 321
Grand^3 Child XTest Case 2-10-1-1: Test Failed at ./XUnit/test/unittests.jl:41
  Expression: 3311 == 3211
   Evaluated: 3311 == 3211
Grand^4 Child XTest Case 2-10-1-1-4: Test Failed at ./XUnit/test/unittests.jl:45
  Expression: 33114 == 32114
   Evaluated: 33114 == 32114
Grand^5 Child XTest Case 2-10-1-1-4-6: Test Failed at ./XUnit/test/unittests.jl:49
  Expression: 331146 == 321146
   Evaluated: 331146 == 321146
Grand^6 Child XTest Case 2-10-1-1-4-6-9: Test Failed at ./XUnit/test/unittests.jl:53
  Expression: 3311469 == 3211469
   Evaluated: 3311469 == 3211469
Grand^7 Child XTest Case 2-10-1-1-4-6-9-3: Test Failed at ./XUnit/test/unittests.jl:58
  Expression: 33114693 == 32114693
   Evaluated: 33114693 == 32114693
Grand Child XTest Case 2-11 XYZ: Test Failed at ./XUnit/test/unittests.jl:69
  Expression: 332 == 322
   Evaluated: 332 == 322
Child XTest 3: Test Failed at ./XUnit/test/unittests.jl:78
  Expression: 2 * 2 == 5
   Evaluated: 4 == 5
Child XTest 3: Error During Test at ./XUnit/test/unittests.jl:79
  Test threw exception
  Expression: fn_throws()
  KeyError: key "Test error!" not found
  Stacktrace:
   [1] fn_throws() at ./XUnit/test/unittests.jl:6
   [2] macro expansion at ./XUnit/test/unittests.jl:79 [inlined]
   [3] (::Main.UnitTests.var"#13#40")() at ./XUnit/src/XUnit.jl:458
   [4] run_single_testcase(::Array{XUnit.AsyncTestSuite,1}, ::XUnit._AsyncTestCase{XUnit.AsyncTestSuite}) at ./XUnit/src/test-runners.jl:208
   [5] macro expansion at ./XUnit/src/test-runners.jl:113 [inlined]
   [6] (::XUnit.var"#29#threadsfor_fun#17"{Array{XUnit.ScheduledTest,1},Base.Threads.Atomic{Int64},Bool,Nothing,UnitRange{Int64}})(::Bool) at ./threadingconstructs.jl:81
   [7] (::XUnit.var"#29#threadsfor_fun#17"{Array{XUnit.ScheduledTest,1},Base.Threads.Atomic{Int64},Bool,Nothing,UnitRange{Int64}})() at ./threadingconstructs.jl:48

Child XTest 4: Test Failed at ./XUnit/test/unittests.jl:89
  Expression: fn_nothrows()
    Expected: KeyError
  No exception thrown
Child XTest 12: Test Failed at ./XUnit/test/unittests.jl:100
  Expression: 1212 == 1212 * 2
   Evaluated: 1212 == 2424
Child XTest 3-1: Error During Test at ./XUnit/test/unittests.jl:108
  Got exception outside of a @test
  AssertionError: 5 == 9
  Stacktrace:
   [1] macro expansion at ./XUnit/test/unittests.jl:116 [inlined]
   [2] (::Main.UnitTests.var"#22#49")() at ./XUnit/src/XUnit.jl:458
   [3] run_single_testcase(::Array{XUnit.AsyncTestSuite,1}, ::XUnit._AsyncTestCase{XUnit.AsyncTestSuite}) at ./XUnit/src/test-runners.jl:208
   [4] macro expansion at ./XUnit/src/test-runners.jl:113 [inlined]
   [5] (::XUnit.var"#29#threadsfor_fun#17"{Array{XUnit.ScheduledTest,1},Base.Threads.Atomic{Int64},Bool,Nothing,UnitRange{Int64}})(::Bool) at ./threadingconstructs.jl:81
   [6] (::XUnit.var"#29#threadsfor_fun#17"{Array{XUnit.ScheduledTest,1},Base.Threads.Atomic{Int64},Bool,Nothing,UnitRange{Int64}})() at ./threadingconstructs.jl:48

Child XTest 3-2: Error During Test at ./XUnit/test/unittests.jl:124
  Test threw exception
  Expression: fn_throws()
  KeyError: key "Test error!" not found
  Stacktrace:
   [1] fn_throws() at ./XUnit/test/unittests.jl:6
   [2] macro expansion at ./XUnit/test/unittests.jl:124 [inlined]
   [3] (::Main.UnitTests.var"#24#51")() at ./XUnit/src/XUnit.jl:458
   [4] run_single_testcase(::Array{XUnit.AsyncTestSuite,1}, ::XUnit._AsyncTestCase{XUnit.AsyncTestSuite}) at ./XUnit/src/test-runners.jl:208
   [5] macro expansion at ./XUnit/src/test-runners.jl:113 [inlined]
   [6] (::XUnit.var"#29#threadsfor_fun#17"{Array{XUnit.ScheduledTest,1},Base.Threads.Atomic{Int64},Bool,Nothing,UnitRange{Int64}})(::Bool) at ./threadingconstructs.jl:81
   [7] (::XUnit.var"#29#threadsfor_fun#17"{Array{XUnit.ScheduledTest,1},Base.Threads.Atomic{Int64},Bool,Nothing,UnitRange{Int64}})() at ./threadingconstructs.jl:48

Child XTest 4-1-1: Error During Test at ./XUnit/test/unittests.jl:145
  Test threw exception
  Expression: fn_throws()
  KeyError: key "Test error!" not found
  Stacktrace:
   [1] fn_throws() at ./XUnit/test/unittests.jl:6
   [2] macro expansion at ./XUnit/test/unittests.jl:145 [inlined]
   [3] (::Main.UnitTests.var"#28#55")() at ./XUnit/src/XUnit.jl:458
   [4] run_single_testcase(::Array{XUnit.AsyncTestSuite,1}, ::XUnit._AsyncTestCase{XUnit.AsyncTestSuite}) at ./XUnit/src/test-runners.jl:208
   [5] macro expansion at ./XUnit/src/test-runners.jl:113 [inlined]
   [6] (::XUnit.var"#29#threadsfor_fun#17"{Array{XUnit.ScheduledTest,1},Base.Threads.Atomic{Int64},Bool,Nothing,UnitRange{Int64}})(::Bool) at ./threadingconstructs.jl:81
   [7] (::XUnit.var"#29#threadsfor_fun#17"{Array{XUnit.ScheduledTest,1},Base.Threads.Atomic{Int64},Bool,Nothing,UnitRange{Int64}})() at ./threadingconstructs.jl:48

Test Summary:                                               | Pass  Fail  Error  Total
Top XParent ABC                                             |   53    11      4     68
  XTest 1                                                   |   26     9      1     36
    Child XTest 2                                           |   19     8            27
      Grand Child XTest Suite 2-10                          |   12     6            18
        Grand Grand Child XTest Case 2-10-1                 |   12     6            18
          Grand^3 Child XTest Case 2-10-1-1                 |   10     5            15
            Grand^4 Child XTest Case 2-10-1-1-4             |    8     4            12
              Grand^5 Child XTest Case 2-10-1-1-4-6         |    6     3             9
                Grand^6 Child XTest Case 2-10-1-1-4-6-9     |    4     2             6
                  Grand^7 Child XTest Case 2-10-1-1-4-6-9-3 |    2     1             3
      Grand Child XTest Case 2-11 XYZ                       |    5     1             6
    Child XTest 1 XYZ                                       |    3                   3
    Child XTest 3                                           |    4     1      1      6
  XTest 2                                                   |   10     2            12
    Child XTest 4                                           |    5     1             6
    Child XTest 5                                           |    3                   3
    Child XTest 12                                          |    2     1             3
  XTest 3                                                   |   12            2     14
    Child XTest 3                                           |   12            2     14
      Child XTest 3-3                                       |    3                   3
      Child XTest 3-1                                       |    3            1      4
        Grand Child XTest 3-1-1                             |    3                   3
      Child XTest 3-2                                       |    3            1      4
      Child XTest 3-4                                       |    3                   3
  XTest 4                                                   |    5            1      6
    Child XTest 4-1                                         |    2            1      3
      Child XTest 4-1-1                                     |    2            1      3
    Child XTest 6                                           |    3                   3
Test results in HTML format: test-results.xml.html
```

## Contributing
Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.

Please make sure to update the tests as appropriate.

## License
[MIT](https://choosealicense.com/licenses/mit/)

## Authors

- [Mohammad Dashti](mailto:mohammad.dashti[at]relational[dot]ai)
- [Todd J. Green](mailto:todd.green[at]relational[dot]ai)
