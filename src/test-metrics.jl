mutable struct DefaultTestMetrics <: TestMetrics
    time::Float64
    bytes::Int
    gctime::Float64
    gcstats::Base.GC_Diff
end
function DefaultTestMetrics()
    return DefaultTestMetrics(0, 0, 0, Base.GC_Diff(0, 0, 0, 0, 0, 0, 0, 0, 0))
end

"""
    create_new_measure_instance(::Type{T}; report_metric::Bool) where T <: TestMetrics

Creates a new instance of `T` and determines whether the collect metrics should be
reported (when `save_test_metrics` is called)
"""
function create_new_measure_instance end

# This is the main method to overload for your custom `TestMetrics` type
function create_new_measure_instance(::Type{T}; report_metric::Bool) where T <: TestMetrics
    return T()
end

# This is a helper function be able to pass a `TestMetrics` object instead of its type
function create_new_measure_instance(::T; report_metric::Bool) where T <: TestMetrics
    create_new_measure_instance(T; report_metric=report_metric)
end

function create_new_measure_instance(::Type{Nothing}; report_metric::Bool)
    return nothing
end

function create_new_measure_instance(::Nothing; report_metric::Bool)
    return create_new_measure_instance(Nothing; report_metric=report_metric)
end

function gather_test_metrics(t::AsyncTestSuite)
    if !t.disabled
        for sub_testset in t.sub_testsets
            gather_test_metrics(sub_testset)
            t = combine_test_metrics(t, sub_testset)
        end

        for sub_testcase in t.sub_testcases
            t = combine_test_metrics(t, sub_testcase)
        end
    end
end

function gather_test_metrics(t::AsyncTestCase)
    run_and_gather_test_metrics(t; run = false)
end

function run_and_gather_test_metrics(t::AsyncTestCase; run::Bool=true)
    !t.disabled && run_and_gather_test_metrics(t; run=run) do
        t.test_fn()
    end
end

function run_and_gather_test_metrics(fn::Function, t::AsyncTestCase; run::Bool=true)
    return run_and_gather_test_metrics(fn, t.testset_report, t.metrics; run=run)
end

function run_and_gather_test_metrics(fn::Function, ::AbstractTestSet, ::Nothing; run::Bool=true)
    !run && return nothing
    # nothing to measure by default
    return fn()
end

function run_and_gather_test_metrics(
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

"""
    save_test_metrics(ts::AsyncTestCase)
    save_test_metrics(ts::AsyncTestSuite)

Saves the collected metrics for a test-case or test-suite
"""
function save_test_metrics(ts::AsyncTestCase)
    !ts.disabled && save_test_metrics(ts.testset_report, ts.metrics)
end

function save_test_metrics(ts::AsyncTestSuite)
    if !ts.disabled
        for sub_testset in ts.sub_testsets
            save_test_metrics(sub_testset)
        end

        save_test_metrics(ts.testset_report, ts.metrics)
    end
end

function save_test_metrics(::AbstractTestSet, ::Option{DefaultTestMetrics})
    # nothing to do
end

"""
    combine_test_metrics(parent, sub)

Combines the merics results from a `sub` into its `parent`
"""
function combine_test_metrics(parent, sub)
    # nothing to do
   # we should always return the new parent, in case we've replaced the parent.
   # Note: we can replace the parent only if it's a subtype of `TestMetrics`
    return parent
end

function combine_test_metrics(parent::AsyncTestSuite, sub::AsyncTestSuite)
    parent.metrics = combine_test_metrics(parent.metrics, sub.metrics)
    return parent
end

function combine_test_metrics(parent::AsyncTestSuite, sub::AsyncTestCase)
    parent.metrics = combine_test_metrics(parent.metrics, sub.metrics)
    return parent
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
    return parent
end

"""
    create_test_metrics(
        parent_testset::Option{AsyncTestSuiteOrTestCase}, ::Type{T}
    ) where T <: TestMetrics

Creates a new `TestMetrics` instance based on the given type `T`

If `T` is `Nothing`, then an instance of `TestMetrics` similar to `parent_testset.metrics`
is created (if it exists). Otherwise, returns `nothing`.
"""
function create_test_metrics(
    parent_testset::Option{AsyncTestSuiteOrTestCase}, ::Type{T}
) where T <: TestMetrics
    if !(parent_testset === nothing || parent_testset.metrics === nothing || parent_testset.metrics isa T)
        error("All metrics in the hierarchy should be the same. Expected $(typeof(parent_testset.metrics)) got $T")
    end
    return create_new_measure_instance(T; report_metric=true)
end

function create_test_metrics(
    parent_testset::Option{AsyncTestSuiteOrTestCase}, instance::T
) where T <: TestMetrics
    return create_new_measure_instance(instance; report_metric=true)
end

function create_test_metrics(
    parent_testset::Option{AsyncTestSuiteOrTestCase}, ::Nothing
)
    return parent_testset === nothing ?
        nothing :
        create_new_measure_instance(parent_testset.metrics; report_metric=false)
end

"""
    should_report_metric(ts::AsyncTestSuiteOrTestCase)
    should_report_metric(::Option{TestMetrics})

Determines wether a test-case, test-suite or TestMetrics instance should report its result
back and save its results (when `save_test_metrics` is called)

`AsyncTestCase.metrics` and `AsyncTestSuite.metrics` are already optional fields.
If you mark a `@testcase` or `@testset` with an explicit `metrics` parameter, then it will
report the metrics for that test-case or test-suite.
However, for a `@testset` (that can have other test-cases or test-suites (hierarchy)
underneath itself), we still need to collect metrics for all those test-cases and
test-suites, even though we won't report them. We use those collected metrics to report
the metrics to their parent (by aggregating them at parent).
"""
function should_report_metric(ts::AsyncTestSuiteOrTestCase)
    return should_report_metric(ts.metrics)
end

function should_report_metric(::Option{TestMetrics})
    return false
end
