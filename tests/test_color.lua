_G.Vector4 = { new = function(r, g, b, a) return { r, g, b, a } end }

local luaunit = require("luaunit")
local Color = require("ui/color")

TestRGBHSVRoundTrip = {}

function TestRGBHSVRoundTrip:testPureRedIsHueZero()
    local h, s, v = Color.RGBtoHSV(255, 0, 0)
    luaunit.assertAlmostEquals(h, 0, 1e-6)
    luaunit.assertAlmostEquals(s, 1, 1e-6)
    luaunit.assertAlmostEquals(v, 1, 1e-6)
end

function TestRGBHSVRoundTrip:testPureGreenIsHue120()
    local h = Color.RGBtoHSV(0, 255, 0)
    luaunit.assertAlmostEquals(h, 120, 1e-6)
end

function TestRGBHSVRoundTrip:testGreyHasZeroSaturation()
    local h, s, v = Color.RGBtoHSV(128, 128, 128)
    luaunit.assertAlmostEquals(s, 0, 1e-6)
    luaunit.assertAlmostEquals(v, 128 / 255, 1e-6)
end

function TestRGBHSVRoundTrip:testHSVtoRGBInvertsRGBtoHSV()
    local cases = { { 60, 200, 255 }, { 0, 0, 0 }, { 255, 255, 255 }, { 10, 240, 30 } }
    for _, c in ipairs(cases) do
        local h, s, v = Color.RGBtoHSV(c[1], c[2], c[3])
        local r, g, b = Color.HSVtoRGB(h, s, v)
        luaunit.assertAlmostEquals(r, c[1], 1)
        luaunit.assertAlmostEquals(g, c[2], 1)
        luaunit.assertAlmostEquals(b, c[3], 1)
    end
end

TestClampByte = {}

function TestClampByte:testClampsBelowZero()
    luaunit.assertEquals(Color.ClampByte(-10), 0)
end

function TestClampByte:testClampsAbove255()
    luaunit.assertEquals(Color.ClampByte(300), 255)
end

function TestClampByte:testRoundsToNearestInt()
    luaunit.assertEquals(Color.ClampByte(127.6), 128)
end

TestHex8 = {}

function TestHex8:testFormatRoundTripsUppercaseRRGGBBAA()
    local hex = Color.FormatHex8({ r = 60, g = 200, b = 255, a = 180 })
    luaunit.assertEquals(hex, "3CC8FFB4")
end

function TestHex8:testFormatDefaultsMissingAlphaToOpaque()
    local hex = Color.FormatHex8({ r = 0, g = 0, b = 0 })
    luaunit.assertEquals(hex, "000000FF")
end

function TestHex8:testFormatNilValueIsEmptyString()
    luaunit.assertEquals(Color.FormatHex8(nil), "")
end

function TestHex8:testParseSixDigitDefaultsAlphaFromCurrent()
    local current = { r = 1, g = 2, b = 3, a = 77 }
    local value = Color.ParseHex8("3CC8FF", current)
    luaunit.assertEquals(value, { r = 0x3C, g = 0xC8, b = 0xFF, a = 77 })
end

function TestHex8:testParseEightDigitParsesAlphaToo()
    local value = Color.ParseHex8("3CC8FFB4", nil)
    luaunit.assertEquals(value, { r = 0x3C, g = 0xC8, b = 0xFF, a = 0xB4 })
end

function TestHex8:testParseToleratesLeadingHash()
    local value = Color.ParseHex8("#3CC8FFB4", nil)
    luaunit.assertEquals(value, { r = 0x3C, g = 0xC8, b = 0xFF, a = 0xB4 })
end

function TestHex8:testParseTooShortKeepsCurrent()
    local current = { r = 1, g = 2, b = 3, a = 4 }
    local value = Color.ParseHex8("3C", current)
    luaunit.assertEquals(value, current)
end

function TestHex8:testParseNonStringKeepsCurrent()
    local current = { r = 1, g = 2, b = 3, a = 4 }
    luaunit.assertEquals(Color.ParseHex8(nil, current), current)
end

TestDrawChecker = {}

function TestDrawChecker:testTilesFullAreaWithoutGaps()
    local calls = {}
    local canvas = { AddRectangle = function(_, x, y, w, h, col)
        calls[#calls + 1] = { x = x, y = y, w = w, h = h, col = col }
    end }
    Color.DrawChecker(canvas, 0, 0, 10, 6, 4, "A", "B")
    luaunit.assertEquals(#calls, 6)
    for _, c in ipairs(calls) do
        luaunit.assertTrue(c.x + c.w <= 10 + 1e-9)
        luaunit.assertTrue(c.y + c.h <= 6 + 1e-9)
    end
end

function TestDrawChecker:testAlternatesColors()
    local colors = {}
    local canvas = { AddRectangle = function(_, x, y, w, h, col) colors[#colors + 1] = col end }
    Color.DrawChecker(canvas, 0, 0, 8, 8, 4, "A", "B")
    luaunit.assertEquals(colors, { "A", "B", "B", "A" })
end

return TestHex8
