struct SequentialTestRunner <: TestRunner end
struct ShuffledTestRunner <: TestRunner end
struct ParallelTestRunner <: TestRunner end

# Runs a Scheduled Test-Suite
function run_testsuite(
    ::Type{T},
    testsuite::AsyncTestSuiteOrTestCase;
    throw_on_error::Bool=true,
    show_stdout::Bool=TESTSET_PRINT_ENABLE[],
) where T <: TestRunner
    return run_testsuite(
        testsuite, T;
        throw_on_error=throw_on_error, show_stdout=show_stdout
    )
end

function run_testsuite(
    testsuite::AsyncTestSuiteOrTestCase,
    ::Type{T}=typeof(testsuite.runner);
    throw_on_error::Bool=true,
    show_stdout::Bool=TESTSET_PRINT_ENABLE[],
)::Bool where {T <: TestRunner}
    # if `_run_testsuite` returns false, then we do not proceed with finalizing the report
    # as it means that tests haven't ran and will run seprately
    if _run_testsuite(T, testsuite)
        _finalize_reports(testsuite)
        if show_stdout
            display_reporting_testset(testsuite, throw_on_error=false)
        end

        testsuite.xml_report && xml_report(testsuite)
        testsuite.html_report && html_report(testsuite)

        if throw_on_error
            _swallow_all_outputs() do # test results are already printed. Let's avoid printing the errors twice.
                prev_TESTSET_PRINT_ENABLE = TESTSET_PRINT_ENABLE[]
                TESTSET_PRINT_ENABLE[] = false
                try
                    # throw an exception is any test failed or errored
                    display_reporting_testset(testsuite; throw_on_error=true)
                catch
                    testsuite.failure_handler(testsuite)
                    rethrow()
                finally
                    TESTSET_PRINT_ENABLE[] = prev_TESTSET_PRINT_ENABLE
                end
            end
        end

        testsuite.success_handler(testsuite)

        return true
    end
    return false
end

# captures all standard outputs of the given function
function _swallow_all_outputs(dofunc::Function)
    Filesystem.mktemp() do out_path, out
        Filesystem.mktemp() do err_path, err
            redirect_stdout(out) do
                redirect_stderr(err) do
                    dofunc()
                end
            end
        end
    end
end

function _run_testsuite(
    ::Type{T},
    testsuite::AsyncTestSuiteOrTestCase,
) where T <: TestRunner
    scheduled_tests = _schedule_tests(T, testsuite)
    _run_scheduled_tests(T, scheduled_tests)
    return true
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
    ::Type{T},
    testcase::AsyncTestCase,
    testcases_acc::Vector{ScheduledTest}=ScheduledTest[],
    parent_testsets::Vector{AsyncTestSuite}=AsyncTestSuite[]
) where T <: TestRunner
    parent_testsets = copy(parent_testsets)

    if !testcase.disabled
        st = ScheduledTest(parent_testsets, testcase)
        push!(testcases_acc, st)
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
        if TESTSET_PRINT_ENABLE[]
            path = _get_path(vcat(st.parent_testsets, [st.target_testcase]))
            print("* Running ")
            printstyled(path; bold=true)
            println(" test-case...")
        end
        run_single_testcase(st.parent_testsets, st.target_testcase)
    end
end

const METRIC_SAVE_LOCK = ReentrantLock()

function _run_scheduled_tests(
    ::Type{ParallelTestRunner},
    scheduled_tests::Vector{ScheduledTest},
)
    scheduled_tests_index = Threads.Atomic{Int}(length(scheduled_tests));

    # make sure to pass the test-state to the underlying threads (mostly for test filtering)
    parent_thread_tls = task_local_storage()
    has_xunit_state = haskey(parent_thread_tls, :__XUNIT_STATE__)
    xunit_state = has_xunit_state ? parent_thread_tls[:__XUNIT_STATE__] : nothing

    @threads for tid in 1:Threads.nthreads()
        tls = task_local_storage()
        if has_xunit_state
            tls[:__XUNIT_STATE__] = create_deep_copy(xunit_state)
        end
        while true
            i = (Threads.atomic_sub!(scheduled_tests_index, 1))
            i <= 0 && break

            st = scheduled_tests[i]
            if TESTSET_PRINT_ENABLE[]
                path = _get_path(vcat(st.parent_testsets, [st.target_testcase]))
                std_io = IOBuffer()
                print(std_io, "-> Running ")
                printstyled(std_io, path; bold=true)
                println(std_io, " test-case (on tid=$tid)...")
                seekstart(std_io)
                # thread-safe print
                print(read(std_io, String))
            end
            run_single_testcase(st.parent_testsets, st.target_testcase)
        end
    end
end

function _run_testsuite(
    ::Type{SequentialTestRunner},
    testsuite::AsyncTestSuite,
    parent_testsets::Vector{AsyncTestSuite}=AsyncTestSuite[]
)
    parent_testsets = vcat(parent_testsets, [testsuite])
    suite_path = _get_path(parent_testsets)
    if !testsuite.disabled
        if TESTSET_PRINT_ENABLE[]
            print("Running ")
            printstyled(suite_path; bold=true)
            println(" test-suite...")
        end
        for sub_testsuite in testsuite.sub_testsuites
            if TESTSET_PRINT_ENABLE[]
                print("  "^length(parent_testsets))
            end
            _run_testsuite(SequentialTestRunner, sub_testsuite, parent_testsets)
        end

        for sub_testcase in testsuite.sub_testcases
            if TESTSET_PRINT_ENABLE[]
                print("  "^length(parent_testsets))
            end
            path = _get_path(vcat(parent_testsets, [sub_testcase]))
            if !sub_testcase.disabled
                if TESTSET_PRINT_ENABLE[]
                    print("Running ")
                    printstyled(path; bold=true)
                    println(" test-case...")
                end
                run_single_testcase(parent_testsets, sub_testcase)
            elseif TESTSET_PRINT_ENABLE[]
                printstyled("Skipping $path test-case...\n"; color=:light_black)
            end
        end
    elseif TESTSET_PRINT_ENABLE[]
        printstyled("Skipping $suite_path test-suite...\n"; color=:light_black)
    end
    return true
end

function run_single_testcase(
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

    added_tls, rs = initialize_xunit_tls_state(tls)

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

    has_saved_source_path = haskey(tls, :SOURCE_PATH)
    saved_source_path = has_saved_source_path ? tls[:SOURCE_PATH] : nothing
    try
        # RNG is re-seeded with its own seed to ease reproduce a failed test
        Random.seed!(RNG.seed)

        # we change the source path directory to the path of the test-case to make its
        # direct `include`s (if any) work correctly
        testcase_path = string(sub_testcase.source.file)
        if ispath(testcase_path)
            tls[:SOURCE_PATH] = testcase_path
        end

        for testsuite in parent_testsets
            testsuite.before_each_hook()
        end
        sub_testcase.test_fn()
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
        finalize_xunit_tls_state(tls, added_tls)
        delete!(tls, :__TESTCASE_IS_RUNNING__)

        # restore the saved source path
        if has_saved_source_path
            tls[:SOURCE_PATH] = saved_source_path
        else
            delete!(tls, :SOURCE_PATH)
        end
    end
end

function _get_path(testsuite_stack)
    join(map(testsuite -> testsuite.testset_report.description, testsuite_stack), "/")
end

"""
    @async_with_error_log expr
    @async_with_error_log "..error msg.." expr

Exactly like `@async`, except that it wraps `expr` in a try/catch block that will print any
exceptions that are thrown from the `expr` to stderr, via `@error`. You can
optionally provide an error message that will be printed before the exception is displayed.

This is useful if you need to asynchronously run a "background task", whose result will
never be waited-on nor fetched-from.
"""
macro async_with_error_log(expr)
    _async_with_error_log_expr(expr)
end
macro async_with_error_log(message, expr)
    _async_with_error_log_expr(expr, message)
end
function _async_with_error_log_expr(expr, message="")
    e = gensym("err")
    return esc(quote
        $Base.Threads.@async try
            $(expr)
        catch $e
            $Base.@error "@async_with_error_log failed: $($message)" $e
            $showerror(stderr, $e, $catch_backtrace())
            rethrow()
        end
    end)
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
