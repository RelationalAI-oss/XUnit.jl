using Distributed #for DistributedTestRunner

abstract type TestRunner end
struct SequentialTestRunner <: TestRunner end
struct ShuffledTestRunner <: TestRunner end
struct ParallelTestRunner <: TestRunner end
struct DistributedTestRunner <: TestRunner end

# Runs a Scheduled Test-Suite
function run_testsuite(::Type{T}, testsuite::AsyncTestSuite) where T <: TestRunner
    return run_testsuite(testsuite, T)
end

function run_testsuite(
    testsuite::TEST_SUITE,
    ::Type{T}=SequentialTestRunner
)::Bool where {T <: TestRunner, TEST_SUITE <: AsyncTestSuite}
    if _run_testsuite(T, testsuite)
        _finalize_reports(testsuite)
        gather_test_metrics(testsuite)
        return true
    end
    return false
end

function _run_testsuite(
    ::Type{T},
    testsuite::AsyncTestSuite,
) where T <: TestRunner
    scheduled_tests = _schedule_tests(T, testsuite)
    _run_scheduled_tests(T, scheduled_tests)
    return true
end

function _run_testsuite(
    ::Type{T},
    testsuite::AsyncTestSuite,
) where T <: DistributedTestRunner
    scheduled_tests = _schedule_tests(T, testsuite)
    tls = task_local_storage()
    already_running = haskey(tls, :__ALREADY_RUNNING_DISTRIBUTED_TESTS__)
    if myid() == 1
        @assert !already_running
        try
            tls[:__ALREADY_RUNNING_DISTRIBUTED_TESTS__] = true
            _run_scheduled_tests(T, scheduled_tests)
        finally
            delete!(tls, :__ALREADY_RUNNING_DISTRIBUTED_TESTS__)
        end
        return true
    else
        @assert !isdefined(Main, :__SCHEDULED_DISTRIBUTED_TESTS__) "Main.__SCHEDULED_DISTRIBUTED_TESTS__ IS defined on process $(myid())"
        Core.eval(Main, Expr(:(=), :__SCHEDULED_DISTRIBUTED_TESTS__, scheduled_tests))
    end

    return false
end

mutable struct ScheduledTest
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
            path = _get_path(vcat(st.parent_testsets, [st.target_testcase]))
            print("* Running ")
            printstyled(path; bold=true)
            println(" test-case...")
        end
        run_single_testcase(st.parent_testsets, st.target_testcase)
    end
end

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
            if Test.TESTSET_PRINT_ENABLE[]
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
            path = _get_path(vcat(parent_testsets, [sub_testcase]))
            if !sub_testcase.disabled
                if Test.TESTSET_PRINT_ENABLE[]
                    print("Running ")
                    printstyled(path; bold=true)
                    println(" test-case...")
                end
                run_single_testcase(parent_testsets, sub_testcase)
            elseif Test.TESTSET_PRINT_ENABLE[]
                printstyled("Skipping $path test-case...\n"; color=:light_black)
            end
        end
    elseif Test.TESTSET_PRINT_ENABLE[]
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

    added_tls, rs = initialize_xunit_state(tls)

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
        gather_test_metrics(sub_testcase)
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
        finalize_xunit_state(tls, added_tls)
        delete!(tls, :__TESTCASE_IS_RUNNING__)
    end
end

function _get_path(testsuite_stack)
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
    @everywhere include_string(Main, $(read(joinpath(@__DIR__, "shared_distributed_code.jl"), String)), "shared_distributed_code.jl")

    # if we have a single worker, then we run tests sequentially
    if nworkers() == 1
        return _run_scheduled_tests(SequentialTestRunner, scheduled_tests)
    end

    # make sure to pass the test-state to the underlying threads (mostly for test filtering)
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
    Core.eval(Main, Expr(:(=), :GLOBAL_SCHEDULED_TESTS, scheduled_tests))

    @passobj 1 workers() GLOBAL_HAS_XUNIT_STATE
    @passobj 1 workers() GLOBAL_XUNIT_STATE
    @passobj 1 workers() GLOBAL_SCHEDULED_TESTS

    num_tests = length(scheduled_tests)

    jobs = RemoteChannel(()->Channel{Tuple{Int,Option{String}}}(num_tests));

    results = RemoteChannel(
        () -> Channel{Tuple{Int,Option{DistributedAsyncTestMessage},Int}}(num_tests)
    );

    n = num_tests

    function make_jobs(scheduled_tests)
        last_i = 0
        try
            for (i, tst) in enumerate(scheduled_tests)
                put!(jobs, (i, tst.target_testcase.testset_report.description))
                last_i = i
            end
        catch e
            for i in last_i:length(scheduled_tests)
                put!(jobs, (i, nothing))
            end
        end
    end

    @async make_jobs(scheduled_tests); # feed the jobs channel with "n" jobs

    for p in workers() # start tasks on the workers to process requests in parallel
        remote_do(Main.SharedDistributedCode.do_work, p, jobs, results)
    end

    while n > 0 # collect results
        job_id, returned_test_case, worker = take!(results)

        job_id == 0 && break

        orig_test_case = scheduled_tests[job_id].target_testcase
        if returned_test_case !== nothing
            orig_test_case.testset_report = returned_test_case.testset_report
            orig_test_case.sub_testsuites = map(msg -> AsyncTestSuite(orig_test_case, msg), returned_test_case.sub_testsuites)
            orig_test_case.sub_testcases = map(msg -> AsyncTestCase(orig_test_case, msg), returned_test_case.sub_testcases)
            orig_test_case.metrics = returned_test_case.metrics
        end

        n = n - 1
    end
end

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
        t.testset_report,
        t.source,
        t.disabled,
        map(DistributedAsyncTestMessage, t.sub_testsuites),
        map(DistributedAsyncTestMessage, t.sub_testcases),
        t.metrics,
    )
end

function AsyncTestCase(parent, msg::DistributedAsyncTestMessage)
    t = AsyncTestCase(
        msg.testset_report,
        parent,
        () -> nothing,
        msg.source,
        msg.disabled,
        AsyncTestSuite[],
        AsyncTestCase[],
        ReentrantLock(),
        msg.metrics,
    )

    for sub_testsuite in msg.sub_testsuites
        push!(parent.sub_testsuites, AsyncTestSuite(t, sub_testsuite))
    end

    for sub_testcase in msg.sub_testcases
        push!(parent.sub_testcases, AsyncTestCase(t, sub_testcase))
    end

    return t
end

function AsyncTestSuite(parent::AsyncTestSuiteOrTestCase, msg::DistributedAsyncTestMessage)
    t = AsyncTestSuite(
        msg.testset_report,
        parent,
        () -> nothing,
        AsyncTestSuite[],
        AsyncTestCase[],
        () -> nothing,
        msg.disabled,
        ReentrantLock(),
        msg.source,
        msg.metrics,
    )

    for sub_testsuite in msg.sub_testsuites
        push!(parent.sub_testsuites, AsyncTestSuite(t, sub_testsuite))
    end

    for sub_testcase in msg.sub_testcases
        push!(parent.sub_testcases, AsyncTestCase(t, sub_testcase))
    end

    return t
end

export DistributedTestRunner
