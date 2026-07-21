-- Widget primitives (ADR-0005): generic, engine-agnostic input primitives under ui/widgets/.
-- These are pure value-in -> value-out tests: a Widget owns its own value codec (number field)
-- or its config + hit-testing (button), and depends only on Theme/Color/ui.* — never on a Pin
-- Control, the Editor, the Store, or the engine. The dependency rule is asserted directly below
-- so a stray require of a forbidden module surfaces here rather than at a future extraction.

local luaunit = require("luaunit")
local NumberField = require("ui/widgets/number_field")
local Button = require("ui/widgets/button")

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
    for _, widget in ipairs({ "number_field", "button" }) do
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
