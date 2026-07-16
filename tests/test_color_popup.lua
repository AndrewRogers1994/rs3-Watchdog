-- Same stubbing convention as test_palette.lua: ColorPopup draws via the client's Canvas,
-- and Theme.Vec4/Theme.Font defer their Vector4/id dependency to draw time specifically so
-- tests can stub them — stub before requiring anything that might touch them at load time.
_G.Vector4 = { new = function(r, g, b, a) return { r, g, b, a } end }
_G.id = { Font = setmetatable({}, { __index = function() return 1 end }) }
_G.config = { Font = setmetatable({}, { __index = function()
    return { GetStringWidth = function(_, text) return #text * 7 end }
end }) }

local luaunit = require("luaunit")
local ColorPopup = require("ui/color_popup")
local Controls = require("ui/controls")
local Theme = require("ui/theme")

local function mockCanvas()
    local canvas = { textCalls = {} }
    function canvas:AddRectangle() end
    function canvas:AddOutline() end
    function canvas:AddGradientH() end
    function canvas:AddGradientV() end
    function canvas:AddLine() end
    function canvas:AddText(x, y, text) table.insert(self.textCalls, text) end
    return canvas
end

TestColorPopupOpenClose = {}

function TestColorPopupOpenClose:setUp()
    self.cp = ColorPopup.new()
end

function TestColorPopupOpenClose:testStartsClosed()
    luaunit.assertFalse(self.cp.open)
end

function TestColorPopupOpenClose:testOpenSeedsFromGivenValue()
    self.cp:Open("node1", "tint", nil, { r = 10, g = 20, b = 30, a = 40 }, 100, 100)
    luaunit.assertTrue(self.cp.open)
    luaunit.assertEquals(self.cp:Value(), { r = 10, g = 20, b = 30, a = 40 })
end

function TestColorPopupOpenClose:testOpenWithNilValueSeedsOpaqueWhite()
    self.cp:Open("node1", "tint", nil, nil, 100, 100)
    luaunit.assertEquals(self.cp:Value(), { r = 255, g = 255, b = 255, a = 255 })
end

function TestColorPopupOpenClose:testOpenRecordsPrevValueSeparatelyFromWorkingValue()
    self.cp:Open("node1", "tint", nil, { r = 10, g = 20, b = 30, a = 40 }, 0, 0)
    self.cp.value.r = 99
    luaunit.assertEquals(self.cp.prevValue.r, 10)
end

function TestColorPopupOpenClose:testCloseClearsOpenAndRect()
    self.cp:Open("node1", "tint", nil, nil, 0, 0)
    self.cp:Draw(mockCanvas(), 0, 0, 800, 600, -1, -1)
    self.cp:Close()
    luaunit.assertFalse(self.cp.open)
    luaunit.assertNil(self.cp.rect)
end

function TestColorPopupOpenClose:testValueReturnsAFreshCopyEachTime()
    self.cp:Open("node1", "tint", nil, { r = 1, g = 2, b = 3, a = 4 }, 0, 0)
    local a = self.cp:Value()
    a.r = 250
    luaunit.assertEquals(self.cp:Value().r, 1)
end

function TestColorPopupOpenClose:testOpenRecordsTheGivenSpec()
    local spec = Controls.For("color")
    self.cp:Open("node1", "tint", spec, nil, 0, 0)
    luaunit.assertIs(self.cp.spec, spec)
end

-- The hex row's display text goes through the spec's own format hook (Controls.Format),
-- the same path every other widget's on-Canvas text takes — not a hard-coded Color.FormatHex8
-- call independent of the registered "color" Control Spec.
function TestColorPopupOpenClose:testHexRowTextGoesThroughTheRegisteredSpec()
    self.cp:Open("node1", "tint", Controls.For("color"), { r = 60, g = 200, b = 255, a = 180 }, 0, 0)
    local canvas = mockCanvas()
    self.cp:Draw(canvas, 0, 0, 800, 600, -1, -1)
    local found = false
    for _, text in ipairs(canvas.textCalls) do
        if text == "#3CC8FFB4" then found = true end
    end
    luaunit.assertTrue(found)
end

TestColorPopupSetValue = {}

function TestColorPopupSetValue:testSetValueOverwritesAndResyncsHSV()
    local cp = ColorPopup.new()
    cp:Open("n", "p", nil, { r = 0, g = 0, b = 0, a = 255 }, 0, 0)
    cp:SetValue({ r = 0, g = 255, b = 0, a = 255 })
    luaunit.assertEquals(cp:Value(), { r = 0, g = 255, b = 0, a = 255 })
    luaunit.assertAlmostEquals(cp.h, 120, 1e-6)
end

TestColorPopupDrawAndClamp = {}

function TestColorPopupDrawAndClamp:setUp()
    self.cp = ColorPopup.new()
end

function TestColorPopupDrawAndClamp:testRectMatchesRequestedAnchorWhenItFits()
    self.cp:Open("n", "p", nil, nil, 50, 50)
    self.cp:Draw(mockCanvas(), 0, 0, 800, 600, -1, -1)
    luaunit.assertEquals(self.cp.rect.x, 50)
    luaunit.assertEquals(self.cp.rect.y, 50)
    luaunit.assertEquals(self.cp.rect.w, Theme.COLOR_POPUP_W)
end

function TestColorPopupDrawAndClamp:testClampsInsideViewportWhenAnchorWouldOverflow()
    self.cp:Open("n", "p", nil, nil, 790, 590)
    self.cp:Draw(mockCanvas(), 0, 0, 800, 600, -1, -1)
    luaunit.assertTrue(self.cp.rect.x + self.cp.rect.w <= 800 + 1e-9)
    luaunit.assertTrue(self.cp.rect.y + self.cp.rect.h <= 600 + 1e-9)
end

function TestColorPopupDrawAndClamp:testSubRectsStayWithinThePanel()
    self.cp:Open("n", "p", nil, nil, 10, 10)
    self.cp:Draw(mockCanvas(), 0, 0, 800, 600, -1, -1)
    local r = self.cp.rect
    for _, name in ipairs({ "sv", "hue", "hex", "r", "g", "b", "a" }) do
        local sub = r[name]
        luaunit.assertTrue(sub.x >= r.x - 1e-9)
        luaunit.assertTrue(sub.x + sub.w <= r.x + r.w + 1e-9)
        luaunit.assertTrue(sub.y >= r.y - 1e-9)
        luaunit.assertTrue(sub.y + sub.h <= r.y + r.h + 1e-9)
    end
end

TestColorPopupPartAt = {}

function TestColorPopupPartAt:setUp()
    self.cp = ColorPopup.new()
    self.cp:Open("n", "p", nil, nil, 10, 10)
    self.cp:Draw(mockCanvas(), 0, 0, 800, 600, -1, -1)
end

local function center(rect)
    return rect.x + rect.w * 0.5, rect.y + rect.h * 0.5
end

function TestColorPopupPartAt:testEachTrackReportsItsOwnPart()
    local r = self.cp.rect
    for _, name in ipairs({ "sv", "hue", "hex", "r", "g", "b", "a" }) do
        local cx, cy = center(r[name])
        luaunit.assertEquals(self.cp:PartAt(cx, cy), name)
    end
end

function TestColorPopupPartAt:testCloseGlyphReportsClose()
    local r = self.cp.rect
    luaunit.assertEquals(self.cp:PartAt(r.close.cx, r.close.cy), "close")
end

function TestColorPopupPartAt:testPrevCurChipsAreInert()
    local r = self.cp.rect
    local cx, cy = center(r.prevChip)
    luaunit.assertEquals(self.cp:PartAt(cx, cy), "other")
end

function TestColorPopupPartAt:testOutsidePanelReturnsNil()
    luaunit.assertNil(self.cp:PartAt(-100, -100))
end

function TestColorPopupPartAt:testContainsMatchesThePanelBounds()
    local r = self.cp.rect
    luaunit.assertTrue(self.cp:Contains(r.x + 1, r.y + 1))
    luaunit.assertFalse(self.cp:Contains(r.x - 5, r.y - 5))
end

TestColorPopupDrag = {}

function TestColorPopupDrag:setUp()
    self.cp = ColorPopup.new()
    self.cp:Open("n", "p", nil, { r = 255, g = 0, b = 0, a = 255 }, 10, 10)
    self.cp:Draw(mockCanvas(), 0, 0, 800, 600, -1, -1)
end

function TestColorPopupDrag:testDraggingSVToTopLeftGivesFullSaturationFullValue()
    local rr = self.cp.rect.sv
    self.cp:ApplyDrag("sv", rr.x, rr.y)
    luaunit.assertAlmostEquals(self.cp.s, 0, 1e-6)
    luaunit.assertAlmostEquals(self.cp.v, 1, 1e-6)
end

function TestColorPopupDrag:testDraggingSVToBottomRightGivesFullSaturationZeroValue()
    local rr = self.cp.rect.sv
    self.cp:ApplyDrag("sv", rr.x + rr.w, rr.y + rr.h)
    luaunit.assertAlmostEquals(self.cp.s, 1, 1e-6)
    luaunit.assertAlmostEquals(self.cp.v, 0, 1e-6)
    -- Value goes black, but hue is NOT recomputed from the (achromatic) result.
    luaunit.assertAlmostEquals(self.cp.h, 0, 1e-6)
end

function TestColorPopupDrag:testDraggingSVClampsOutOfBoundsPoints()
    local rr = self.cp.rect.sv
    self.cp:ApplyDrag("sv", rr.x - 500, rr.y - 500)
    luaunit.assertAlmostEquals(self.cp.s, 0, 1e-6)
    luaunit.assertAlmostEquals(self.cp.v, 1, 1e-6)
end

function TestColorPopupDrag:testHueSurvivesADropToValueZeroThenBackUp()
    -- Set a distinct hue via the hue strip, drag V to 0 (goes black), then back to 1 --
    -- the color should return to the ORIGINAL hue, not reset to red (h=0).
    local hueR, svR = self.cp.rect.hue, self.cp.rect.sv
    self.cp:ApplyDrag("hue", hueR.x + hueR.w * (120 / 360), hueR.y)  -- ~green
    luaunit.assertAlmostEquals(self.cp.h, 120, 1)
    self.cp:ApplyDrag("sv", svR.x + svR.w, svR.y + svR.h)  -- v -> 0 (black)
    self.cp:ApplyDrag("sv", svR.x + svR.w, svR.y)          -- v -> 1, s stays 1
    luaunit.assertAlmostEquals(self.cp.h, 120, 1)
    luaunit.assertAlmostEquals(self.cp.value.g, 255, 1)
end

function TestColorPopupDrag:testDraggingHueToMidpointGivesCyan()
    local rr = self.cp.rect.hue
    self.cp:ApplyDrag("hue", rr.x + rr.w * 0.5, rr.y)
    luaunit.assertAlmostEquals(self.cp.h, 180, 1)
    luaunit.assertAlmostEquals(self.cp.value.r, 0, 1)
    luaunit.assertTrue(self.cp.value.g > 200)
    luaunit.assertTrue(self.cp.value.b > 200)
end

function TestColorPopupDrag:testDraggingGChannelToFullSetsGreenByteAndReSyncsHue()
    local rr = self.cp.rect.g
    self.cp:ApplyDrag("g", rr.x + rr.w, rr.y)
    luaunit.assertEquals(self.cp.value.g, 255)
    -- r=255 (from Open), g now 255, b=0 -> yellow, hue 60.
    luaunit.assertAlmostEquals(self.cp.h, 60, 1)
end

function TestColorPopupDrag:testDraggingAlphaDoesNotTouchHue()
    local before = self.cp.h
    local rr = self.cp.rect.a
    self.cp:ApplyDrag("a", rr.x, rr.y)
    luaunit.assertEquals(self.cp.value.a, 0)
    luaunit.assertAlmostEquals(self.cp.h, before, 1e-6)
end

function TestColorPopupDrag:testApplyDragBeforeDrawIsANoOp()
    local fresh = ColorPopup.new()
    fresh:Open("n", "p", nil, { r = 1, g = 2, b = 3, a = 4 }, 0, 0)
    fresh:ApplyDrag("sv", 50, 50)
    luaunit.assertEquals(fresh:Value(), { r = 1, g = 2, b = 3, a = 4 })
end

return TestColorPopupDrag
