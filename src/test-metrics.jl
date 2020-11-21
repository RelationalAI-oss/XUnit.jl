mutable struct DefaultTestMetrics <: TestMetrics
    time::Float64
    bytes::Int
    gctime::Float64
    gcstats::Base.GC_Diff
end
function DefaultTestMetrics()
    return DefaultTestMetrics(0, 0, 0, Base.GC_Diff(0, 0, 0, 0, 0, 0, 0, 0, 0))
end

function create_new_measure_instance end

# This is the main method to overload for your custom `TestMetrics` type
function create_new_measure_instance(::Type{T}; report_metric::Bool=false) where T <: TestMetrics
    return T()
end

# This is a helper function be able to pass a `TestMetrics` object instead of its type
function create_new_measure_instance(::T; report_metric::Bool=false) where T <: TestMetrics
    create_new_measure_instance(T; report_metric=report_metric)
end

function create_new_measure_instance(::Type{Nothing}; report_metric::Bool=false)
    return nothing
end

function create_new_measure_instance(::Nothing; report_metric::Bool=false)
    return create_new_measure_instance(Nothing; report_metric=report_metric)
end

function gather_test_metrics end

function gather_test_metrics(t::AsyncTestSuite; run::Bool=true)
    if !t.disabled
        for sub_testsuite in t.sub_testsuites
            gather_test_metrics(sub_testsuite; run=run)
            combine_test_metrics(t, sub_testsuite)
        end

        for sub_testcase in t.sub_testcases
            combine_test_metrics(t, sub_testcase)
        end
    end
end

function gather_test_metrics(t::AsyncTestCase; run::Bool=true)
    !t.disabled && gather_test_metrics(t.test_fn, t; run=run)
end

function gather_test_metrics(fn::Function, t::AsyncTestCase; run::Bool=true)
    return gather_test_metrics(fn, t.testset_report, t.metrics; run=run)
end

function gather_test_metrics(fn::Function, ::AbstractTestSet, ::Nothing; run::Bool=true)
    !run && return nothing
    # nothing to measure by default
    return fn()
end

function gather_test_metrics(
    fn::Function, ts::AbstractTestSet, m::DefaultTestMetrics; run::Bool=true
)
    !run && return nothing
    val, t, bytes, gctime, memallocs = @timed fn()
    m.time = t
    m.bytes = bytes
    m.gctime = gctime
    m.gcstats = memallocs

    return val
end

function save_test_metrics(ts::AsyncTestCase)
    !ts.disabled && save_test_metrics(ts.testset_report, ts.metrics)
end

function save_test_metrics(ts::AsyncTestSuite)
    if !ts.disabled
        for sub_testsuite in ts.sub_testsuites
            save_test_metrics(sub_testsuite)
        end

        save_test_metrics(ts.testset_report, ts.metrics)
    end
end

function save_test_metrics(::AbstractTestSet, ::Option{DefaultTestMetrics})
    # nothing to do
end

function combine_test_metrics(parent, sub)
    # nothing to do
end

function combine_test_metrics(parent::AsyncTestSuite, sub::AsyncTestSuite)
    combine_test_metrics(parent.metrics, sub.metrics)
end

function combine_test_metrics(parent::AsyncTestSuite, sub::AsyncTestCase)
    combine_test_metrics(parent.metrics, sub.metrics)
end

function combine_test_metrics(parent::DefaultTestMetrics, sub::DefaultTestMetrics)
    parent.time += sub.time
    parent.bytes += sub.bytes
    parent.gctime += sub.gctime
    parent.gcstats = Base.GC_Diff(
        parent.gcstats.allocd + sub.gcstats.allocd,
        parent.gcstats.malloc + sub.gcstats.malloc,
        parent.gcstats.realloc + sub.gcstats.realloc,
        parent.gcstats.poolalloc + sub.gcstats.poolalloc,
        parent.gcstats.bigalloc + sub.gcstats.bigalloc,
        parent.gcstats.freecall + sub.gcstats.freecall,
        parent.gcstats.total_time + sub.gcstats.total_time,
        parent.gcstats.pause + sub.gcstats.pause,
        parent.gcstats.full_sweep + sub.gcstats.full_sweep,
    )
    nothing
end

function create_test_metrics(
    parent_testsuite::Option{AsyncTestSuiteOrTestCase}, ::Type{T}
) where T <: TestMetrics
    if !(parent_testsuite === nothing || parent_testsuite.metrics === nothing || parent_testsuite.metrics isa T)
        error("All metrics in the hierarchy should be the same. Expected $(typeof(parent_testsuite.metrics)) got $T")
    end
    return create_new_measure_instance(T; report_metric=true)
end

function create_test_metrics(
    parent_testsuite::Option{AsyncTestSuiteOrTestCase}, ::T
) where T <: TestMetrics
    return create_test_metrics(parent_testsuite, T)
end

function create_test_metrics(
    parent_testsuite::Option{AsyncTestSuiteOrTestCase}, ::Nothing
)
    return parent_testsuite === nothing ?
        nothing :
        create_new_measure_instance(parent_testsuite.metrics; report_metric=false)
end
