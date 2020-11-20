module SubModule
    import XUnit

    mutable struct MyTestMetrics <: XUnit.TestMetrics
        default::XUnit.DefaultTestMetrics
    end

    function MyTestMetrics()
        return MyTestMetrics(XUnit.DefaultTestMetrics())
    end

    function XUnit.gather_test_metrics(fn::Function, ts::XUnit.AbstractTestSet, m::MyTestMetrics)
        return XUnit.gather_test_metrics(fn, ts, m.default)
    end

    function XUnit.combine_test_metrics(parent::MyTestMetrics, sub::MyTestMetrics)
        return XUnit.combine_test_metrics(parent.default, sub.default)
    end

    function XUnit.save_test_metrics(ts, m::MyTestMetrics)
        return XUnit.save_test_metrics(ts, m.default)
    end
end

module MacroDefMod

import ..SubModule
import XUnit

macro my_testcase(name, code)
    tests_block_location = XUnit.get_block_source(code)
    tests_block = if tests_block_location !== nothing
        Expr(:block, tests_block_location, esc(code))
    else
        quote
            begin
                esc(code)
            end
        end
    end
    quote
        XUnit.@testcase metrics = SubModule.MyTestMetrics $(name) $(tests_block)
    end
end

end
