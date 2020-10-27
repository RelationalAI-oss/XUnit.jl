module XUnit

import Test
using Test: AbstractTestSet, Result, Fail, Broken, Pass, Error
using Test: get_testset_depth, get_testset
using TestReports
using Random
using Base.Threads
using EzXML

const Option{T} = Union{Nothing,T}

struct AsyncTestCase
    testset_report::AbstractTestSet
    parent_testsuite#::Option{AsyncTestSuiteOrTestCase}
    test_fn::Function
    source::LineNumberNode
    disabled::Bool
    before_hook::Function
    after_hook::Function
    sub_testsuites::Vector#{AsyncTestSuite}
    sub_testcases::Vector{AsyncTestCase}
    modify_lock::ReentrantLock
end

struct AsyncTestSuite
    testset_report::AbstractTestSet
    parent_testsuite#::Option{AsyncTestSuiteOrTestCase}
    before_all_hook::Function
    before_each_hook::Function
    sub_testsuites::Vector{AsyncTestSuite}
    sub_testcases::Vector{AsyncTestCase}
    after_each_hook::Function
    after_all_hook::Function
    disabled::Bool
    modify_lock::ReentrantLock
    source::LineNumberNode
end

const AsyncTestSuiteOrTestCase = Union{AsyncTestSuite,AsyncTestCase}

function AsyncTestSuite(
    testset_report::AbstractTestSet,
    source::LineNumberNode,
    parent_testsuite::Option{AsyncTestSuiteOrTestCase}=nothing;
    before_all::Function = () -> nothing,
    before_each::Function = () -> nothing,
    sub_testsuites::Vector{AsyncTestSuite} = AsyncTestSuite[],
    sub_testcases::Vector{AsyncTestSuite} = AsyncTestSuite[],
    after_each::Function = () -> nothing,
    after_all::Function = () -> nothing,
    disabled::Bool = false,
)
    instance = AsyncTestSuite(
        testset_report,
        parent_testsuite,
        before_all,
        before_each,
        sub_testsuites,
        sub_testcases,
        after_each,
        after_all,
        disabled,
        ReentrantLock(),
        source,
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
    before::Function = () -> nothing,
    after::Function = () -> nothing,
)
    instance = AsyncTestCase(
        testset_report,
        parent_testsuite,
        test_fn,
        source,
        disabled,
        before,
        after,
        AsyncTestSuite[],
        AsyncTestCase[],
        ReentrantLock(),
    )
    if parent_testsuite !== nothing
        lock(parent_testsuite.modify_lock) do
            push!(parent_testsuite.sub_testcases, instance)
        end
    end
    return instance
end

abstract type TestRunner end
struct SequentialTestRunner <: TestRunner end
struct ShuffledTestRunner <: TestRunner end
struct ParallelTestRunner <: TestRunner end

include("rich-reporting-testset.jl")

# TODO refactor into patch to bring these into Base

# NOTE: Since  the internals have changed in julia v1.3.0, we need VERSION checks inside
# these functions.

# Helper for `pmatch`: Mirrors Base.PCRE.exec
function pexec(re, subject, offset, options, match_data)
    rc = ccall((:pcre2_match_8, Base.PCRE.PCRE_LIB), Cint,
               (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Csize_t, Cuint, Ptr{Cvoid}, Ptr{Cvoid}),
               re, subject, sizeof(subject), offset, options, match_data,
               @static if VERSION >= v"1.3-"
                   Base.PCRE.get_local_match_context()
               else
                   Base.PCRE.MATCH_CONTEXT[]
               end)
    # rc == -1 means no match, -2 means partial match.
    rc < -2 && error("PCRE.exec error: $(err_message(rc))")
    (rc >= 0 ||
        # Allow partial matches if they were requested in the options.
        ((options & Base.PCRE.PARTIAL_HARD != 0 || options & Base.PCRE.PARTIAL_SOFT != 0) && rc == -2))
end

# Helper to call `pexec` w/ thread-safe match data: Mirrors Base.PCRE.exec_r_data
# Only used for Julia Version >= v"1.3-"
function pexec_r_data(re, subject, offset, options)
    match_data = Base.PCRE.create_match_data(re)
    ans = pexec(re, subject, offset, options, match_data)
    return ans, match_data
end

"""
   pmatch(r::Regex, s::AbstractString[, idx::Integer[, addopts]])

Variant of `Base.match` that supports partial matches (when `Base.PCRE.PARTIAL_HARD`
is set in `re.match_options`).
"""
function pmatch(re::Regex, str::Union{SubString{String}, String}, idx::Integer, add_opts::UInt32=UInt32(0))
    Base.compile(re)
    opts = re.match_options | add_opts
    @static if VERSION >= v"1.3-"
        # rc == -1 means no match, -2 means partial match.
        matched, data = pexec_r_data(re.regex, str, idx-1, opts)
        if !matched
            Base.PCRE.free_match_data(data)
            return nothing
        end
        n = div(Base.PCRE.ovec_length(data), 2) - 1
        p = Base.PCRE.ovec_ptr(data)
        mat = SubString(str, unsafe_load(p, 1)+1, prevind(str, unsafe_load(p, 2)+1))
        cap = Option{SubString{String}}[unsafe_load(p,2i+1) == Base.PCRE.UNSET ? nothing :
                                            SubString(str, unsafe_load(p,2i+1)+1,
                                                      prevind(str, unsafe_load(p,2i+2)+1)) for i=1:n]
        off = Int[ unsafe_load(p,2i+1)+1 for i=1:n ]
        result = RegexMatch(mat, cap, unsafe_load(p,1)+1, off, re)
        Base.PCRE.free_match_data(data)
        return result
    else  #  Julia VERSION < v"1.3"
        # rc == -1 means no match, -2 means partial match.
        matched = pexec(re.regex, str, idx-1, opts, re.match_data)
        if !matched
            return nothing
        end
        ovec = re.ovec
        n = div(length(ovec),2) - 1
        mat = SubString(str, ovec[1]+1, prevind(str, ovec[2]+1))
        cap = Option{SubString{String}}[ovec[2i+1] == PCRE.UNSET ? nothing :
                                            SubString(str, ovec[2i+1]+1,
                                                      prevind(str, ovec[2i+2]+1)) for i=1:n]
        off = Int[ ovec[2i+1]+1 for i=1:n ]
        RegexMatch(mat, cap, ovec[1]+1, off, re)
    end
end

pmatch(r::Regex, s::AbstractString) = pmatch(r, s, firstindex(s))
pmatch(r::Regex, s::AbstractString, i::Integer) = throw(ArgumentError(
    "regex matching is only available for the String type; use String(s) to convert"
))

"""
Constructs a regular expression to perform partial matching.
"""
partial(str::AbstractString) = Regex(str, Base.DEFAULT_COMPILER_OPTS,
    Base.DEFAULT_MATCH_OPTS | Base.PCRE.PARTIAL_HARD)

"""
Constructs a regular expression to perform exact maching.
"""
exact(str::AbstractString) = Regex(str)


# struct XUnitSet <: Test.AbstractTestSet
#     parent::Test.DefaultTestSet
#
#     function XUnitSet(description::String)
#         new(Test.DefaultTestSet(description))
#     end
# end
#
# function Test.record(ts::XUnitSet, res::Test.Result)
#     # println("Recording $res for $(Test.get_test_set()) at depth $(Test.get_testset_depth())")
#     Test.record(ts.parent, res)
# end
#
# function Test.finish(ts::XUnitSet)
#     # println("Finishing")
#     Test.finish(ts.parent)
# end

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

# Runs a Scheduled Test-Suite
function run_testsuite(::Type{T}, testsuite::AsyncTestSuite) where T <: TestRunner
    return run_testsuite(testsuite, T)
end

function run_testsuite(
    testsuite::TEST_SUITE,
    ::Type{T}=SequentialTestRunner
)::TEST_SUITE where {T <: TestRunner, TEST_SUITE <: AsyncTestSuite}
    _run_testsuite(T, testsuite)
    return _finalize_reports(testsuite)
end

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

const TEST_SUITE_HOOK_FUNCTION_PARAMETER_NAMES = (
    # Expr(:quote, :before_all),
    Expr(:quote, :before_each),
    Expr(:quote, :after_each),
    # Expr(:quote, :after_all),
)

const TEST_CASE_HOOK_FUNCTION_PARAMETER_NAMES = (
    Expr(:quote, :before),
    Expr(:quote, :after),
)

@enum SuiteType TestSuiteType TestCaseType TestSetType

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
            (a.args[2] in TEST_CASE_HOOK_FUNCTION_PARAMETER_NAMES && is_testcase) ||
            (a.args[2] in TEST_SUITE_HOOK_FUNCTION_PARAMETER_NAMES && !is_testcase)
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
                if get_testset_depth() == 0
                    run_testsuite(SequentialTestRunner, ret)
                    if Test.TESTSET_PRINT_ENABLE[]
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
        added_tls, rs = initialize_testy_state(tls)

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
                                    testcase_obj.before_hook()
                                    testcase_obj.test_fn()
                                    testcase_obj.after_hook()
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
                delete!(tls, :__TESTY_STATE__)
            end
        end

        testsuite_or_testcase
    end
end

function get_path(testsuite_stack)
    join(map(testsuite -> testsuite.testset_report.description, testsuite_stack), "/")
end

function _finalize_reports(testsuite::TEST_SUITE)::TEST_SUITE where TEST_SUITE <: AsyncTestSuite
    Test.push_testset(testsuite.testset_report)
    try
        for sub_testsuite in testsuite.sub_testsuites
            _finalize_reports(sub_testsuite)
        end

        for sub_testcase in testsuite.sub_testcases
            _finalize_reports(sub_testcase)
        end
    finally
        Test.pop_testset()
    end

    Test.finish(testsuite.testset_report)
    return testsuite
end

function _finalize_reports(testcase::TEST_CASE)::TEST_CASE where TEST_CASE <: AsyncTestCase
    Test.push_testset(testcase.testset_report)
    try
        for sub_testsuite in testcase.sub_testsuites
            _finalize_reports(sub_testsuite)
        end

        for sub_testcase in testcase.sub_testcases
            _finalize_reports(sub_testcase)
        end
    finally
        Test.pop_testset()
    end

    Test.finish(testcase.testset_report)
    return testcase
end

function _run_testsuite(
    ::Type{T},
    testsuite::AsyncTestSuite,
) where T <: TestRunner
    scheduled_tests = _schedule_tests(T, testsuite)
    _run_scheduled_tests(T, scheduled_tests)
    return testsuite
end

struct ScheduledTest
    parent_testsets::Vector{AsyncTestSuite}
    target_testcase::AsyncTestCase
end

function _schedule_tests(
    ::Type{T},
    testsuite::AsyncTestSuite,
    testcases_acc::Vector{ScheduledTest}=ScheduledTest[],
    parent_testsets::Vector{AsyncTestSuite}=AsyncTestSuite[]
) where T <: TestRunner
    parent_testsets = copy(parent_testsets)
    push!(parent_testsets, testsuite)
    for sub_testsuite in testsuite.sub_testsuites
        if !sub_testsuite.disabled
            _schedule_tests(T, sub_testsuite, testcases_acc, parent_testsets)
        end
    end

    for sub_testcase in testsuite.sub_testcases
        if !sub_testcase.disabled
            st = ScheduledTest(parent_testsets, sub_testcase)
            push!(testcases_acc, st)
        end
    end
    return testcases_acc
end

function _schedule_tests(
    ::Type{ShuffledTestRunner},
    testsuite::AsyncTestSuite,
    testcases_acc::Vector{ScheduledTest}=ScheduledTest[],
    parent_testsets::Vector{AsyncTestSuite}=AsyncTestSuite[]
)
    seq_testcases = _schedule_tests(SequentialTestRunner, testsuite, testcases_acc, parent_testsets)
    shuffle!(seq_testcases)
    return seq_testcases
end

function _run_scheduled_tests(
    ::Type{T},
    scheduled_tests::Vector{ScheduledTest},
) where T <: TestRunner
    for st in scheduled_tests
        if Test.TESTSET_PRINT_ENABLE[]
            path = get_path(vcat(st.parent_testsets, [st.target_testcase]))
            print("* Running ")
            printstyled(path; bold=true)
            println(" test-case...")
        end
        _run_single_testcase(st.parent_testsets, st.target_testcase)
    end
end

function _run_scheduled_tests(
    ::Type{ParallelTestRunner},
    scheduled_tests::Vector{ScheduledTest},
)
    scheduled_tests_index = Threads.Atomic{Int}(length(scheduled_tests));

    # make sure to pass the test-state to the underlying threads (mostly for test filtering)
    parent_thread_tls = task_local_storage()
    has_testy_state = haskey(parent_thread_tls, :__TESTY_STATE__)
    testy_state = has_testy_state ? parent_thread_tls[:__TESTY_STATE__] : nothing

    @threads for tid in 1:Threads.nthreads()
        tls = task_local_storage()
        if has_testy_state
            tls[:__TESTY_STATE__] = deepcopy(testy_state)
        end
        while true
            i = (Threads.atomic_sub!(scheduled_tests_index, 1))
            i <= 0 && break

            st = scheduled_tests[i]
            if Test.TESTSET_PRINT_ENABLE[]
                path = get_path(vcat(st.parent_testsets, [st.target_testcase]))
                std_io = IOBuffer()
                print(std_io, "-> Running ")
                printstyled(std_io, path; bold=true)
                println(std_io, " test-case (on tid=$tid)...")
                seekstart(std_io)
                # thread-safe print
                print(read(std_io, String))
            end
            _run_single_testcase(st.parent_testsets, st.target_testcase)
        end
    end
end


function _run_testsuite(
    ::Type{SequentialTestRunner},
    testsuite::AsyncTestSuite,
    parent_testsets::Vector{AsyncTestSuite}=AsyncTestSuite[]
)
    parent_testsets = vcat(parent_testsets, [testsuite])
    suite_path = get_path(parent_testsets)
    if !testsuite.disabled
        if Test.TESTSET_PRINT_ENABLE[]
            print("Running ")
            printstyled(suite_path; bold=true)
            println(" test-suite...")
        end
        for sub_testsuite in testsuite.sub_testsuites
            if Test.TESTSET_PRINT_ENABLE[]
                print("  "^length(parent_testsets))
            end
            _run_testsuite(SequentialTestRunner, sub_testsuite, parent_testsets)
        end

        for sub_testcase in testsuite.sub_testcases
            if Test.TESTSET_PRINT_ENABLE[]
                print("  "^length(parent_testsets))
            end
            path = get_path(vcat(parent_testsets, [sub_testcase]))
            if !sub_testcase.disabled
                if Test.TESTSET_PRINT_ENABLE[]
                    print("Running ")
                    printstyled(path; bold=true)
                    println(" test-case...")
                end
                _run_single_testcase(parent_testsets, sub_testcase)
            elseif Test.TESTSET_PRINT_ENABLE[]
                printstyled("Skipping $path test-case...\n"; color=:light_black)
            end
        end
    elseif Test.TESTSET_PRINT_ENABLE[]
        printstyled("Skipping $suite_path test-suite...\n"; color=:light_black)
    end
    return testsuite
end

function _run_single_testcase(
    parent_testsets::Vector{AsyncTestSuite},
    sub_testcase::AsyncTestCase
)
    parents_with_this = vcat(parent_testsets, [sub_testcase])
    tls = task_local_storage()

    # Testcases cannot be nested underneath each other.
    # Even if they are nested, the nested testcases are considered like testsets
    # (i.e., those are not scheduled for running and will run immediately as part of their
    # parent testcase)
    @assert !haskey(tls, :__TESTCASE_IS_RUNNING__)
    tls[:__TESTCASE_IS_RUNNING__] = sub_testcase

    added_tls, rs = initialize_testy_state(tls)

    # start from an empty stack
    # this will have help with having proper indentation if a `@testset` appears under a `@testcase`
    empty!(rs.stack)
    for testsuite in parents_with_this
        ts = testsuite.testset_report
        push!(rs.stack, ts.description)
        push!(rs.test_suites_stack, testsuite)
        Test.push_testset(ts)
    end

    # we reproduce the logic of guardseed, but this function
    # cannot be used as it changes slightly the semantic of @testset,
    # by wrapping the body in a function
    local RNG = Random.default_rng()
    local oldrng = copy(RNG)
    try
        # RNG is re-seeded with its own seed to ease reproduce a failed test
        Random.seed!(RNG.seed)

        for testsuite in parent_testsets
            testsuite.before_each_hook()
        end
        sub_testcase.before_hook()
        sub_testcase.test_fn()
        sub_testcase.after_hook()
        for testsuite in reverse(parent_testsets)
            testsuite.after_each_hook()
        end
    catch err
        err isa InterruptException && rethrow()
        # something in the test block threw an error. Count that as an
        # error in this test set
        ts = sub_testcase.testset_report
        Test.record(ts, Test.Error(:nontest_error, Expr(:tuple), err, Base.catch_stack(), sub_testcase.source))
    finally
        copy!(RNG, oldrng)
        for ts in parents_with_this
            Test.pop_testset()
            pop!(rs.test_suites_stack)
        end
        close_testset(rs)
        finalize_testy_state(tls, added_tls)
        delete!(tls, :__TESTCASE_IS_RUNNING__)
    end
end

function initialize_testy_state(tls)
    added_tls = false
    rs = if haskey(tls, :__TESTY_STATE__)
        tls[:__TESTY_STATE__]
    else
        added_tls = true
        val = XUnitState()
        tls[:__TESTY_STATE__] = val
        val
    end
    return added_tls, rs
end

function finalize_testy_state(tls, added_tls)
    added_tls && delete!(tls, :__TESTY_STATE__)
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
    task_local_storage(:__TESTY_STATE__, state) do
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
        @eval Main begin
            # Construct a new throw-away module in which to run the tests
            # (see https://github.com/RelationalAI-oss/XUnit.jl/issues/2)
            m = @eval Main module $(gensym("XUnitModule")) end  # e.g. Main.##XUnitModule#365
            # Perform the include inside the new module m
            m.include($filepath)
        end
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
export TestRunner, SequentialTestRunner, ShuffledTestRunner, ParallelTestRunner

end
