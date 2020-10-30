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

function create_new_measure_instance(::T) where T <: TestMetrics
    create_new_measure_instance(T)
end

function create_new_measure_instance(::Type{T}) where T <: TestMetrics
    return T()
end

function create_new_measure_instance(::Type{Nothing})
    return nothing
end

function create_new_measure_instance(::Nothing)
    return create_new_measure_instance(Nothing)
end

function gather_test_metrics end

function gather_test_metrics(t::AsyncTestSuite)
    for sub_testsuite in t.sub_testsuites
        gather_test_metrics(sub_testsuite)
        combine_test_metrics(t, sub_testsuite)
    end

    for sub_testcase in t.sub_testcases
        combine_test_metrics(t, sub_testcase)
    end

    save_test_metrics(t.testset_report, t.metrics)

    return nothing
end

function gather_test_metrics(t::AsyncTestCase)
    gather_test_metrics(t.test_fn, t)
    @show "AsyncTestCase"
    @show t.testset_report.description
    @show t.metrics
end

function gather_test_metrics(fn::Function, t::AsyncTestCase)
    return gather_test_metrics(fn, t.testset_report, t.metrics)
end

function gather_test_metrics(fn::Function, ::AbstractTestSet, ::Nothing)
    # nothing to measure by default
    return fn()
end

function gather_test_metrics(fn::Function, ts::AbstractTestSet, m::DefaultTestMetrics)
    val, t, bytes, gctime, memallocs = @timed fn()
    m.time = t
    m.bytes = bytes
    m.gctime = gctime
    m.gcstats = memallocs

    save_test_metrics(ts, t.metrics)

    return val
end

function save_test_metrics(::AbstractTestSet, ::DefaultTestMetrics)
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
    @assert parent_testsuite === nothing || parent_testsuite.metrics === nothing || parent_testsuite.metrics isa T
    return create_new_measure_instance(T)
end

function create_test_metrics(
    parent_testsuite::Option{AsyncTestSuiteOrTestCase}, ::T
) where T <: TestMetrics
    return create_test_metrics(parent_testsuite, T)
end

function create_test_metrics(
    parent_testsuite::Option{AsyncTestSuiteOrTestCase}, ::Nothing
)
    return parent_testsuite === nothing ? nothing : create_new_measure_instance(parent_testsuite.metrics)
end
