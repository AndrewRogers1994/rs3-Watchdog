-- Widget primitives (ADR-0005): generic, engine-agnostic input primitives under ui/widgets/.
-- These are pure value-in -> value-out tests: a Widget owns its own value codec (number field)
-- or its config + hit-testing (button), and depends only on Theme/Color/ui.* — never on a Pin
-- Control, the Editor, the Store, or the engine. The dependency rule is asserted directly below
-- so a stray require of a forbidden module surfaces here rather than at a future extraction.

local luaunit = require("luaunit")
local NumberField = require("ui/widgets/number_field")
local Button = require("ui/widgets/button")
local TextField = require("ui/widgets/text_field")
local Dropdown = require("ui/widgets/dropdown")
local Toggle = require("ui/widgets/toggle")

--- number_field Widget: the numeric codec ------------------------------------------------

TestNumberFieldFormat = {}

function TestNumberFieldFormat:testNilFormatsToEmptyString()
    luaunit.assertEquals(NumberField.Format(nil), "")
end

function TestNumberFieldFormat:testNumberFormatsToItsDigits()
    luaunit.assertEquals(NumberField.Format(50), "50")
    luaunit.assertEquals(NumberField.Format(0), "0")
    luaunit.assertEquals(NumberField.Format(-3), "-3")
end

TestNumberFieldParse = {}

function TestNumberFieldParse:testParsesADigitString()
    luaunit.assertEquals(NumberField.Parse("50", nil), 50)
end

function TestNumberFieldParse:testEmptyStringIsNoValue()
    -- Empty/whitespace means "nothing to commit" (nil), so a caller leaves its stored value
    -- alone rather than clobbering it with 0 — the empty-box guard that motivated ADR-0005.
    luaunit.assertNil(NumberField.Parse("", nil))
    luaunit.assertNil(NumberField.Parse("   ", nil))
end

function TestNumberFieldParse:testUnparsableStringIsNoValue()
    luaunit.assertNil(NumberField.Parse("not-a-number", nil))
end

function TestNumberFieldParse:testQuantityIsPreferredOverTheRawString()
    -- A real InputField reports contentQuantity honoring suffixes like "1K" that tonumber can't;
    -- when present it wins over re-parsing the raw text.
    luaunit.assertEquals(NumberField.Parse("1K", 1000), 1000)
    luaunit.assertEquals(NumberField.Parse("ignored", 42), 42)
end

function TestNumberFieldParse:testWhitespaceGuardsEvenWithAQuantity()
    -- An empty box is "leave alone" regardless of a stale quantity the field may still report.
    luaunit.assertNil(NumberField.Parse("", 7))
end

--- button Widget: config + hit-testing ---------------------------------------------------

TestButton = {}

function TestButton:testLabelRoundTrips()
    local b = Button.new("Set to current position")
    luaunit.assertEquals(b:Label(), "Set to current position")
end

function TestButton:testMissingLabelIsEmptyString()
    luaunit.assertEquals(Button.new():Label(), "")
end

function TestButton:testHitTestInsideAndOutside()
    local b = Button.new("go")
    local rect = { x = 10, y = 20, w = 100, h = 16 }
    luaunit.assertTrue(b:HitTest(rect, 10, 20))       -- top-left corner (inclusive)
    luaunit.assertTrue(b:HitTest(rect, 60, 28))       -- centre
    luaunit.assertTrue(b:HitTest(rect, 110, 36))      -- bottom-right corner (inclusive)
    luaunit.assertFalse(b:HitTest(rect, 9, 28))       -- left of the box
    luaunit.assertFalse(b:HitTest(rect, 60, 37))      -- below the box
end

--- text_field Widget: the text codec -----------------------------------------------------

TestTextFieldFormat = {}

function TestTextFieldFormat:testNilFormatsToEmptyString()
    luaunit.assertEquals(TextField.Format(nil), "")
end

function TestTextFieldFormat:testStringFormatsToItself()
    luaunit.assertEquals(TextField.Format("hello"), "hello")
    luaunit.assertEquals(TextField.Format(""), "")
end

TestTextFieldParse = {}

function TestTextFieldParse:testParsesTextVerbatim()
    luaunit.assertEquals(TextField.Parse("zulrah", nil), "zulrah")
end

function TestTextFieldParse:testEmptyStringIsAMeaningfulValue()
    -- Unlike the number codec (empty -> nil "leave alone"), an empty text box is how the user
    -- clears a field, so it commits verbatim as "" rather than guarding.
    luaunit.assertEquals(TextField.Parse("", nil), "")
    luaunit.assertEquals(TextField.Parse("   ", nil), "   ")
end

function TestTextFieldParse:testQuantityIsIgnored()
    luaunit.assertEquals(TextField.Parse("5 gp", 5), "5 gp")
end

--- dropdown Widget: choice list + value<->label mapping ----------------------------------

TestDropdown = {}

local function boolDropdown()
    return Dropdown.new({ { value = true, label = "true" }, { value = false, label = "false" } })
end

function TestDropdown:testLabelsInDeclarationOrder()
    luaunit.assertEquals(boolDropdown():Labels(), { "true", "false" })
end

function TestDropdown:testLabelForValueRoundTrips()
    local d = boolDropdown()
    luaunit.assertEquals(d:LabelForValue(true), "true")
    luaunit.assertEquals(d:LabelForValue(false), "false")
end

function TestDropdown:testValueForLabelRoundTrips()
    local d = boolDropdown()
    local v, found = d:ValueForLabel("false")
    luaunit.assertEquals(v, false)
    luaunit.assertTrue(found)
end

function TestDropdown:testUnknownLabelIsNotFound()
    local _, found = boolDropdown():ValueForLabel("maybe")
    luaunit.assertFalse(found)
end

function TestDropdown:testNilValuedChoiceRoundTripsByLabel()
    -- A "None" choice whose value is nil (e.g. the toast icon) must still round-trip: the found
    -- flag distinguishes (nil, true) "the None choice" from (nil, false) "no such label".
    local d = Dropdown.new({ { value = nil, label = "None" }, { value = 431, label = "Coins" } })
    luaunit.assertEquals(d:LabelForValue(nil), "None")
    local v, found = d:ValueForLabel("None")
    luaunit.assertNil(v)
    luaunit.assertTrue(found)
end

function TestDropdown:testUnmatchedValueHasNoLabel()
    luaunit.assertNil(boolDropdown():LabelForValue(42))
end

--- toggle Widget: ordered mode cycle -----------------------------------------------------

TestToggle = {}

local function modeToggle()
    return Toggle.new({ { value = "substring", label = "Substring" },
        { value = "pattern", label = "Pattern" } })
end

function TestToggle:testLabelForCurrentMode()
    local t = modeToggle()
    luaunit.assertEquals(t:Label("substring"), "Substring")
    luaunit.assertEquals(t:Label("pattern"), "Pattern")
end

function TestToggle:testUnknownModeFallsBackToFirstLabel()
    luaunit.assertEquals(modeToggle():Label(nil), "Substring")
end

function TestToggle:testNextCyclesAndWraps()
    local t = modeToggle()
    luaunit.assertEquals(t:Next("substring"), "pattern")
    luaunit.assertEquals(t:Next("pattern"), "substring")  -- wraps back
end

function TestToggle:testNextFromUnknownLandsOnFirst()
    luaunit.assertEquals(modeToggle():Next(nil), "substring")
end

--- Dependency rule: ui/widgets/ files require only Theme/Color/ui.* -----------------------
-- A Widget must not reach into a Pin Control, the Editor, the Store, the runtime, or the
-- engine — that isolation is what keeps a future UI-library extraction a move, not a rewrite
-- (ADR-0005). Scanning the source for a forbidden require is deterministic regardless of what
-- other suites have loaded into package.loaded, so it stays a real guard in the full run.

TestWidgetDependencyRule = {}

local function widgetSource(name)
    -- Tests run with cwd at the plugin root (see tests/run.lua), so widgets resolve directly.
    local f = assert(io.open("ui/widgets/" .. name .. ".lua", "r"))
    local src = f:read("*a")
    f:close()
    return src
end

function TestWidgetDependencyRule:testNoWidgetRequiresAForbiddenModule()
    local forbidden = { "controls", "graph", "store", "runtime", "engine", "registry" }
    for _, widget in ipairs({ "number_field", "button", "text_field", "dropdown", "toggle" }) do
        local src = widgetSource(widget)
        for req in src:gmatch("require%s*%(?%s*[\"']([^\"']+)[\"']") do
            local base = req:match("([^/]+)$")
            for _, bad in ipairs(forbidden) do
                luaunit.assertNotEquals(base, bad,
                    "ui/widgets/" .. widget .. " must not require " .. req)
            end
        end
    end
end

return {}
