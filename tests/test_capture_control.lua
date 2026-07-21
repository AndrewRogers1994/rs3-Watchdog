-- capture Pin Control (ADR-0005 / #60) driven through the shared FAKE HOST. One factory serves both
-- flavors, chosen by captureKind: Screen Marker's `rect` (the drag overlay) and Object Marker's
-- `object` (the MiniMenu select mode). The behavior under test is: pressing the button ARMS the
-- correct capture through the host, and Display summarizes the captured value (or falls back to the
-- placeholder) exactly as each node's format hook does.

local luaunit = require("luaunit")
local FakeHost = require("fake_control_host")
local Capture = require("ui/controls/capture")

-- Mirrors screen_marker.rect's spec: a rect summary, default "screen" kind + "Draw on screen".
local screenCapture = Capture.new({
    format = function(value)
        if value == nil then return "" end
        return string.format("%d,%d %dx%d", value.x or 0, value.y or 0, value.w or 0, value.h or 0)
    end,
})
-- Mirrors object_marker.object's spec: an object name, "object" kind + "Select object".
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
