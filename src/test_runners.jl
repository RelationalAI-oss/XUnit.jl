abstract type TestRunner end
struct SequentialTestRunner <: TestRunner end
struct ShuffledTestRunner <: TestRunner end
struct ParallelTestRunner <: TestRunner end

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
    return testsuite
end

function _get_path(testsuite_stack)
    join(map(testsuite -> testsuite.testset_report.description, testsuite_stack), "/")
end
