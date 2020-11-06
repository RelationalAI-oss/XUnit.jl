module SharedDistributedCode

using Distributed
using Test
import XUnit

function do_work(jobs, results) # define work function everywhere
    try
        tls = task_local_storage()
        if Main.GLOBAL_HAS_XUNIT_STATE
            tls[:__XUNIT_STATE__] = Main.GLOBAL_XUNIT_STATE
        end
        @assert isdefined(Main, :__SCHEDULED_DISTRIBUTED_TESTS__) "Main.__SCHEDULED_DISTRIBUTED_TESTS__ IS NOT defined on process $(myid())"
        scheduled_tests = Main.__SCHEDULED_DISTRIBUTED_TESTS__

        while true
            (scheduled_tests_index, scheduled_test_name) = take!(jobs)

            st = scheduled_tests[scheduled_tests_index]
            @assert st.target_testcase.testset_report.description == scheduled_test_name

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

            put!(results, (scheduled_tests_index, st.target_testcase, myid()))
        end
    catch e
        println("ERROR: ", e)
        for s in stacktrace(catch_backtrace())
            println(s)
        end

        while true
            put!(results, (0, nothing, myid()))
        end
    end
end

end
