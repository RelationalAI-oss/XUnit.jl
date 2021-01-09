struct SequentialTestRunner <: TestRunner end
struct ShuffledTestRunner <: TestRunner end
struct ParallelTestRunner <: TestRunner end
struct DistributedTestRunner <: TestRunner end

# Runs a Scheduled Test-Suite
function run_testset(
    ::Type{T},
    testset::AsyncTestSuiteOrTestCase;
    throw_on_error::Bool=true,
    show_stdout::Bool=TESTSET_PRINT_ENABLE[],
) where T <: TestRunner
    return run_testset(
        testset, T;
        throw_on_error=throw_on_error, show_stdout=show_stdout
    )
end

function run_testset(
    testset::AsyncTestSuiteOrTestCase,
    ::Type{T}=typeof(testset.runner);
    throw_on_error::Bool=true,
    show_stdout::Bool=TESTSET_PRINT_ENABLE[],
)::Bool where {T <: TestRunner}
    # if `_run_testset` returns false, then we do not proceed with finalizing the report
    # as it means that tests haven't ran and will run seprately
    if _run_testset(T, testset)
        _finalize_reports(testset)
        gather_test_metrics(testset)
        save_test_metrics(testset)
        if show_stdout
            display_reporting_testset(testset, throw_on_error=false)
        end

        testset.xml_report && xml_report(testset)
        testset.html_report && html_report(testset)

        if throw_on_error
            prev_TESTSET_PRINT_ENABLE = TESTSET_PRINT_ENABLE[]
            TESTSET_PRINT_ENABLE[] = false
            try
                _swallow_all_outputs() do # test results are already printed. Let's avoid printing the errors twice.
                    display_reporting_testset(testset; throw_on_error=true)
                end
            catch e
                testset.failure_handler(testset)
                rethrow()
            finally
                TESTSET_PRINT_ENABLE[] = prev_TESTSET_PRINT_ENABLE
            end
        end

        testset.success_handler(testset)

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

function _run_testset(
    ::Type{T},
    testset::AsyncTestSuiteOrTestCase,
) where T <: TestRunner
    scheduled_tests = _schedule_tests(T, testset)
    _run_scheduled_tests(T, scheduled_tests)
    return true
end

function _run_testset(
    ::Type{T},
    testset::AsyncTestSuite,
) where T <: DistributedTestRunner
    try
        scheduled_tests = _schedule_tests(T, testset)
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
            if isdefined(Main, :__SCHEDULED_DISTRIBUTED_TESTS__)
                @warn "Main.__SCHEDULED_DISTRIBUTED_TESTS__ IS ALREADY defined on process $(myid())"
            end
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
    testset::AsyncTestSuite,
    testcases_acc::Vector{ScheduledTest}=ScheduledTest[],
    parent_testsets::Vector{AsyncTestSuite}=AsyncTestSuite[]
) where T <: TestRunner
    parent_testsets = copy(parent_testsets)
    push!(parent_testsets, testset)
    for sub_testset in testset.sub_testsets
        if !sub_testset.disabled
            _schedule_tests(T, sub_testset, testcases_acc, parent_testsets)
        end
    end

    for sub_testcase in testset.sub_testcases
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
    testset::AsyncTestSuite,
    testcases_acc::Vector{ScheduledTest}=ScheduledTest[],
    parent_testsets::Vector{AsyncTestSuite}=AsyncTestSuite[]
)
    seq_testcases = _schedule_tests(SequentialTestRunner, testset, testcases_acc, parent_testsets)
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

function _run_testset(
    ::Type{SequentialTestRunner},
    testset::AsyncTestSuite,
    parent_testsets::Vector{AsyncTestSuite}=AsyncTestSuite[]
)
    parent_testsets = vcat(parent_testsets, [testset])
    suite_path = _get_path(parent_testsets)
    if !testset.disabled
        if TESTSET_PRINT_ENABLE[]
            print("Running ")
            printstyled(suite_path; bold=true)
            println(" test-suite...")
        end
        for sub_testset in testset.sub_testsets
            if TESTSET_PRINT_ENABLE[]
                print("  "^length(parent_testsets))
            end
            _run_testset(SequentialTestRunner, sub_testset, parent_testsets)
        end

        for sub_testcase in testset.sub_testcases
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
    for testset in parents_with_this
        ts = testset.testset_report
        push!(rs.stack, get_description(ts))
        push!(rs.test_suites_stack, testset)
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

        for testset in parent_testsets
            testset.before_each_hook()
        end
        run_and_gather_test_metrics(sub_testcase; run=true)
        for testset in reverse(parent_testsets)
            testset.after_each_hook()
        end
    catch err
        has_wrapped_exception(err, InterruptException) && rethrow()
        # something in the test block threw an error. Count that as an
        # error in this test set
        ts = sub_testcase.testset_report
        XUnit.record(ts, Test.Error(:nontest_error, Expr(:tuple), err, Base.catch_stack(), sub_testcase.source))
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

function _get_path(testset_stack)
    join(map(testset -> get_description(testset), testset_stack), "/")
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
    err = gensym("err")
    return esc(quote
        $Base.Threads.@async try
            $(expr)
        catch $err
            $Base.@error "@async_with_error_log failed: $($message)" $err
            $showerror(stderr, $err, $catch_backtrace())
            rethrow()
        end
    end)
end

function _finalize_reports(testset::TEST_SUITE)::TEST_SUITE where TEST_SUITE <: AsyncTestSuite
    Test.push_testset(testset.testset_report)
    try
        for sub_testset in testset.sub_testsets
            _finalize_reports(sub_testset)
        end

        for sub_testcase in testset.sub_testcases
            _finalize_reports(sub_testcase)
        end
    finally
        Test.pop_testset()
    end

    Test.finish(testset.testset_report)
    return testset
end

function _finalize_reports(testcase::TEST_CASE)::TEST_CASE where TEST_CASE <: AsyncTestCase
    Test.push_testset(testcase.testset_report)
    try
        for sub_testset in testcase.sub_testsets
            _finalize_reports(sub_testset)
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
                put!(jobs, (i, get_description(tst)))
                println("$i => $(get_description(tst))")
                last_i = i
            end
        finally
            # At the end of all jobs, we put a sentinel for each worker process to know that
            # it can peacefully die, as there will not be any further tests to run
            # In addition, we also add one more sentinel for the main process to consume
            # in the even of a critical failure in a worker to be able to drain the
            # remaining jobs (so that the remaining healthy workers will not continue
            # processing the remaining tests)
            for i in 1:(num_workers+1)
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
        #       That's why the main process first tries to drain the whole `jobs` channel.
        if job_id == 0
            while true
                (scheduled_tests_index, _) = take!(jobs)
                scheduled_tests_index == -1 && break
            end
            for (job_id, ishandled) in enumerate(handled_scheduled_tests)
                if !ishandled
                    orig_test_case = scheduled_tests[job_id].target_testcase
                    ts = orig_test_case.testset_report.reporting_test_set[]
                    XUnit.record(ts, Test.Error(
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
            orig_test_case.sub_testsets = map(msg -> AsyncTestSuite(orig_test_case, msg), returned_test_case.sub_testsets)
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
    sub_testsets::Vector{DistributedAsyncTestMessage}
    sub_testcases::Vector{DistributedAsyncTestMessage}
    metrics::Option{TestMetrics}
end

function DistributedAsyncTestMessage(t::AsyncTestSuiteOrTestCase)
    return DistributedAsyncTestMessage(
        convert_results_to_be_transferrable(t.testset_report),
        t.source,
        t.disabled,
        map(DistributedAsyncTestMessage, t.sub_testsets),
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

    for sub_testset in msg.sub_testsets
        AsyncTestSuite(t, sub_testset) # the returned test-suite is already registered with its parent
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

    for sub_testset in msg.sub_testsets
        AsyncTestSuite(t, sub_testset) # the returned test-suite is already registered with its parent
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
