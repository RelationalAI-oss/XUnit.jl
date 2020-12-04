module XUnit

using Base: @lock, ReentrantLock
using Distributed #for DistributedTestRunner
using ExceptionUnwrapping: has_wrapped_exception
using EzXML
import Test
using Test: AbstractTestSet, Result, Fail, Broken, Pass, Error
using Test: TESTSET_PRINT_ENABLE, get_testset_depth, get_testset
using Test: _check_testset, parse_testset_args, push_testset, pop_testset
using TestReports
using TestReports: display_reporting_testset
using Random
using Base: Filesystem
using Base.Threads

const Option{T} = Union{Nothing,T}

abstract type TestRunner end
abstract type TestMetrics end

# BEGIN AsyncTestSuite and AsyncTestCase

mutable struct _AsyncTestCase{ASYNC_TEST_SUITE}
    testset_report::AbstractTestSet
    parent_testsuite::Option{Union{_AsyncTestCase{ASYNC_TEST_SUITE},ASYNC_TEST_SUITE}}
    test_fn::Function
    source::LineNumberNode
    disabled::Bool
    sub_testsuites::Vector{ASYNC_TEST_SUITE}
    sub_testcases::Vector{_AsyncTestCase{ASYNC_TEST_SUITE}}
    metrics::Option{TestMetrics}
    runner::TestRunner
    success_handler::Function
    failure_handler::Function
    xml_report::Bool
    html_report::Bool
    modify_lock::ReentrantLock
end

struct AsyncTestSuite
    testset_report::AbstractTestSet
    parent_testsuite::Option{Union{_AsyncTestCase{AsyncTestSuite},AsyncTestSuite}}
    before_each_hook::Function
    after_each_hook::Function
    source::LineNumberNode
    disabled::Bool
    sub_testsuites::Vector{AsyncTestSuite}
    sub_testcases::Vector{_AsyncTestCase{AsyncTestSuite}}
    metrics::Option{TestMetrics}
    runner::TestRunner
    success_handler::Function
    failure_handler::Function
    xml_report::Bool
    html_report::Bool
    modify_lock::ReentrantLock
end

const AsyncTestCase = _AsyncTestCase{AsyncTestSuite}
const AsyncTestSuiteOrTestCase = Union{AsyncTestSuite,AsyncTestCase}

include("rich-reporting-testset.jl")
include("test-runners.jl")
include("test-filter.jl")

function AsyncTestSuite(
    testset_report::AbstractTestSet,
    source::LineNumberNode,
    parent_testsuite::Option{AsyncTestSuiteOrTestCase}=nothing;
    before_each::Function = () -> nothing,
    after_each::Function = () -> nothing,
    sub_testsuites::Vector{AsyncTestSuite} = AsyncTestSuite[],
    sub_testcases::Vector{AsyncTestCase} = AsyncTestCase[],
    disabled::Bool = false,
    metrics = nothing,
    runner::TestRunner = SequentialTestRunner(),
    success_handler::Function = (testsuite) -> nothing,
    failure_handler::Function = (testsuite) -> nothing,
    xml_report::Bool = false,
    html_report::Bool = false,
)
    metrics_instance = create_test_metrics(parent_testsuite, metrics)

    instance = AsyncTestSuite(
        testset_report,
        parent_testsuite,
        before_each,
        after_each,
        source,
        disabled,
        sub_testsuites,
        sub_testcases,
        metrics_instance,
        runner,
        success_handler,
        failure_handler,
        xml_report,
        html_report,
        ReentrantLock(),
    )
    if parent_testsuite !== nothing
        lock(parent_testsuite.modify_lock) do
            push!(parent_testsuite.sub_testsuites, instance)
        end
    end
    return instance
end

function AsyncTestSuite(testcase::AsyncTestCase)
    return AsyncTestSuite(
        testcase.testset_report,
        testcase.source;
        disabled = testcase.disabled,
        metrics = testcase.metrics === nothing ? nothing : typeof(testcase.metrics),
        runner = testcase.runner,
        success_handler = testcase.success_handler,
        failure_handler = testcase.failure_handler,
        xml_report = testcase.xml_report,
        html_report = testcase.html_report,
    )
end

function AsyncTestCase(
    test_fn::Function,
    testset_report::AbstractTestSet,
    source::LineNumberNode,
    parent_testsuite::Option{AsyncTestSuiteOrTestCase};
    disabled::Bool=false,
    metrics = nothing,
    runner::TestRunner = SequentialTestRunner(),
    success_handler::Function = (testsuite) -> nothing,
    failure_handler::Function = (testsuite) -> nothing,
    xml_report::Bool = false,
    html_report::Bool = false,
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
        metrics_instance,
        runner,
        success_handler,
        failure_handler,
        xml_report,
        html_report,
        ReentrantLock(),
    )
    if parent_testsuite !== nothing
        lock(parent_testsuite.modify_lock) do
            push!(parent_testsuite.sub_testcases, instance)
        end
    end
    return instance
end

include("test-metrics.jl")

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
    Expr(:quote, :runner),
    Expr(:quote, :success_handler),
    Expr(:quote, :failure_handler),
    Expr(:quote, :xml_report),
    Expr(:quote, :html_report),
)

const TEST_CASE_PARAMETER_NAMES = (
    Expr(:quote, :metrics),
    Expr(:quote, :runner),
    Expr(:quote, :success_handler),
    Expr(:quote, :failure_handler),
    Expr(:quote, :xml_report),
    Expr(:quote, :html_report),
)

html_output(testsuite::AsyncTestSuite) = html_output(testsuite.testset_report)
html_output(testcase::AsyncTestCase) = html_output(testcase.testset_report)
xml_output(testsuite::AsyncTestSuite) = xml_output(testsuite.testset_report)
xml_output(testcase::AsyncTestCase) = xml_output(testcase.testset_report)

function html_report(testsuite::AsyncTestSuiteOrTestCase)
    return html_report(testsuite.testset_report)
end

function xml_report(testsuite::AsyncTestSuiteOrTestCase)
    return xml_report(testsuite.testset_report)
end

function TestReports.display_reporting_testset(
    testsuite::AsyncTestSuiteOrTestCase;
    throw_on_error::Bool = true,
)
    TestReports.display_reporting_testset(
        testsuite.testset_report; throw_on_error=throw_on_error
    )
end

# END AsyncTestSuite and AsyncTestCase

# BEGIN XUnitState

"""
    struct XUnitState

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
    create_deep_copy(x)

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

function initialize_xunit_tls_state(tls)
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

function finalize_xunit_tls_state(tls, added_tls)
    added_tls && delete!(tls, :__XUNIT_STATE__)
end

# END XUnitState

# Enumeration of all possible macro types
@enum SuiteType TestSuiteType TestCaseType TestSetType

# BEGIN TestSuite

"""
    @testsuite "suite name" begin ... end
    @testsuite [before_each=()->...] [after_each=()->...] [metrics=DefaultTestMetrics]
               [success_handler=(testsuite)->...] [failure_handler=(testsuite)->...]
               [xml_report=false] [html_report=false] "suite name" begin ... end

Schedules a Test Suite

Please note that `@testset` and `@testsuite` macros are very similar.
The only difference is the top-level `@testset` also runs the test-cases, but a top-level
`@testsuite` does not run its underlying test-cases (and only schedules them).
Then, one needs to explicitly call `run_testsuite` over the result of this macro.

Also, note that the body of a `@testsuite` always gets executed at scheduling time, as it
needs to gather possible underlying `@testcase`s. Thus, it's a good practice to put your
tests under a `@testcase` (instead of putting them under a `@testsuite`), as any tests
defined under a `@testsuite` are executed sequentially at scheduling time.

## Keyword Arguments

`@testsuite` takes seven additional parameters:
  - `before_each`: a function to run before each underlying test-case
  - `after_each`: a function to run after each underlying test-case
  - `metrics`: a custom `TestMetrics` type
  - `success_handler`: a function to run after a successful handling of all tests. This
    function accepts the test-suite as an argument. This argument only works for the
    top-most `@testsuite`.
  - `failure_handler`: a function to run after a failed handling of all tests. This function
    accepts the test-suite as an argument. This argument only works for the top-most
    `@testsuite`.
  - `xml_report`: whether to produce the XML output file at the end.
    This argument only works for the top-most `@testsuite`
  - `html_report`: whether to produce the HTML output file at the end.
    This argument only works for the top-most `@testsuite`
"""
macro testsuite(args...)
    return testsuite_handler(args, __source__)
end

function _is_block(e)
    return false
end
function _is_block(e::Expr)
    e.head === :block
end

"""
    get_block_source(e)

A utility function for extracting the source information from a block expression
"""
function get_block_source(e)
    if e.head === :block && !isempty(e.args) && e.args[1] isa LineNumberNode
        return e.args[1]
    end
    return nothing
end

function testsuite_handler(args, source)
    isempty(args) && error("No arguments to @testsuite")

    tests = args[end]

    # Determine if a single block or for-loop style
    if !isa(tests, Expr) || !_is_block(tests)
        error("Expected begin/end block or for loop as argument to @testsuite")
    end

    return testsuite_beginend(args, tests, source, TestSuiteType)
end

"""
    testsuite_beginend(args, tests, source, suite_type::SuiteType)

Generate the code for a `@testsuite` with a `begin`/`end` argument
"""
function testsuite_beginend(args, tests, source, suite_type::SuiteType)
    is_testcase = suite_type == TestCaseType

    tests_block_location = get_block_source(tests)
    tests_is_block_with_location = tests_block_location !== nothing

    # the location information inside `tests.args[1]` (if available) is more accurate
    # The `source` passed to this function is not correct is this macro is called inside
    # another macro. In that case, source will refer to the upper macro's address, not the
    # place that tests are defined
    source = tests_is_block_with_location ? tests_block_location : source
    desc, testsettype, options = XUnit.parse_testset_args(args[1:end-1])

    # `option` is a tuple creating expression that represents a key-value option
    function filter_hooks_fn(option)
        option.head == :call &&
        option.args[1] == :(=>) &&
        (
            (option.args[2] in TEST_CASE_PARAMETER_NAMES && is_testcase) ||
            (option.args[2] in TEST_SUITE_PARAMETER_NAMES && !is_testcase)
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
    if testsettype === nothing
        testsettype = :(XUnit.get_testset_depth() == 0 ?
                            RichReportingTestSet :
                            typeof(XUnit.get_testset()))
    end

    # Generate a block of code that initializes a new testset, adds
    # it to the task local storage, evaluates the test(s), before
    # finally removes the testset and gives it a chance to take
    # action (such as reporting the results)
    @assert _is_block(tests)
    ex = quote
        # check that `testsettype` is a subtype of `AbstractTestSet`
        # (otherwise, throw an error)
        XUnit._check_testset($testsettype, $(QuoteNode(testsettype.args[1])))
        local ret = nothing
        local ts = $(testsettype)($desc; $options...)
        XUnit.push_testset(ts)
        # we reproduce the logic of guardseed, but this function
        # cannot be used as it changes slightly the semantic of @testset,
        # by wrapping the body in a function
        local RNG = Random.default_rng()
        local oldrng = copy(RNG)
        local ret = nothing
        try
            # RNG is re-seeded with its own seed to ease reproduce a failed test
            Random.seed!(RNG.seed)
            ret = let
                $(checked_testsuite_expr(
                    desc, tests, source, hook_fn_options; is_testcase = is_testcase
                ))
            end
        finally
            copy!(RNG, oldrng)
            XUnit.pop_testset()
        end

        if ret !== nothing && XUnit.get_testset_depth() == 0
            # if there was no error during the scheduling and it's the topmost `@testset`,
            # `@testsuite` or `@testcase`, then we want to run the scheduled tests.
            # If the `runner` keyword argument is used, that runner type is going to run
            # the tests. Otherwise, `SequentialTestRunner` is used to keep the same
            # semantics of `@testset` in `Base.Test`
            run_testsuite(ret)
        end

        ret
    end
    # preserve outer location if possible
    if tests_is_block_with_location
        ex = Expr(:block, tests_block_location, ex)
    end
    return ex
end

function run_testcase_inplace(testcase_obj)
    testcase_obj.disabled && return

    ts = testcase_obj.testset_report

    try
        # a test-case that is under another test-case is treated
        # like a testset and runs immediately
        # Note: `before_each` and `after_each` hooks are already
        # ran for the top-most test-case and won't run again
        # Note: there's no need to gather metrics for a test-case if it's not explicitly
        # marked for statistics collection. These non-top-level test-cases are guaranteed to
        # run sequentially (in a single process/thread) and cannot comprise of smaller
        # execution units that run out-of-order.
        if XUnit.should_report_metric(testcase_obj)
            XUnit.run_and_gather_test_metrics(testcase_obj; run=true)
        else
            testcase_obj.test_fn()
        end
    catch err
        has_wrapped_exception(err, InterruptException) && rethrow()
        # something in the test block threw an error. Count that as an
        # error in this test set
        XUnit.record(ts, XUnit.Error(
            :nontest_error, Expr(:tuple), err, Base.catch_stack(), testcase_obj.source
        ))
    end

    return testcase_obj
end

# This function is the common function for handling the body of all `@testsuite`, `@testset`,
# and `@testcase` macros. This is how it works:
# - if a `@testsuite`, `@testset`, or `@testcase` is disabled, it skips it.
# - if it's a `@testsuite` or `@testset`, runs its body
# - if it's a `@testcase`:
#   - if it IS NOT enclosed inside another `@testcase`, then it schedules it for running later
#   - if it IS enclosed inside another `@testcase`, runs its body
function checked_testsuite_expr(
    name::Expr, ts_expr::Expr, source, hook_fn_options; is_testcase::Bool = false
)
    quote
        ts = get_testset()

        tls = task_local_storage()
        added_tls, rs = XUnit.initialize_xunit_tls_state(tls)

        local testsuite_or_testcase = nothing

        try
            std_io = IOBuffer()
            if XUnit.TESTSET_PRINT_ENABLE[]
                print(std_io, "  "^length(rs.stack))
            end
            path = XUnit.open_testset(rs, $name)
            shouldrun = length(rs.stack) <= rs.maxdepth &&
                        XUnit.pmatch(rs.include, path) != nothing &&
                        XUnit.pmatch(rs.exclude, path) == nothing
            rs.seen[path] = shouldrun
            parent_testsuite_obj = if isempty(rs.test_suites_stack)
                nothing
            else
                last(rs.test_suites_stack)
            end

            if shouldrun # if it's not disabled
                if XUnit.TESTSET_PRINT_ENABLE[]
                    if $is_testcase && !haskey(tls, :__TESTCASE_IS_RUNNING__)
                        # if it's a `@testcase` NOT enclosed inside another `@testcase`,
                        # then it gets scheduled for running later
                        print(std_io, "Scheduling ")
                    else
                        # otherwise, if it IS enclosed inside another `@testcase`,
                        # we run it immediately
                        print(std_io, "Running ")
                    end
                    printstyled(std_io, path; bold=true)
                    println(std_io, " tests...")
                end
            else # skip disabled `@testsuite`s, `@testset`s, and `@testcase`s
                if XUnit.TESTSET_PRINT_ENABLE[]
                    printstyled(
                        std_io, "Skipped Scheduling $path tests...\n"; color=:light_black
                    )
                end
            end

            seekstart(std_io)
            # thread-safe print
            print(read(std_io, String))

            $(
                if !is_testcase #if it's a `@testsuite` or `@testset`, runs its body
                    quote
                        testsuite_obj = XUnit.AsyncTestSuite(
                            ts, $(QuoteNode(source)), parent_testsuite_obj;
                            disabled=!shouldrun, $(esc(hook_fn_options))...
                        )

                        push!(rs.test_suites_stack, testsuite_obj)

                        try
                            if shouldrun # if a test-suite is filtered, we completely ignore it
                                let
                                    $(esc(ts_expr))
                                end
                            end
                        catch err
                            has_wrapped_exception(err, InterruptException) && rethrow()
                            # something in the test block threw an error. Count that as an
                            # error in this test set
                            XUnit.record(ts, XUnit.Error(
                                :nontest_error,
                                Expr(:tuple),
                                err,
                                Base.catch_stack(),
                                testsuite_obj.source
                            ))
                        finally
                            pop!(rs.test_suites_stack)
                        end

                        testsuite_or_testcase = testsuite_obj
                    end
                else
                    quote
                        testsuite_or_testcase = if shouldrun # if a `@testcase` is not disabled
                            testcase_obj = XUnit.AsyncTestCase(
                                ts, $(QuoteNode(source)), parent_testsuite_obj;
                                disabled=!shouldrun, $(esc(hook_fn_options))...) do
                                    $(esc(ts_expr))
                            end

                            # if it IS enclosed inside another `@testcase`, we run it immediately
                            if haskey(tls, :__TESTCASE_IS_RUNNING__)
                                push!(rs.test_suites_stack, testcase_obj)

                                try
                                    run_testcase_inplace(testcase_obj)
                                finally
                                    pop!(rs.test_suites_stack)
                                end
                            end
                            testcase_obj
                        else  # if a `@testcase` is disabled, skipt it
                            XUnit.AsyncTestCase(
                                ts, $(QuoteNode(source)), parent_testsuite_obj;
                                disabled=!shouldrun, $(esc(hook_fn_options))...) do
                                    nothing
                            end
                        end
                    end
                end
            )
        finally
            XUnit.close_testset(rs)
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
    @testcase "test-case name" begin ... end
    @testcase [before_each=()->...] [after_each=()->...] [metrics=DefaultTestMetrics]
              [success_handler=(testcase)->...] [failure_handler=(testcase)->...]
              [xml_report=false] [html_report=false] "test-case" begin ... end

Defines a self-contained test-case.

Test-cases are gathered at scheduling time and will get executed using a test-runner.
As a test-runner can run tests in any order (and even on multiple threads/processes), it's
strongly advised that test-cases do not depend on each other.

## Keyword Arguments

`@testsuite` takes four additional parameters:
  - `metrics`: a custom `TestMetrics` type
  - `success_handler`: a function to run after a successful handling of all tests. This
    function accepts the test-suite as an argument. This argument only works for the
    top-most `@testcase`.
  - `failure_handler`: a function to run after a failed handling of all tests. This function
    accepts the test-suite as an argument. This argument only works for the top-most
    `@testcase`.
  - `xml_report`: whether to produce the XML output file at the end.
    This argument only works for the top-most `@testcase`
  - `html_report`: whether to produce the HTML output file at the end.
    This argument only works for the top-most `@testcase`
"""
macro testcase(args...)
    return testcase_handler(args, __source__)
end

function testcase_handler(args, source)
    isempty(args) && error("No arguments to @testcase")

    tests = args[end]

    # Determine if a single block or for-loop style
    if !isa(tests, Expr) || !_is_block(tests)
        error("Expected begin/end block or for loop as argument to @testcase")
    end

    return testsuite_beginend(args, tests, source, TestCaseType)
end

# END TestCase

# BEGIN TestSet

"""
    @testset [CustomTestSet] [option=val  ...] ["description"] begin ... end

Overwritten version of `Base.Test.@testset`.

Please note that `@testset` and `@testsuite` macros are very similar.
The only difference is the top-level `@testset` also runs the test-cases, but a top-level
`@testsuite` does not run its underlying test-cases (and only schedules them).
Then, one needs to explicitly call `run_testsuite` over the result of this macro.

Starts a new test set

If no custom testset type is given it defaults to creating a `DefaultTestSet`.
`DefaultTestSet` records all the results and, if there are any `Fail`s or
`Error`s, throws an exception at the end of the top-level (non-nested) test set,
along with a summary of the test results.
Any custom testset type (subtype of `AbstractTestSet`) can be given and it will
also be used for any nested `@testset` invocations. The given options are only
applied to the test set where they are given. The default test set type does
not take any options.
By default the `@testset` macro will return the testset object itself, though
this behavior can be customized in other testset types.
Before the execution of the body of a `@testset`, there is an implicit
call to `Random.seed!(seed)` where `seed` is the current seed of the global RNG.
Moreover, after the execution of the body, the state of the global RNG is
restored to what it was before the `@testset`. This is meant to ease
reproducibility in case of failure, and to allow seamless
re-arrangements of `@testset`s regardless of their side-effect on the
global RNG state.
# Examples
```jldoctest
julia> @testset "trigonometric identities" begin
            θ = 2/3*π
            @test sin(-θ) ≈ -sin(θ)
            @test cos(-θ) ≈ cos(θ)
            @test sin(2θ) ≈ 2*sin(θ)*cos(θ)
            @test cos(2θ) ≈ cos(θ)^2 - sin(θ)^2
        end;
Test Summary:            | Pass  Total
trigonometric identities |    4      4
```
"""
macro testset(args...)
    isempty(args) && error("No arguments to @testset")

    tests = args[end]

    # Determine if a single block or for-loop style
    if !isa(tests,Expr) || (tests.head !== :for && !_is_block(tests))
        error("Expected begin/end block or for loop as argument to @testset")
    end

    if tests.head === :for
        return testset_forloop(args, tests, __source__)
    else
        return testsuite_beginend(args, tests, __source__, TestSetType)
    end
end

"""
    testset_forloop(args, testloop, source)

Generate the code for a `@testset` with a `for` loop argument

Note: It's not supported yet.
"""
function testset_forloop(args, testloop, source)
    error("For loop in `XUnit.@testset` is not supported.")
end

# END TestSet

# BEGIN Overloading Base.Test functions

# We do not want to print all non-relevant stack-trace related to `XUnit` or Julia internals
# This function overload handles this scrubbing and stacktrace cleanup
function Test.scrub_backtrace(bt::Vector)
    do_test_ind = findfirst(ip -> Test.ip_has_file_and_func(
        ip, joinpath(@__DIR__, "rich-reporting-testset.jl"), (:display_reporting_testset,)
    ), bt)
    if do_test_ind !== nothing && length(bt) > do_test_ind
        bt = bt[do_test_ind + 1:end]
    end
    name_ind = findfirst(ip -> Test.ip_has_file_and_func(
        ip, @__FILE__, (Symbol("macro expansion"),)
    ), bt)
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
    runtests(filepath::String, args...)

Include file `filepath` and execute test sets matching the regular expressions
in `args`.  See alternative form of `runtests` for examples.
"""
function runtests(filepath::String, args...)
    runtests(typemax(Int), args...) do
        if nworkers() == 1
            # Using a single worker, there's no need to do fancy distributed execution
            @eval Main begin
                # Construct a new throw-away module in which to run the tests
                m = @eval Main module $(gensym("XUnitModule")) end  # e.g. Main.##XUnitModule#365
                # Perform the include inside the new module m
                m.include($filepath)
            end
        else
            # make sure to pass the test-state to the worker processes (mostly for test filtering)
            parent_thread_tls = task_local_storage()
            has_xunit_state = haskey(parent_thread_tls, :__XUNIT_STATE__)
            xunit_state = if has_xunit_state
                xs = create_deep_copy(parent_thread_tls[:__XUNIT_STATE__])
                empty!(xs.test_suites_stack)
                empty!(xs.stack)
                empty!(xs.seen)
                xs
            else
                nothing
            end
            Core.eval(Main, Expr(:(=), :GLOBAL_HAS_XUNIT_STATE, has_xunit_state))
            Core.eval(Main, Expr(:(=), :GLOBAL_XUNIT_STATE, xunit_state))
            @passobj 1 workers() GLOBAL_HAS_XUNIT_STATE
            @passobj 1 workers() GLOBAL_XUNIT_STATE

            # When we have several workers available, we'd prepare for `Distributed` execution
            # Even though, still, the underlying test-suite should explicitly request it via
            # the `runner=DistributedTestRunner()` keyword argument.
            XUnitModuleName = replace(string(gensym("XUnitModule")), "#" => "_")
            GLOBAL_TEST_FILENAME = filepath
            # everything is in a single line to correctly report the line numbers in
            # `filepath` back to the user
            GLOBAL_TEST_MOD = string(
                "module ",XUnitModuleName, "; ",
                "import XUnit; ",
                "function __set_tls_xunit_state(); ",
                "    xs = XUnit.create_deep_copy(Main.GLOBAL_XUNIT_STATE); ",
                "    empty!(xs.test_suites_stack); ",
                "    empty!(xs.stack); ",
                "    empty!(xs.seen); ",
                "    tls = task_local_storage(); ",
                "    tls[:__XUNIT_STATE__] = xs; ",
                "end; ",
                "Main.GLOBAL_HAS_XUNIT_STATE && __set_tls_xunit_state(); ",
                read(filepath, String),"\n",
                "end")
            Core.eval(Main, Expr(:(=), :GLOBAL_TEST_MOD, GLOBAL_TEST_MOD))
            Core.eval(Main, Expr(:(=), :GLOBAL_TEST_FILENAME, GLOBAL_TEST_FILENAME))
            @passobj 1 workers() GLOBAL_TEST_FILENAME
            @passobj 1 workers() GLOBAL_TEST_MOD
            @everywhere begin
                tls = task_local_storage()
                has_saved_source_path = haskey(tls, :SOURCE_PATH)
                saved_source_path = has_saved_source_path ? tls[:SOURCE_PATH] : nothing
                try
                    # we are setting the thread-local `:SOURCE_PATH` for Julia's `include`
                    # mechanism to work correctly. Otheriwse, the direct `include`s inside the
                    # test file located at `filepath` won't work.
                    if ispath(Main.GLOBAL_TEST_FILENAME)
                        tls[:SOURCE_PATH] = Main.GLOBAL_TEST_FILENAME
                    end

                    include_string(Main, Main.GLOBAL_TEST_MOD, Main.GLOBAL_TEST_FILENAME)

                finally
                    if has_saved_source_path
                        tls[:SOURCE_PATH] = saved_source_path
                    else
                        delete!(tls, :SOURCE_PATH)
                    end
                end
            end
        end
    end
end

"""
    runtests(args::Vector{String})

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
    runtests(depth::Int, args...)

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

export RichReportingTestSet, html_output, html_report, xml_output, xml_report
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
export display_reporting_testset, gather_test_metrics, combine_test_metrics
export run_and_gather_test_metrics, save_test_metrics

end
