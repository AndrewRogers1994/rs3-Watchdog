-- swatch Pin Control (ADR-0005 / #60) driven through the shared FAKE HOST. Unlike the editable
-- controls the swatch edits nothing itself — the whole edit is the Color Popup — so the behavior
-- under test is: pressing the chip OPENS the popup through the host and hands it a working hex
-- codec, and the chip's geometry/display project the stored color the way the Node draws it.

local luaunit = require("luaunit")
local FakeHost = require("fake_control_host")
local Swatch = require("ui/controls/swatch")
local Theme = require("ui/theme")

local swatch = Swatch.new()

local RED = { r = 255, g = 0, b = 0, a = 255 }

local function swatchCtrl(value)
    return { kind = "swatch", pinName = "tint", value = value, x = 0, y = 0, w = 24, h = 16 }
end

--- Press opens the popup ------------------------------------------------------------------

TestSwatchPress = {}

function TestSwatchPress:testPressOpensTheColorPopup()
    local host = FakeHost.new(RED)
    swatch.Press(host, swatchCtrl(RED))
    luaunit.assertNotNil(host.openedPopup)
    -- The swatch commits nothing itself — the popup owns the edit.
    luaunit.assertEquals(host.commitCount, 0)
end

function TestSwatchPress:testPopupGetsAWorkingHexCodec()
    -- The codec is what lets the popup keep its own file with no Control Spec: it round-trips the
    -- hex field through the swatch Widget's Color hex8 mapping.
    local host = FakeHost.new(RED)
    swatch.Press(host, swatchCtrl(RED))
    local codec = host.openedPopup.codec
    luaunit.assertEquals(codec.format(RED), "FF0000FF")
    luaunit.assertEquals(codec.parse("00FF00FF", RED), { r = 0, g = 255, b = 0, a = 255 })
end

--- Display + geometry the Node draws from --------------------------------------------------

TestSwatchDisplay = {}

function TestSwatchDisplay:testDisplayIsTheHexOfTheColor()
    luaunit.assertEquals(swatch.Display(swatchCtrl(RED)), "FF0000FF")
end

function TestSwatchDisplay:testDisplayOfUnsetIsEmpty()
    luaunit.assertEquals(swatch.Display(swatchCtrl(nil)), "")
end

TestSwatchLayout = {}

function TestSwatchLayout:testInlineChipFlushRightAtFixedWidth()
    luaunit.assertTrue(swatch.Inline)
    luaunit.assertEquals(swatch.ReservedHeight({}), 0)
    local rects = swatch.Layout({ x = 10, y = 4, w = 100, h = 16 })
    luaunit.assertEquals(#rects, 1)
    local r = rects[1]
    luaunit.assertEquals(r.kind, "swatch")
    luaunit.assertEquals(r.widget, "swatch")
    luaunit.assertEquals(r.w, Theme.SWATCH_W)          -- fixed chip width
    luaunit.assertEquals(r.x + r.w, 110)               -- flush against the box's right edge
end

function TestSwatchLayout:testChipNeverWiderThanTheBox()
    local rects = swatch.Layout({ x = 0, y = 0, w = 5, h = 16 })  -- box narrower than SWATCH_W
    luaunit.assertEquals(rects[1].w, 5)
    luaunit.assertEquals(rects[1].x, 0)
end

return {}
