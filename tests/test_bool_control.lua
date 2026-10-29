-- bool Pin Control (#112) through the fake host. A click flips the shown boolean.
-- Nothing is mounted: the checkbox commits on press.

_G.Vector4 = _G.Vector4 or { new = function(r, g, b, a) return { r, g, b, a } end }

local luaunit = require("luaunit")
local FakeHost = require("fake_control_host")
local Bool = require("src/ui/controls/bool")

local function box(value)
    return { kind = "checkbox", pinName = "sticky", value = value, enabled = true,
        x = 0, y = 0, w = 60, h = 16 }
end

TestBoolPress = {}

function TestBoolPress:testClickClearsACheckedBox()
    local host = FakeHost.new(true)
    Bool.Press(host, box(true))
    luaunit.assertEquals(host.committed, false)
    luaunit.assertEquals(host.commitCount, 1)
    luaunit.assertNil(host.mounted)
end

function TestBoolPress:testClickChecksAClearBox()
    local host = FakeHost.new(false)
    Bool.Press(host, box(false))
    luaunit.assertEquals(host.committed, true)
end

function TestBoolPress:testClickOnADefaultCheckedBoxClearsIt()
    -- Graph fills ctrl.value from the pin default before Press. The flip uses that
    -- shown value, so the first click on an unset pin whose default is true stores false.
    local host = FakeHost.new(nil)
    Bool.Press(host, box(true))
    luaunit.assertEquals(host.committed, false)
end

function TestBoolPress:testUnsetWithNoDefaultBecomesChecked()
    local host = FakeHost.new(nil)
    Bool.Press(host, box(nil))
    luaunit.assertEquals(host.committed, true)
end

--- Geometry the Node delegates to ---------------------------------------------------------

TestBoolLayout = {}

function TestBoolLayout:testInlineCheckboxFillsTheValueColumn()
    luaunit.assertTrue(Bool.Inline)
    luaunit.assertEquals(Bool.ReservedHeight({}), 0)
    local rects = Bool.Layout({ x = 4, y = 8, w = 60, h = 16 })
    luaunit.assertEquals(#rects, 1)
    luaunit.assertEquals(rects[1].kind, "checkbox")
    luaunit.assertEquals(rects[1].enabled, true)
    luaunit.assertEquals(rects[1].x, 4)
    luaunit.assertEquals(rects[1].y, 8)
    luaunit.assertEquals(rects[1].w, 60)
    luaunit.assertEquals(rects[1].h, 16)
end

--- Display: the pin label already names the row ------------------------------------------

TestBoolDisplay = {}

function TestBoolDisplay:testDoesNotRepeatThePinLabelOrTheWordsTrueAndFalse()
    luaunit.assertEquals(Bool.Display(box(true)), "")
    luaunit.assertEquals(Bool.Display(box(false)), "")
    luaunit.assertEquals(Bool.Display(box(nil)), "")
end

--- Draw: a scalar bool ticks through the checkbox Widget ----------------------------------

local function recordingCanvas()
    local calls = { lines = 0 }
    return {
        AddRectangle = function() end,
        AddOutline = function() end,
        AddText = function() end,
        AddLine = function() calls.lines = calls.lines + 1 end,
    }, calls
end

local function dctx()
    return { hot = false, font = nil, zoom = 1, scale = function(n) return n end }
end

TestBoolDraw = {}

function TestBoolDraw:testTrueDrawsTheTick()
    local canvas, calls = recordingCanvas()
    Bool.Draw(canvas, { x = 0, y = 0, w = 60, h = 16 }, box(true), dctx())
    luaunit.assertEquals(calls.lines, 2)
end

function TestBoolDraw:testFalseAndNilDrawNoTick()
    local canvas, calls = recordingCanvas()
    Bool.Draw(canvas, { x = 0, y = 0, w = 60, h = 16 }, box(false), dctx())
    luaunit.assertEquals(calls.lines, 0)
    Bool.Draw(canvas, { x = 0, y = 0, w = 60, h = 16 }, box(nil), dctx())
    luaunit.assertEquals(calls.lines, 0)
end

--- Registry: the bool tag commits on click ------------------------------------------------

TestBoolRegistry = {}

function TestBoolRegistry:testBoolTagCommitsOnClick()
    local Controls = require("src/ui/controls")
    local ControlKinds = require("src/ui/control_kinds")
    local host = FakeHost.new(true)
    local pc = Controls.PinControlFor("bool")
    pc.Press(host, box(true))
    luaunit.assertEquals(host.committed, false)
    luaunit.assertNil(host.mounted)
    luaunit.assertEquals(ControlKinds.Widget("bool"), "checkbox")
end

return {}
