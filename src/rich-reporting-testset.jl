# RichReportingTestSet extends ReportingTestSet with providing richer
# test output for XUnit
mutable struct RichReportingTestSet <: Test.AbstractTestSet
    reporting_test_set::Ref{Option{ReportingTestSet}}
    flattened_reporting_test_set::Ref{Option{ReportingTestSet}}
    description::AbstractString
    xml_output::String
    html_output::String
    out_buff::IOBuffer
    err_buff::IOBuffer
end

# constructor takes a description string and options keyword arguments
function RichReportingTestSet(
    desc;
    xml_output::String="test-results.xml",
    other_args...
)
    html_output = "$xml_output.html"
    RichReportingTestSet(
        ReportingTestSet(desc),
        nothing,
        desc,
        xml_output,
        html_output,
        IOBuffer(),
        IOBuffer(),
    )
end

function Test.record(rich_ts::RichReportingTestSet, child::AbstractTestSet)
    Test.record(rich_ts.reporting_test_set[], child)
    return rich_ts
end
function Test.record(rich_ts::RichReportingTestSet, res::Result)
    Test.record(rich_ts.reporting_test_set[], res)
    return rich_ts
end
function Test.finish(rich_ts::RichReportingTestSet)
    # If we are a nested test set, do not print a full summary
    # now - let the parent test set do the printing
    if get_testset_depth() != 0
        # Attach this test set to the parent test set
        parent_ts = get_testset()
        record(parent_ts, rich_ts)
    end

    return rich_ts
end

function TestReports.add_to_ts_default!(ts_default::Test.DefaultTestSet, rich_ts::RichReportingTestSet)
    ts = rich_ts.reporting_test_set[]
    sub_ts = Test.DefaultTestSet(rich_ts.description)
    TestReports.add_to_ts_default!.(Ref(sub_ts), ts.results)
    push!(ts_default.results, sub_ts)
end

function TestReports.display_reporting_testset(rich_ts::RichReportingTestSet)
    ts = rich_ts.reporting_test_set[]
    # Create top level default testset to hold all results
    ts_default = DefaultTestSet(rich_ts.description)
    Test.push_testset(ts_default)
    TestReports.add_to_ts_default!.(Ref(ts_default), ts.results)
    try
        # Finish the top level testset, to mimick the output from Pkg.test()
        Test.pop_testset()
        finish(ts_default)
    catch TestSetException
        # Don't want to error here if a test fails or errors. This is handled elswhere.
    end
    return nothing
end

function test_out_io()
    ts = get_testset()
    @assert ts isa RichReportingTestSet
    ts.out_buff
end

function test_err_io()
    ts = get_testset()
    @assert ts isa RichReportingTestSet
    ts.err_buff
end

# Gathers per-test output. Should be used instead of `println` if you want to gather any
# output without worrying about multi-threaded execution of tests.
function test_print(input...)
    print(test_out_io(), input...)
end

# Gathers per-test output. Should be used instead of `print` if you want to gather any
# output without worrying about multi-threaded execution of tests.
function test_println(input...)
    println(test_out_io(), input...)
end

include("to_xml.jl")

"""
    html_report!(
        rich_ts::RichReportingTestSet;
        show_stdout::Bool=TESTSET_PRINT_ENABLE[],
    )

Generates an HTML file output for the given testset.

If `show_stdout` is `true`, then it also prints the test output in the standard output.
"""
function html_report!(
    rich_ts::RichReportingTestSet;
    show_stdout::Bool=TESTSET_PRINT_ENABLE[],
)
    xml_report!(rich_ts; show_stdout=show_stdout)

    run(`junit2html $(rich_ts.xml_output)`)

    if TESTSET_PRINT_ENABLE[]
        println("Test results in HTML format: $(rich_ts.html_output)")
    end
    return rich_ts
end

"""
    function xml_report!(
        rich_ts::RichReportingTestSet;
        show_stdout::Bool=TESTSET_PRINT_ENABLE[],
    )

Generates an xUnit/JUnit-style XML file output for the given testset.

If `show_stdout` is `true`, then it also prints the test output in the standard output.
"""
function xml_report!(
    rich_ts::RichReportingTestSet;
    show_stdout::Bool=TESTSET_PRINT_ENABLE[],
)
    if show_stdout
        TestReports.display_reporting_testset(rich_ts)
    end

    # We are the top level, lets do this
    flatten_results!(rich_ts)

    open(rich_ts.xml_output, "w") do fh
        print(fh, report(rich_ts))
    end
    return rich_ts
end

create_deep_copy(x::Test.Broken) = x
create_deep_copy(x::Test.Pass) = x
create_deep_copy(x::Test.Fail) = x
create_deep_copy(x::Test.Error) = x
create_deep_copy(x::Nothing) = x

function create_deep_copy(ts::RichReportingTestSet)::RichReportingTestSet
    RichReportingTestSet(
        create_deep_copy(ts.reporting_test_set[]),
        create_deep_copy(ts.flattened_reporting_test_set[]),
        ts.description,
        ts.xml_output,
        ts.html_output,
        copy(ts.out_buff),
        copy(ts.out_buff),
    )
end

function create_deep_copy(ts::ReportingTestSet)::ReportingTestSet
    return ReportingTestSet(
        ts.description,
        map(create_deep_copy, ts.results),
        copy(ts.properties)
    )
end

function flatten_results!(rich_ts::RichReportingTestSet)
    if rich_ts.flattened_reporting_test_set[] === nothing
        rich_ts.flattened_reporting_test_set[] = create_deep_copy(rich_ts.reporting_test_set[])
        ts = rich_ts.flattened_reporting_test_set[]
        # Add any top level Results to their own TestSet
        TestReports.handle_top_level_results!(ts)

        # Flatten all results of top level testset, which should all be testsets now
        rich_ts.flattened_reporting_test_set[].results = vcat(_flatten_results!.(ts.results)...)
    end
    return rich_ts
end

"""
    _flatten_results!(ts::AbstractTestSet)::Vector{<:AbstractTestSet}

Recursively flatten `ts` to a vector of `TestSet`s.
"""
function _flatten_results!(rich_ts::RichReportingTestSet)::Vector{<:AbstractTestSet}
    rich_ts.flattened_reporting_test_set[] = create_deep_copy(rich_ts.reporting_test_set[])
    ts = rich_ts.flattened_reporting_test_set[]
    original_results = ts.results
    flattened_results = AbstractTestSet[]
    # Track results that are a Result so that if there are any, they can be added
    # in their own testset to flattened_results
    results = Result[]

    # Define nested functions
    function inner!(rs::Result)
        # Add to results vector
        push!(results, rs)
    end
    function inner!(childts::AbstractTestSet)
        # Make it a sibling
        TestReports.update_testset_properties!(childts, ts)
        childts.description = rich_ts.description * "/" * childts.description
        push!(flattened_results, childts)
    end

    # Iterate through original_results
    for res in original_results
        children = _flatten_results!(res)
        for child in children
            inner!(child)
        end
    end

    # results will be empty if ts.results only contains testsets
    if !isempty(results)
        # Use same ts to preserve description
        ts.results = results
        push!(flattened_results, rich_ts)
    end
    return flattened_results
end

"""
    _flatten_results!(rs::Result)

Return vector containing `rs` so that when iterated through,
`rs` is added to the results vector.
"""
_flatten_results!(rs::Result) = [rs]

html_output(rich_ts::RichReportingTestSet) = rich_ts.html_output
xml_output(rich_ts::RichReportingTestSet) = rich_ts.xml_output
