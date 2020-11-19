macro my_testcase(args...)
    args_with_metrics = (:(metrics = DefaultTestMetrics), args...)
    return XUnit.testcase_handler(args_with_metrics, __source__)
end
