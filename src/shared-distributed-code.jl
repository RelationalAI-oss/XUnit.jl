module SharedDistributedCode

using Distributed
using Test
using ExceptionUnwrapping: has_wrapped_exception
using XUnit

function do_work(jobs, results) # define work function everywhere
    try
        tls = task_local_storage()
        if Main.GLOBAL_HAS_XUNIT_STATE
            tls[:__XUNIT_STATE__] = Main.GLOBAL_XUNIT_STATE
        end
        attempt_cnt = 1
        # we wait until either tests get scheduled (indicated by `Main.__SCHEDULED_DISTRIBUTED_TESTS__`)
        # or at least tried to get scheduled (indicated by `Main.__RUN_DISTRIBUTED_TESTS_CALLED__`)
        while !isdefined(Main, :__SCHEDULED_DISTRIBUTED_TESTS__) &&
              !isdefined(Main, :__RUN_DISTRIBUTED_TESTS_CALLED__)
            @info "Main.__SCHEDULED_DISTRIBUTED_TESTS__ IS NOT still defined on process $(myid())."
            @info "Sleeping for a second (attempt #$(attempt_cnt))."
            sleep(1)
            attempt_cnt += 1
        end
        # If the test scheduling code encounters an error, then `Main.__RUN_DISTRIBUTED_TESTS_CALLED__`
        # is defined but `Main.__SCHEDULED_DISTRIBUTED_TESTS__` won't be available.
        @assert isdefined(Main, :__SCHEDULED_DISTRIBUTED_TESTS__) "Main.__SCHEDULED_DISTRIBUTED_TESTS__ IS NOT defined on process $(myid())"
        scheduled_tests = Main.__SCHEDULED_DISTRIBUTED_TESTS__

        task_count = 0
        while true
            (scheduled_tests_index, scheduled_test_name) = take!(jobs)
            scheduled_tests_index < 1 && break
            if scheduled_tests_index > length(scheduled_tests)
                throw("scheduled_tests_index ($scheduled_tests_index) is outside of bound for scheduled_tests (with $(length(scheduled_tests)) elements)")
            end

            task_count += 1

            println("Process $(myid()) is handling task #$(task_count) (which is $(scheduled_tests_index)/$(length(scheduled_tests)))")

            st = scheduled_tests[scheduled_tests_index]
            try
                if st.target_testcase.testset_report.description != scheduled_test_name
                    println("A critical test scheduling error:")
                    println("  st.target_testcase.testset_report.description (\"$(st.target_testcase.testset_report.description)\") != scheduled_test_name (\"$(scheduled_test_name)\")")
                    println("List of scheduled tests on worker #$(myid()):")
                    for (i, tst) in enumerate(scheduled_tests)
                        println("$i ==> $(tst.target_testcase.testset_report.description)")
                    end
                    put!(jobs, (scheduled_tests_index, scheduled_test_name))
                    break
                end

                if XUnit.TESTSET_PRINT_ENABLE[]
                    path = XUnit._get_path(vcat(st.parent_testsets, [st.target_testcase]))
                    std_io = IOBuffer()
                    print(std_io, "-> Running ")
                    printstyled(std_io, path; bold=true)
                    println(std_io, string(" test-case (on pid=", myid(), ")..."))
                    seekstart(std_io)
                    # thread-safe print
                    print(read(std_io, String))
                end

                XUnit.run_single_testcase(st.parent_testsets, st.target_testcase)

                put!(results, (
                    scheduled_tests_index,
                    XUnit.DistributedAsyncTestMessage(st.target_testcase),
                    myid(),
                ))
            catch err
                has_wrapped_exception(err, InterruptException) && rethrow()

                println("A critical error occued while running '$scheduled_test_name': ", err)
                for s in stacktrace(catch_backtrace())
                    println(s)
                end

                # something in the test block threw an error. Count that as an
                # error in this test set
                ts = st.target_testcase.testset_report.reporting_test_set[]
                Test.record(
                    ts,
                    Test.Error(
                        :nontest_error,
                        Expr(:tuple),
                        err,
                        Base.catch_stack(),
                        st.target_testcase.source
                    )
                )

                put!(results, (
                    scheduled_tests_index,
                    XUnit.DistributedAsyncTestMessage(st.target_testcase),
                    myid(),
                ))
            end
        end
        println("Process $(myid()) is done with handling task after running $(task_count) tasks (out of $(length(scheduled_tests)))")
    catch err
        has_wrapped_exception(err, InterruptException) && rethrow()

        println("A critical error occued in XUnit while running tests: ", err)
        for s in stacktrace(catch_backtrace())
            println(s)
        end

        # cancel all remaining tests by putting an empty result with index `0`
        put!(results, (0, nothing, myid()))
    end
end

end
