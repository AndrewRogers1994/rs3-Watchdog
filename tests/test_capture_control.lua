-- Capture pin control (ADR-0005 / #60) through FakeHost; screen vs object kinds.

local luaunit = require("luaunit")
local FakeHost = require("fake_control_host")
local Capture = require("ui/controls/capture")

-- Same format hook as screen_marker.rect.
local screenCapture = Capture.new({
    format = function(value)
        if value == nil then return "" end
        return string.format("%d,%d %dx%d", value.x or 0, value.y or 0, value.w or 0, value.h or 0)
    end,
})
-- Same format hook as object_marker.object.
local objectCapture = Capture.new({
    captureKind = "object", placeholder = "Select object",
    format = function(value)
        if type(value) ~= "table" then return "" end
        return value.name or ""
    end,
})

local function captureCtrl(value)
    return { kind = "capture", pinName = "rect", value = value, x = 0, y = 0, w = 100, h = 16 }
end

--- Press arms the right capture -----------------------------------------------------------

TestCapturePress = {}

function TestCapturePress:testScreenCaptureArmsTheScreenKind()
    local host = FakeHost.new(nil)
    screenCapture.Press(host, captureCtrl(nil))
    luaunit.assertEquals(host.armed.kind, "screen")
    luaunit.assertEquals(host.commitCount, 0)  -- the overlay commits, not the Pin Control
end

function TestCapturePress:testObjectCaptureArmsTheObjectKind()
    local host = FakeHost.new(nil)
    objectCapture.Press(host, captureCtrl(nil))
    luaunit.assertEquals(host.armed.kind, "object")
end

--- Display: captured summary vs empty-state placeholder -----------------------------------

TestCaptureDisplay = {}

function TestCaptureDisplay:testScreenSummarizesTheRect()
    luaunit.assertEquals(
        screenCapture.Display(captureCtrl({ x = 10, y = 20, w = 30, h = 40 })), "10,20 30x40")
end

function TestCaptureDisplay:testObjectShowsTheName()
    luaunit.assertEquals(objectCapture.Display(captureCtrl({ name = "Bank booth" })), "Bank booth")
end

function TestCaptureDisplay:testUnsetShowsEmptySoThePlaceholderTakesOver()
    -- "" is what makes the Node draw the box's placeholder; the Pin Control never returns it itself.
    luaunit.assertEquals(screenCapture.Display(captureCtrl(nil)), "")
    luaunit.assertEquals(objectCapture.Display(captureCtrl(nil)), "")
end

function TestCaptureDisplay:testArmedShowsCancelAffordance()
    -- #71: while this pin's Capture Arm is live, the Control label is an explicit Cancel.
    local ctrl = captureCtrl({ x = 1, y = 2, w = 3, h = 4 })
    ctrl.captureArmed = true
    luaunit.assertEquals(screenCapture.Display(ctrl), "Cancel")
    local octrl = captureCtrl({ name = "Bank booth" })
    octrl.captureArmed = true
    luaunit.assertEquals(objectCapture.Display(octrl), "Cancel")
end

--- Geometry the Node delegates to ---------------------------------------------------------

TestCaptureLayout = {}

function TestCaptureLayout:testInlineFullWidthActionBox()
    luaunit.assertTrue(screenCapture.Inline)
    luaunit.assertEquals(screenCapture.ReservedHeight({}), 0)
    local rects = screenCapture.Layout({ x = 8, y = 2, w = 120, h = 16 })
    luaunit.assertEquals(#rects, 1)
    local r = rects[1]
    luaunit.assertEquals(r.kind, "capture")
    luaunit.assertEquals(r.x, 8)
    luaunit.assertEquals(r.w, 120)                     -- fills the value column, unlike the swatch chip
    luaunit.assertEquals(r.placeholder, "Draw on screen")
end

function TestCaptureLayout:testObjectCarriesItsOwnPlaceholder()
    local rects = objectCapture.Layout({ x = 0, y = 0, w = 100, h = 16 })
    luaunit.assertEquals(rects[1].placeholder, "Select object")
end

return {}
