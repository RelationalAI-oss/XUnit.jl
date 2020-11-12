module SharedDistributedCode

using Distributed
using Test
using ExceptionUnwrapping: has_wrapped_exception
import XUnit

function do_work(jobs, results) # define work function everywhere
    try
        tls = task_local_storage()
        if Main.GLOBAL_HAS_XUNIT_STATE
            tls[:__XUNIT_STATE__] = Main.GLOBAL_XUNIT_STATE
        end
        attempt_cnt = 1
        while !isdefined(Main, :__SCHEDULED_DISTRIBUTED_TESTS__) && !isdefined(Main, :__RUN_DISTRIBUTED_TESTS_CALLED__)
            @info "Main.__SCHEDULED_DISTRIBUTED_TESTS__ IS NOT still defined on process $(myid())."
            @info "Sleeping for a second (attempt #$(attempt_cnt))."
            sleep(1)
            attempt_cnt += 1
        end
        @assert isdefined(Main, :__SCHEDULED_DISTRIBUTED_TESTS__) "Main.__SCHEDULED_DISTRIBUTED_TESTS__ IS NOT defined on process $(myid())"
        scheduled_tests = Main.__SCHEDULED_DISTRIBUTED_TESTS__

        task_count = 0
        while true
            (scheduled_tests_index, scheduled_test_name) = take!(jobs)
            scheduled_tests_index < 1 && break
            task_count += 1

            println("Process $(myid()) is handling task #$(task_count) (which is $(scheduled_tests_index)/$(length(scheduled_tests)))")

            st = scheduled_tests[scheduled_tests_index]
            try
                @assert st.target_testcase.testset_report.description == scheduled_test_name "st.target_testcase.testset_report.description (\"$(st.target_testcase.testset_report.description)\") != scheduled_test_name (\"$(scheduled_test_name)\")"

                if Test.TESTSET_PRINT_ENABLE[]
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
            catch e
                has_wrapped_exception(e, InterruptException) && rethrow()

                println("A critical error occued in while running '$scheduled_test_name': ", e)
                for s in stacktrace(catch_backtrace())
                    println(s)
                end

                # something in the test block threw an error. Count that as an
                # error in this test set
                ts = st.target_testcase.testset_report.reporting_test_set[]
                record(ts, Test.Error(:nontest_error, Expr(:tuple), e, Base.catch_stack(), st.target_testcase.source))
                put!(results, (
                    scheduled_tests_index,
                    XUnit.DistributedAsyncTestMessage(st.target_testcase),
                    myid(),
                ))
            end
        end
        println("Process $(myid()) is done with handling task after running $(task_count) tasks (out of $(length(scheduled_tests)))")
    catch e
        has_wrapped_exception(e, InterruptException) && rethrow()

        println("A critical error occued in XUnit while running tests: ", e)
        for s in stacktrace(catch_backtrace())
            println(s)
        end

        while true
            put!(results, (0, nothing, myid()))
        end
    end
end

end
