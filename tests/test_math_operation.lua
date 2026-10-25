local luaunit = require("luaunit")
local Controls = require("src/ui/controls")
local ControlKinds = require("src/ui/control_kinds")
local FakeHost = require("fake_control_host")
local Theme = require("src/ui/theme")

TestMathOperation = {}

-- The dropdown stores the operator. Labels stay plain text so the client does
-- not read "<" or ">" as a formatting tag.
function TestMathOperation:testDropdownStoresTheOperatorWithoutFormattingTags()
    local control = Controls.PinControlFor("mathOperation")
    luaunit.assertNotNil(control)
    local host = FakeHost.new("+")
    control.Press(host, { value = "+", pinName = "operation" })
    local labels = {
        "Add (+)", "Subtract (-)", "Multiply (*)", "Divide (/)", "Modulo (%)", "Min", "Max",
    }
    luaunit.assertItemsEquals(host.mounted.opts.labels, labels)
    for _, label in ipairs(host.mounted.opts.labels) do
        luaunit.assertNil(string.find(label, "<", 1, true))
        luaunit.assertNil(string.find(label, ">", 1, true))
    end
    for _, choice in ipairs({
        { "+", "Add (+)" },
        { "-", "Subtract (-)" },
        { "*", "Multiply (*)" },
        { "/", "Divide (/)" },
        { "%", "Modulo (%)" },
        { "min", "Min" },
        { "max", "Max" },
    }) do
        host:Pick(choice[2])
        luaunit.assertEquals(host.committed, choice[1])
        luaunit.assertEquals(control.Display({ value = choice[1] }), choice[2])
    end
    local recorded = ControlKinds.Choices("mathOperation")
    local recordedValues = {}
    for i, choice in ipairs(recorded) do
        recordedValues[i] = choice.value
    end
    luaunit.assertEquals(recordedValues, { "+", "-", "*", "/", "%", "min", "max" })
    luaunit.assertFalse(control.Inline)
    luaunit.assertEquals(control.ReservedHeight({}), Theme.CONTROL_H)
    luaunit.assertEquals(control.Layout({ x = 4, y = 8, w = 120, h = Theme.CONTROL_H }), {
        { kind = "field", x = 4, y = 8, w = 120, h = Theme.CONTROL_H },
    })
end

return {}
