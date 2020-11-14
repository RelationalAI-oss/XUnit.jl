module XUnit

import Test
using Test: AbstractTestSet, Result, Fail, Broken, Pass, Error
using Test: get_testset_depth, get_testset
import TestReports: display_reporting_testset
using TestReports
using Random
using Base.Threads
using EzXML

const Option{T} = Union{Nothing,T}

abstract type TestMetrics end

# BEGIN AsyncTestSuite and AsyncTestCase

mutable struct AsyncTestCase
    testset_report::AbstractTestSet
    parent_testsuite#::Option{AsyncTestSuiteOrTestCase}
    test_fn::Function
    source::LineNumberNode
    disabled::Bool
    sub_testsuites::Vector#{AsyncTestSuite}
    sub_testcases::Vector{AsyncTestCase}
    modify_lock::ReentrantLock
    metrics::Option{TestMetrics}
end

struct AsyncTestSuite
    testset_report::AbstractTestSet
    parent_testsuite#::Option{AsyncTestSuiteOrTestCase}
    before_each_hook::Function
    sub_testsuites::Vector{AsyncTestSuite}
    sub_testcases::Vector{AsyncTestCase}
    after_each_hook::Function
    disabled::Bool
    modify_lock::ReentrantLock
    source::LineNumberNode
    metrics::Option{TestMetrics}
end

const AsyncTestSuiteOrTestCase = Union{AsyncTestSuite,AsyncTestCase}

function AsyncTestSuite(
    testset_report::AbstractTestSet,
    source::LineNumberNode,
    parent_testsuite::Option{AsyncTestSuiteOrTestCase}=nothing;
    before_each::Function = () -> nothing,
    sub_testsuites::Vector{AsyncTestSuite} = AsyncTestSuite[],
    sub_testcases::Vector{AsyncTestSuite} = AsyncTestSuite[],
    after_each::Function = () -> nothing,
    disabled::Bool = false,
    metrics = nothing,
)
    metrics_instance = create_test_metrics(parent_testsuite, metrics)

    instance = AsyncTestSuite(
        testset_report,
        parent_testsuite,
        before_each,
        sub_testsuites,
        sub_testcases,
        after_each,
        disabled,
        ReentrantLock(),
        source,
        metrics_instance,
    )
    if parent_testsuite !== nothing
        lock(parent_testsuite.modify_lock) do
            push!(parent_testsuite.sub_testsuites, instance)
        end
    end
    return instance
end

function AsyncTestCase(
    test_fn::Function,
    testset_report::AbstractTestSet,
    parent_testsuite::Option{AsyncTestSuiteOrTestCase},
    source::LineNumberNode;
    disabled::Bool=false,
    metrics = nothing,
)
    metrics_instance = create_test_metrics(parent_testsuite, metrics)

    instance = AsyncTestCase(
        testset_report,
        parent_testsuite,
        test_fn,
        source,
        disabled,
        AsyncTestSuite[],
        AsyncTestCase[],
        ReentrantLock(),
        metrics_instance,
    )
    if parent_testsuite !== nothing
        lock(parent_testsuite.modify_lock) do
            push!(parent_testsuite.sub_testcases, instance)
        end
    end
    return instance
end

include("test_metrics.jl")

function clear_test_reports!(testsuite::AsyncTestSuite)
    rich_ts = testsuite.testset_report
    rich_ts.reporting_test_set[] = ReportingTestSet(rich_ts.description)

    clear_test_reports!.(testsuite.sub_testsuites)
    clear_test_reports!.(testsuite.sub_testcases)
end

function clear_test_reports!(testcase::AsyncTestCase)
    rich_ts = testcase.testset_report
    clear_test_reports!.(testsuite.sub_testsuites)
    clear_test_reports!.(testsuite.sub_testcases)
    rich_ts.reporting_test_set[] = ReportingTestSet(rich_ts.description)
end

const TEST_SUITE_PARAMETER_NAMES = (
    Expr(:quote, :before_each),
    Expr(:quote, :after_each),
    Expr(:quote, :metrics),
)

const TEST_CASE_PARAMETER_NAMES = (
    Expr(:quote, :metrics),
)

html_output(testsuite::AsyncTestSuite) = html_output(testsuite.testset_report)
html_output(testcase::AsyncTestCase) = html_output(testcase.testset_report)
xml_output(testsuite::AsyncTestSuite) = xml_output(testsuite.testset_report)
xml_output(testcase::AsyncTestCase) = xml_output(testcase.testset_report)

function html_report!(
    testsuite::AsyncTestSuite;
    show_stdout::Bool=Test.TESTSET_PRINT_ENABLE[],
)
    return html_report!(testsuite.testset_report; show_stdout=show_stdout)
end

function xml_report!(
    testsuite::AsyncTestSuite;
    show_stdout::Bool=Test.TESTSET_PRINT_ENABLE[],
)
    return xml_report!(testsuite.testset_report; show_stdout=show_stdout)
end

function TestReports.display_reporting_testset(testsuite::AsyncTestSuite)
    TestReports.display_reporting_testset(testsuite.testset_report)
end

# END AsyncTestSuite and AsyncTestCase

include("rich-reporting-testset.jl")
include("test_runners.jl")
include("test_filter.jl")

# BEGIN XUnitState

"""
State maintained during a test run, consisting of a stack of strings
for the nested `@testset`s, a maximum depth beyond which we skip `@testset`s,
and a pair of regular expressions over `@testset` nestings used to decide
which `@testset`s should be executed.  We also keep a record of tests run or
skipped so that these can be reported at the end of the test run.
"""
struct XUnitState
    test_suites_stack::Vector{AsyncTestSuiteOrTestCase}
    stack::Vector{String}
    maxdepth::Int
    include::Regex
    exclude::Regex
    seen::Dict{String,Bool}
end

"""
This function works similar to Base.deepcopy.

We saw some failures by applying `Base.deepcopy` on `RichReportingTestSet` and
`ReportingTestSet`. That's why this function is added to have more control over the impl.
"""
function create_deep_copy end
create_deep_copy(x) = deepcopy(x)

function create_deep_copy(ts::XUnitState)::XUnitState
    return XUnitState(
        map(create_deep_copy, ts.test_suites_stack),
        copy(ts.stack),
        ts.maxdepth,
        ts.include,
        ts.exclude,
        copy(ts.seen)
    )
end

function open_testset(rs::XUnitState, name::String)
    push!(rs.stack, name)
    join(rs.stack, "/")
end

function close_testset(rs::XUnitState)
    pop!(rs.stack)
end

const ⊤ = r""       # matches any string
const ⊥ = r"(?!)"   # matches no string

XUnitState() = XUnitState([], [], typemax(Int64), ⊤, ⊥, Dict{String,Bool}())

XUnitState(maxdepth::Int, include::Regex, exclude::Regex) =
   XUnitState([], [], maxdepth, include, exclude, Dict{String,Bool}())

function initialize_xunit_state(tls)
    added_tls = false
    rs = if haskey(tls, :__XUNIT_STATE__)
        tls[:__XUNIT_STATE__]
    else
        added_tls = true
        val = XUnitState()
        tls[:__XUNIT_STATE__] = val
        val
    end
    return added_tls, rs
end

function finalize_xunit_state(tls, added_tls)
    added_tls && delete!(tls, :__XUNIT_STATE__)
end

# END XUnitState

# Enumeration of all possible macro types
@enum SuiteType TestSuiteType TestCaseType TestSetType

# BEGIN TestSuite

"""
Schedules a Test Suite

Please note that `@testset` and `@testsuite` macros are very similar.
The only difference is the top-level `@testset` also runs the test-cases, but a top-level
`@testsuite` does not run its underlying test-cases (and only schedules them).
Then, one needs to explicitly call `run_testsuite` over the result of this macro.

Also, note that the body of a `@testsuite` always gets executed at scheduling time, as it
needs to gather possible underlying `@testcase`s. Thus, it's a good practice to put your
tests under a `@testcase` (instead of putting them under a `@testsuite`), as all the tests
defined under a `@testsuite` are executed sequentially at scheduling time.

`@testsuite` takes two additional parameters:
  - `beofre_each`: a function to run before each underlying test-case
  - `after_each`: a function to run after each underlying test-case
"""
macro testsuite(args...)
    isempty(args) && error("No arguments to @testsuite")

    tests = args[end]

    # Determine if a single block or for-loop style
    if !isa(tests, Expr) || tests.head !== :block
        error("Expected begin/end block or for loop as argument to @testsuite")
    end

    return testsuite_beginend(args, tests, __source__, TestSuiteType)
end

"""
Generate the code for a `@testsuite` with a `begin`/`end` argument
"""
function testsuite_beginend(args, tests, source, suite_type::SuiteType)
    is_testcase = suite_type == TestCaseType
    is_testset = suite_type == TestSetType

    desc, testsuitetype, options = Test.parse_testset_args(args[1:end-1])

    function filter_hooks_fn(a)
        a.head == :call &&
        a.args[1] == :(=>) &&
        (
            (a.args[2] in TEST_CASE_PARAMETER_NAMES && is_testcase) ||
            (a.args[2] in TEST_SUITE_PARAMETER_NAMES && !is_testcase)
        )
    end

    # separate hook functions from other params
    hook_fn_options = :(Dict{Symbol, Any}())
    append!(hook_fn_options.args, filter(filter_hooks_fn, options.args))

    # keep non-hook options in-place
    filter!(!filter_hooks_fn, options.args)

    if desc === nothing
        desc = "test set"
    end
    # If we're at the top level we'll default to RichReportingTestSet. Otherwise
    # default to the type of the parent testset
    if testsuitetype === nothing
        testsuitetype = :(get_testset_depth() == 0 ? RichReportingTestSet : typeof(get_testset()))
    end

    # Generate a block of code that initializes a new testset, adds
    # it to the task local storage, evaluates the test(s), before
    # finally removing the testset and giving it a chance to take
    # action (such as reporting the results)
    @assert tests.head == :block
    ex = quote
        Test._check_testset($testsuitetype, $(QuoteNode(testsuitetype.args[1])))
        local ret = nothing
        local ts = $(testsuitetype)($desc; $options...)
        Test.push_testset(ts)
        # we reproduce the logic of guardseed, but this function
        # cannot be used as it changes slightly the semantic of @testset,
        # by wrapping the body in a function
        local RNG = Random.default_rng()
        local oldrng = copy(RNG)
        try
            # RNG is re-seeded with its own seed to ease reproduce a failed test
            Random.seed!(RNG.seed)
            ret = let
                $(checked_testsuite_expr(desc, tests, source, hook_fn_options; is_testcase = is_testcase))
            end
        finally
            copy!(RNG, oldrng)
            Test.pop_testset()
            if $is_testset
                # for a top-level `@testset`, we also run the tests using `SequentialTestRunner`
                if get_testset_depth() == 0
                    if run_testsuite(SequentialTestRunner, ret) && Test.TESTSET_PRINT_ENABLE[]
                        TestReports.display_reporting_testset(ts)
                    end
                end
            end
        end
        ret
    end
    # preserve outer location if possible
    if tests isa Expr && tests.head === :block && !isempty(tests.args) && tests.args[1] isa LineNumberNode
        ex = Expr(:block, tests.args[1], ex)
    end
    return ex
end

function checked_testsuite_expr(name::Expr, ts_expr::Expr, source, hook_fn_options; is_testcase::Bool = false)
    quote
        ts = get_testset()

        tls = task_local_storage()
        added_tls, rs = initialize_xunit_state(tls)

        local testsuite_or_testcase = nothing

        try
            std_io = IOBuffer()
            if Test.TESTSET_PRINT_ENABLE[]
                print(std_io, "  "^length(rs.stack))
            end
            path = open_testset(rs, $name)
            shouldrun = length(rs.stack) <= rs.maxdepth &&
                    pmatch(rs.include, path) != nothing && pmatch(rs.exclude, path) == nothing
            rs.seen[path] = shouldrun
            parent_testsuite_obj = isempty(rs.test_suites_stack) ? nothing : last(rs.test_suites_stack)

            if shouldrun
                if Test.TESTSET_PRINT_ENABLE[]
                    if $is_testcase && !haskey(tls, :__TESTCASE_IS_RUNNING__)
                        print(std_io, "Scheduling ")
                    else
                        print(std_io, "Running ")
                    end
                    printstyled(std_io, path; bold=true)
                    println(std_io, " tests...")
                end
            else
                if Test.TESTSET_PRINT_ENABLE[]
                    printstyled(std_io, "Skipped Scheduling $path tests...\n"; color=:light_black)
                end
            end

            seekstart(std_io)
            # thread-safe print
            print(read(std_io, String))

            $(
                if !is_testcase
                    quote
                        testsuite_obj = AsyncTestSuite(ts, $(QuoteNode(source)), parent_testsuite_obj; disabled=!shouldrun, $(esc(hook_fn_options))...)

                        push!(rs.test_suites_stack, testsuite_obj)

                        try
                            if shouldrun # if a test-suite is filtered, we completely ignore it
                                let
                                    $(esc(ts_expr))
                                end
                            end
                        catch err
                            err isa InterruptException && rethrow()
                            # something in the test block threw an error. Count that as an
                            # error in this test set
                            Test.record(ts, Test.Error(:nontest_error, Expr(:tuple), err, Base.catch_stack(), testsuite_obj.source))
                        finally
                            pop!(rs.test_suites_stack)
                        end

                        testsuite_or_testcase = testsuite_obj
                    end
                else
                    quote
                        testsuite_or_testcase = if shouldrun
                            testcase_obj = AsyncTestCase(ts, parent_testsuite_obj, $(QuoteNode(source)); disabled=!shouldrun, $(esc(hook_fn_options))...) do
                                $(esc(ts_expr))
                            end

                            if haskey(tls, :__TESTCASE_IS_RUNNING__)
                                push!(rs.test_suites_stack, testcase_obj)

                                try
                                    # a test-case that is under another test-case is treated
                                    # like a testset and runs immediately
                                    # Note: `before_each` and `after_each` hooks are already
                                    # ran for the top-most test-case and won't run again
                                    gather_test_metrics(testcase_obj)
                                catch err
                                    err isa InterruptException && rethrow()
                                    # something in the test block threw an error. Count that as an
                                    # error in this test set
                                    Test.record(ts, Test.Error(:nontest_error, Expr(:tuple), err, Base.catch_stack(), testcase_obj.source))
                                finally
                                    pop!(rs.test_suites_stack)
                                end
                            end
                            testcase_obj
                        else
                            AsyncTestCase(ts, parent_testsuite_obj, $(QuoteNode(source)); disabled=!shouldrun, $(esc(hook_fn_options))...) do
                                nothing
                            end
                        end
                    end
                end
            )
        finally
            close_testset(rs)
            if added_tls
                delete!(tls, :__XUNIT_STATE__)
            end
        end

        testsuite_or_testcase
    end
end

# END TestSuite

# BEGIN TestCase

"""
Defines a self-contained test-case.

Test-cases are gathered at scheduling time and will get executed using a test-runner.
As a test-runner can run tests in any order (and even on multiple threads/processes), it's
stringly advised that test-cases be independent and do not depend on each other.
"""
macro testcase(args...)
    isempty(args) && error("No arguments to @testcase")

    tests = args[end]

    # Determine if a single block or for-loop style
    if !isa(tests, Expr) || tests.head !== :block
        error("Expected begin/end block or for loop as argument to @testcase")
    end

    return testsuite_beginend(args, tests, __source__, TestCaseType)
end

# END TestCase

# BEGIN TestSet

"""
Overwritten version of `Base.Test.@testset`.

Please note that `@testset` and `@testsuite` macros are very similar.
The only difference is the top-level `@testset` also runs the test-cases, but a top-level
`@testsuite` does not run its underlying test-cases (and only schedules them).
Then, one needs to explicitly call `run_testsuite` over the result of this macro.
"""
macro testset(args...)
    isempty(args) && error("No arguments to @testset")

    tests = args[end]

    # Determine if a single block or for-loop style
    if !isa(tests,Expr) || (tests.head !== :for && tests.head !== :block)
        error("Expected begin/end block or for loop as argument to @testset")
    end

    if tests.head === :for
        return testset_forloop(args, tests, __source__)
    else
        return testsuite_beginend(args, tests, __source__, TestSetType)
    end
end

"""
Generate the code for a `@testset` with a `for` loop argument
"""
function testset_forloop(args, testloop, source)
    error("For loop in `XUnit.@testset` is not supported.")
end

# END TestSet

# BEGIN Overloading Base.Test functions

# We do not want to print all non-relevant stack-trace related to `XUnit` or Julia internals
# This function overload handles this scrubbing and stacktrace cleanup
function Test.scrub_backtrace(bt::Vector)
    do_test_ind = findfirst(ip -> Test.ip_has_file_and_func(ip, joinpath(@__DIR__, "rich-reporting-testset.jl"), (:display_reporting_testset,)), bt)
    if do_test_ind !== nothing && length(bt) > do_test_ind
        bt = bt[do_test_ind + 1:end]
    end
    name_ind = findfirst(ip -> Test.ip_has_file_and_func(ip, @__FILE__, (Symbol("macro expansion"),)), bt)
    if name_ind !== nothing && length(bt) != 0
        bt = bt[1:name_ind]
    end
    return bt
end

function Test.record(ts::Test.DefaultTestSet, t::Fail)
    if Test.myid() == 1
        printstyled(ts.description, ": ", color=:white)
        # don't print for interrupted tests
        if t.test_type !== :test_interrupted
            print(t)
            println()
        end
    end
    push!(ts.results, t)
    t, backtrace()
end

# END Overloading Base.Test functions

function runtests(fun::Function, depth::Int64=typemax(Int64), args...)
    includes = []
    excludes = ["(?!)"]     # seed with an unsatisfiable regex
    for arg in args
        if startswith(arg, "-") || startswith(arg, "¬")
            push!(excludes, arg[nextind(arg,1):end])
        else
            push!(includes, arg)
        end
    end
    include = partial(join(map(x -> string("(?:", x, ")"), includes), "|"))
    exclude = exact(join(map(x -> string("(?:", x, ")"), excludes), "|"))
    state = XUnitState(depth, include, exclude)
    task_local_storage(:__XUNIT_STATE__, state) do
        fun()
    end
    state
end

"""
Include file `filepath` and execute test sets matching the regular expressions
in `args`.  See alternative form of `runtests` for examples.
"""
function runtests(filepath::String, args...)
    runtests(typemax(Int), args...) do
        XUnitModuleName = replace(string(gensym("XUnitModule")), "#" => "_")
        GLOBAL_TEST_FILENAME = filepath
        GLOBAL_TEST_MOD = string("module ",XUnitModuleName, "; ",read(filepath, String), "\nend")
        Core.eval(Main, Expr(:(=), :GLOBAL_TEST_MOD, GLOBAL_TEST_MOD))
        Core.eval(Main, Expr(:(=), :GLOBAL_TEST_FILENAME, GLOBAL_TEST_FILENAME))
        @passobj 1 workers() GLOBAL_TEST_FILENAME
        @passobj 1 workers() GLOBAL_TEST_MOD
        @everywhere include_string(Main, Main.GLOBAL_TEST_MOD, Main.GLOBAL_TEST_FILENAME)
    end
end

"""
Include file `test/runtests.jl` and execute test sets matching the regular
expressions in `args` (where a leading '-' or '¬' indicates that tests
matching the expression should be excluded).

# Examples
```jldoctest
julia> runtests(["t/a/.*"])         # Run all tests under `t/a`

julia> runtests(["t/.*", "¬t/b/2"])  # Run all tests under `t` except `t/b/2`
```
"""
function runtests(args::Vector{String})
    testfile = pwd() * "/test/runtests.jl"
    if !isfile(testfile)
        @error("Could not find test/runtests.jl")
        return
    end
    runtests(testfile, args...)
end

"""
Run test sets up to the provided nesting `depth` and matching the regular
expressions in `args`.
"""
function runtests(depth::Int, args...)
    testfile = pwd() * "/test/runtests.jl"
    if !isfile(testfile)
        @error("Could not find test/runtests.jl")
        return
    end
    runtests(testfile, depth, args...)
end

export RichReportingTestSet, html_output, html_report!, xml_output, xml_report!
export clear_test_reports!, test_out_io, test_err_io, test_print, test_println

export @testset, @test_broken
export runtests, showtests

#
# Purely delegated macros and functions
#
using Test: @test, @test_throws, @test_broken, @test_skip,
    @test_warn, @test_nowarn, @test_logs, @test_deprecated
using Test: @inferred
using Test: detect_ambiguities, detect_unbound_args
using Test: GenericString, GenericSet, GenericDict, GenericArray
using Test: TestSetException
using Test: get_testset, get_testset_depth
using Test: DefaultTestSet, record, finish

export @test, @test_throws, @test_broken, @test_skip,
    @test_warn, @test_nowarn, @test_logs, @test_deprecated,
    @testsuite, @testcase
export @inferred
export detect_ambiguities, detect_unbound_args
export GenericString, GenericSet, GenericDict, GenericArray
export TestSetException
export get_testset, get_testset_depth, run_testsuite
export AbstractTestSet, DefaultTestSet, record, finish
export TestRunner
export SequentialTestRunner, ShuffledTestRunner, ParallelTestRunner, DistributedTestRunner
export TestMetrics, DefaultTestMetrics
export gather_test_metrics, combine_test_metrics, save_test_metrics

end
