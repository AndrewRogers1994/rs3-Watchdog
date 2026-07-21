-- scalar Pin Control (ADR-0005 / #59) driven through the shared FAKE HOST. The scalar factory
-- builds the `number` and `string` Type Tags from one code path — the only difference is the
-- codec + filter, and the empty-box behavior that difference produces: number guards an empty box
-- (leave the stored value alone), string commits it verbatim (clearing the field). Both are driven
-- here through the same press->type->commit seam the in-client Editor uses.

local luaunit = require("luaunit")
local FakeHost = require("fake_control_host")
local Scalar = require("ui/controls/scalar")
local NumberField = require("ui/widgets/number_field")
local TextField = require("ui/widgets/text_field")

local number = Scalar.new({ codec = NumberField, filter = "NUMERIC" })
local text = Scalar.new({ codec = TextField, filter = "NONE" })

-- The clicked value-column box as node.lua hands it to Press: the pin name + the default-resolved
-- current value (ctrl.value) that seeds the transient field.
local function fieldCtrl(value)
    return { kind = "field", pinName = "amount", value = value, x = 0, y = 0, w = 40, h = 16 }
end

--- number scalar --------------------------------------------------------------------------

TestScalarNumber = {}

function TestScalarNumber:testCommitsAParsedNumber()
    local host = FakeHost.new(0)
    number.Press(host, fieldCtrl(0))
    host:Type("50", 50)
    luaunit.assertEquals(host.committed, 50)
end

function TestScalarNumber:testEmptyBoxLeavesTheValueAlone()
    -- A numeric field reports contentQuantity 0 for an empty box; the codec's whitespace guard
    -- means an emptied field commits nothing rather than nuking the stored value to 0.
    local host = FakeHost.new(7)
    number.Press(host, fieldCtrl(7))
    host:Type("", 0)
    luaunit.assertNil(host.committed)
    luaunit.assertEquals(host.commitCount, 0)
end

function TestScalarNumber:testUnparsableLeavesTheValueAlone()
    local host = FakeHost.new(7)
    number.Press(host, fieldCtrl(7))
    host:Type("not-a-number", nil)
    luaunit.assertEquals(host.commitCount, 0)
end

function TestScalarNumber:testQuantityIsPreferredOverRawText()
    local host = FakeHost.new(0)
    number.Press(host, fieldCtrl(0))
    host:Type("1K", 1000)
    luaunit.assertEquals(host.committed, 1000)
end

function TestScalarNumber:testFieldIsSeededAndNumericFiltered()
    local host = FakeHost.new(42)
    number.Press(host, fieldCtrl(42))
    luaunit.assertEquals(host.mounted.opts.initial, "42")
    luaunit.assertEquals(host.mounted.opts.filter, "NUMERIC")
end

function TestScalarNumber:testDisplayShowsDigitsOrEmpty()
    luaunit.assertEquals(number.Display(fieldCtrl(50)), "50")
    luaunit.assertEquals(number.Display(fieldCtrl(nil)), "")
end

--- string scalar --------------------------------------------------------------------------

TestScalarString = {}

function TestScalarString:testCommitsTextVerbatim()
    local host = FakeHost.new("")
    text.Press(host, fieldCtrl("old"))
    host:Type("zulrah", nil)
    luaunit.assertEquals(host.committed, "zulrah")
end

function TestScalarString:testEmptyBoxCommitsAnEmptyString()
    -- Clearing a text field is a real edit (unlike a numeric axis) — it commits "" rather than
    -- snapping back to the previous text.
    local host = FakeHost.new("old")
    text.Press(host, fieldCtrl("old"))
    host:Type("", nil)
    luaunit.assertEquals(host.committed, "")
    luaunit.assertEquals(host.commitCount, 1)
end

function TestScalarString:testFieldIsSeededAndUnfiltered()
    local host = FakeHost.new("hi")
    text.Press(host, fieldCtrl("hi"))
    luaunit.assertEquals(host.mounted.opts.initial, "hi")
    luaunit.assertEquals(host.mounted.opts.filter, "NONE")
end

function TestScalarString:testDisplayShowsTextOrEmpty()
    luaunit.assertEquals(text.Display(fieldCtrl("hello")), "hello")
    luaunit.assertEquals(text.Display(fieldCtrl(nil)), "")
end

--- Geometry the Node delegates to ---------------------------------------------------------

TestScalarLayout = {}

function TestScalarLayout:testInlineWithZeroReservedHeight()
    luaunit.assertTrue(number.Inline)
    luaunit.assertEquals(number.ReservedHeight({}), 0)
end

function TestScalarLayout:testLayoutFillsTheValueBox()
    local rects = number.Layout({ x = 10, y = 20, w = 60, h = 16 })
    luaunit.assertEquals(rects, { { kind = "field", x = 10, y = 20, w = 60, h = 16 } })
end

return {}
