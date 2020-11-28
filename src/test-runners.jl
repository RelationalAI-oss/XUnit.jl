struct SequentialTestRunner <: TestRunner end
struct ShuffledTestRunner <: TestRunner end
struct ParallelTestRunner <: TestRunner end
struct DistributedTestRunner <: TestRunner end

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
        gather_test_metrics(testsuite; run=false)
        save_test_metrics(testsuite)
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

function _run_testsuite(
    ::Type{T},
    testsuite::AsyncTestSuite,
) where T <: DistributedTestRunner
    try
        scheduled_tests = _schedule_tests(T, testsuite)
        tls = task_local_storage()
        already_running = haskey(tls, :__ALREADY_RUNNING_DISTRIBUTED_TESTS__)
        if myid() == 1
            @assert !already_running
            # the main process starts the workers
            try
                tls[:__ALREADY_RUNNING_DISTRIBUTED_TESTS__] = true
                _run_scheduled_tests(T, scheduled_tests)
            finally
                delete!(tls, :__ALREADY_RUNNING_DISTRIBUTED_TESTS__)
            end
            return true
        else
            # each worker processes the scheduled tests (in `SharedDistributedCode.do_work`)
            # The scheduled tests are assigned to a global variable on the worker processes
            @assert !isdefined(Main, :__SCHEDULED_DISTRIBUTED_TESTS__) "Main.__SCHEDULED_DISTRIBUTED_TESTS__ IS defined on process $(myid())"
            Core.eval(Main, Expr(:(=), :__SCHEDULED_DISTRIBUTED_TESTS__, scheduled_tests))

            # returning `false` here means: tests have not been ran
            # the tests will run separately with an orchestration from the main process
            # (cf. `_run_scheduled_tests(::Type{DistributedTestRunner}, ...)`)
            return false
        end
    finally
        # This is a fail-safe to avoid ending up with ghost worker processes waiting for
        # `Main.__SCHEDULED_DISTRIBUTED_TESTS__` to be assigned
        Core.eval(Main, Expr(:(=), :__RUN_DISTRIBUTED_TESTS_CALLED__, true))
    end
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
        save_test_metrics(st.target_testcase)
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
            # writing to metrics collector concurrently might lead to concurrency issues if
            # it's not thread-safe
            @lock METRIC_SAVE_LOCK begin
                save_test_metrics(st.target_testcase)
            end
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
                save_test_metrics(sub_testcase)
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
        run_and_gather_test_metrics(sub_testcase; run=true)
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

# pass variable named `nm` from process `src` to all other `target` processes
function passobj(src::Int, target::AbstractVector{Int}, nm::Symbol; from_mod=Main, to_mod=Main)
    r = RemoteChannel(src)
    @spawnat(src, put!(r, getfield(from_mod, nm)))
    @sync for to in target
        @spawnat(to, Core.eval(to_mod, Expr(:(=), nm, fetch(r))))
    end
    nothing
end

macro passobj(src::Int, target, val, from_mod=:Main, tomod=:Main)
    quote
        passobj($(esc(src)), $(esc(target)), $(QuoteNode(val)); from_mod=$from_mod, to_mod=$tomod)
    end
end

function passobj(src::Int, target::Int, nm::Symbol; from_mod=Main, to_mod=Main)
    passobj(src, [target], nm; from_mod=from_mod, to_mod=to_mod)
end


function passobj(src::Int, target, nms::Vector{Symbol}; from_mod=Main, to_mod=Main)
    for nm in nms
        passobj(src, target, nm; from_mod=from_mod, to_mod=to_mod)
    end
end

function _run_scheduled_tests(
    ::Type{DistributedTestRunner},
    scheduled_tests::Vector{ScheduledTest},
)
    # if we have a single worker, then we run tests sequentially
    if nworkers() == 1
        return _run_scheduled_tests(SequentialTestRunner, scheduled_tests)
    end

    # put `SharedDistributedCode` module under `Main` on all processes
    @everywhere include_string(
        Main,
        $(read(joinpath(@__DIR__, "shared-distributed-code.jl"), String)),
        "shared-distributed-code.jl"
    )

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

    num_tests = length(scheduled_tests)

    # jobs channel contains a list of scheduled test index and name tuples.
    # the assumption is that the same list of tests gets scheduled on all worker processes
    # and each worker process can take one element from this channel and run that specific
    # test in the given index. We also pass the test name to do a double-check and make
    # sure that our assumption (of having the same list of scheduled tests on all processes)
    # is accurate and catch any inconsistencies (due to non-determinism in the test code).
    jobs = RemoteChannel(()->Channel{Tuple{Int,Option{String}}}(num_tests));

    # each element in the results channel is a triple produced by worker processes
    # the triple is (job_id, returned_test_case, worker):
    #  - job_id: is an index from `scheduled_tests` or `0` (if an error occurs with a worker process)
    #  - returned_test_case: is a simplified `AsyncTestCase` (as `DistributedAsyncTestMessage`)
    #                        or `nothing` (if an error occurs with a worker process)
    #  - worker: the worker index (returned by `myid()` on the worker process)
    results = RemoteChannel(
        () -> Channel{Tuple{Int,Option{DistributedAsyncTestMessage},Int}}(
            num_tests + nworkers() # as each worker process might also produce a failure message
        )
    );

    n = num_tests

    # create jobs for worker processes to handle
    function make_jobs(scheduled_tests, num_workers::Int)
        last_i = 0
        try
            println("List of scheduled tests on master:")
            for (i, tst) in enumerate(scheduled_tests)
                put!(jobs, (i, tst.target_testcase.testset_report.description))
                println("$i => $(tst.target_testcase.testset_report.description)")
                last_i = i
            end
        finally
            # at the end of all jobs, we put a sentinel for each worker process to know that
            # it can peacefully die, as there will not be any further tests to run
            for i in 1:num_workers
                put!(jobs, (-1, nothing))
            end
        end
    end

    # feed the jobs channel with "n" jobs
    @async_with_error_log make_jobs(scheduled_tests, nworkers());

    function start_worker_processes(jobs, results)
        # Here, we first make sure that all workers are ready before giving them any task
        # Otherwise, there is a possibility of getting into a Julia `world age` issue
        ready_workers = Set{Int}()
        worker_state_futures = map(p -> (p, remotecall(
            () -> begin
                while !isdefined(Main, :__SCHEDULED_DISTRIBUTED_TESTS__) &&
                      !isdefined(Main, :__RUN_DISTRIBUTED_TESTS_CALLED__)
                    sleep(1)
                end
                return true
            end, p)),
            workers(),
        )

        while true
            for (p, worker_state) in worker_state_futures
                if !(p in ready_workers) && isready(worker_state)
                    @assert fetch(worker_state)
                    println("Worker #$p is ready to start processing test-cases.")
                    # start tasks on the workers to process requests in parallel
                    remote_do(Main.SharedDistributedCode.do_work, p, jobs, results)
                    push!(ready_workers, p)
                end
            end
            length(ready_workers) == nworkers() && break
            sleep(1)
        end
    end

    # start the worker processes to handle the jobs and produce results
    @async_with_error_log start_worker_processes(jobs, results)

    handled_scheduled_tests = falses(length(scheduled_tests))

    while n > 0 # collect results
        job_id, returned_test_case, worker = take!(results)

        # `job_id == 0` means that a critical error occurred with one of worker processes
        # then, we stop testing here and report results early by showing an error for all
        # remaining tests
        # Note: if some worker processes are still alive, they might continue processing
        #       tests, but their produced results are not consumed anymore.
        #       One approach to improve this is by limitting the size of `results` channel.
        if job_id == 0
            for (job_id, ishandled) in enumerate(handled_scheduled_tests)
                if !ishandled
                    orig_test_case = scheduled_tests[job_id].target_testcase
                    ts = orig_test_case.testset_report.reporting_test_set[]
                    Test.record(ts, Test.Error(
                        :nontest_error,
                        Expr(:tuple),
                        "An error occurred in the worker test-runner process.",
                        Base.catch_stack(),
                        orig_test_case.source
                    ))
                end
            end
            break
        else
            # mark test as handled
            handled_scheduled_tests[job_id] = true
        end

        # update the test-case on the main process with the results returned from the worker
        orig_test_case = scheduled_tests[job_id].target_testcase
        if returned_test_case !== nothing
            orig_test_case.testset_report = returned_test_case.testset_report
            orig_test_case.sub_testsuites = map(msg -> AsyncTestSuite(orig_test_case, msg), returned_test_case.sub_testsuites)
            orig_test_case.sub_testcases = map(msg -> AsyncTestCase(orig_test_case, msg), returned_test_case.sub_testcases)
            orig_test_case.metrics = returned_test_case.metrics
            save_test_metrics(orig_test_case)
        end

        n = n - 1
    end
end

# A simplified version of `AsyncTestCase` that can be safely transferred between processes
#
# Note: functions and exceptions are not safe to be transferred between processes
struct DistributedAsyncTestMessage
    testset_report::AbstractTestSet
    source::LineNumberNode
    disabled::Bool
    sub_testsuites::Vector{DistributedAsyncTestMessage}
    sub_testcases::Vector{DistributedAsyncTestMessage}
    metrics::Option{TestMetrics}
end

function DistributedAsyncTestMessage(t::AsyncTestSuiteOrTestCase)
    return DistributedAsyncTestMessage(
        convert_results_to_be_transferrable(t.testset_report),
        t.source,
        t.disabled,
        map(DistributedAsyncTestMessage, t.sub_testsuites),
        map(DistributedAsyncTestMessage, t.sub_testcases),
        t.metrics,
    )
end

function AsyncTestCase(parent::AsyncTestSuiteOrTestCase, msg::DistributedAsyncTestMessage)
    t = AsyncTestCase(
        () -> nothing,
        msg.testset_report,
        msg.source,
        parent;
        disabled=msg.disabled,
        metrics=msg.metrics,
    )

    for sub_testsuite in msg.sub_testsuites
        AsyncTestSuite(t, sub_testsuite) # the returned test-suite is already registered with its parent
    end

    for sub_testcase in msg.sub_testcases
        AsyncTestCase(t, sub_testcase) # the returned test-suite is already registered with its parent
    end

    return t
end

function AsyncTestSuite(parent::AsyncTestSuiteOrTestCase, msg::DistributedAsyncTestMessage)
    t = AsyncTestSuite(
        msg.testset_report,
        msg.source,
        parent;
        disabled=msg.disabled,
        metrics=msg.metrics,
    )

    for sub_testsuite in msg.sub_testsuites
        AsyncTestSuite(t, sub_testsuite) # the returned test-suite is already registered with its parent
    end

    for sub_testcase in msg.sub_testcases
        AsyncTestCase(t, sub_testcase) # the returned test-suite is already registered with its parent
    end

    return t
end

"""
    convert_results_to_be_transferrable(x)

Converts the results of a testset to be transferrable between processes

Basically, any code or struct that is process-specific (i.e., related to the tests that
ran on a specific process) is not transferrable between processes. This function converts
any possible data of this kind in the results to simpler common types (e.g., String)
"""
function convert_results_to_be_transferrable(x)
    return x
end

function convert_results_to_be_transferrable(ts::AbstractTestSet)
    results_copy = copy(ts.results)
    empty!(ts.results)
    for t in results_copy
        push!(ts.results, convert_results_to_be_transferrable(t))
    end
    return ts
end

function convert_results_to_be_transferrable(ts::RichReportingTestSet)
    convert_results_to_be_transferrable(ts.reporting_test_set[])
    return ts
end

function convert_results_to_be_transferrable(res::Pass)
    if res.test_type == :test_throws
        # A passed `@test_throws` contains the stacktrace for the (correctly) thrown exception
        # This exception might contain references to some types that are not available
        # on other processes (e.g., the master process that consolidates the results)
        # The stack-trace is converted to string here.
        return Pass(:test_throws, nothing, nothing, string(res.value))
    end
    return res
end
