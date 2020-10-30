mutable struct DefaultTestMeasures <: TestMeasures
    time::Float64
    bytes::Int
    gctime::Float64
    gcstats::Base.GC_Diff
end
function DefaultTestMeasures()
    return DefaultTestMeasures(0, 0, 0, Base.GC_Diff(0, 0, 0, 0, 0, 0, 0, 0, 0))
end

function create_new_measure_instance end

function create_new_measure_instance(::T) where T <: TestMeasures
    create_new_measure_instance(T)
end

function create_new_measure_instance(::Type{DefaultTestMeasures})
    return DefaultTestMeasures()
end

function create_new_measure_instance(::Type{Nothing})
    return nothing
end

function create_new_measure_instance(::Nothing)
    return create_new_measure_instance(Nothing)
end

function gather_test_measures end

function gather_test_measures(t::AsyncTestSuite)
    for sub_testsuite in t.sub_testsuites
        gather_test_measures(sub_testsuite)
        combine_test_measures(t, sub_testsuite)
    end

    for sub_testcase in t.sub_testcases
        combine_test_measures(t, sub_testcase)
    end
end

function gather_test_measures(t::AsyncTestCase)
    gather_test_measures(t.test_fn, t)
end

function gather_test_measures(fn::Function, t::AsyncTestCase)
    return gather_test_measures(fn, t.measures)
end

function gather_test_measures(fn::Function, ::Nothing)
    # nothing to measure by default
    return fn()
end

function gather_test_measures(fn::Function, m::DefaultTestMeasures)
    val, t, bytes, gctime, memallocs = @timed fn()
    m.time = t
    m.bytes = bytes
    m.gctime = gctime
    m.gcstats = memallocs
    return val
end

function combine_test_measures(parent, sub)
    # nothing to do
end

function combine_test_measures(parent::AsyncTestSuite, sub::AsyncTestSuite)
    combine_test_measures(parent.measures, sub.measures)
end

function combine_test_measures(parent::AsyncTestSuite, sub::AsyncTestCase)
    combine_test_measures(parent.measures, sub.measures)
end

function combine_test_measures(parent::DefaultTestMeasures, sub::DefaultTestMeasures)
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

function create_measures(
    parent_testsuite::Option{AsyncTestSuiteOrTestCase}, ::Type{T}
) where T <: TestMeasures
    @assert parent_testsuite === nothing || parent_testsuite.measures === nothing || parent_testsuite.measures isa T
    return create_new_measure_instance(T)
end

function create_measures(
    parent_testsuite::Option{AsyncTestSuiteOrTestCase}, ::T
) where T <: TestMeasures
    return create_measures(parent_testsuite, T)
end

function create_measures(
    parent_testsuite::Option{AsyncTestSuiteOrTestCase}, ::Nothing
)
    return parent_testsuite === nothing ? nothing : create_new_measure_instance(parent_testsuite.measures)
end
