-- Widget draw (ADR-0005 / #63, the render seam): each Widget owns its Canvas drawing at an
-- already-projected screen rect. These drive every Widget's Draw through a recording canvas and
-- assert the PRIMITIVE SHAPE the render seam promises - empty swatch = one box, filled = checker +
-- fill, checked mode row = box + two tick lines, dropdown = a caret triangle - without asserting
-- pixels (cf. test_popup's makeFakeCanvas note). Colors resolve through Vector4/ui.TextDataConfig
-- at draw time, so both are stubbed here exactly as the other draw suites stub Vector4.

_G.Vector4 = _G.Vector4 or { new = function(r, g, b, a) return { r, g, b, a } end }
_G.ui = _G.ui or {}
_G.ui.TextDataConfig = _G.ui.TextDataConfig or { new = function() return {} end }

local luaunit     = require("luaunit")
local Theme       = require("ui/theme")
local Swatch      = require("ui/widgets/swatch")
local Checkbox    = require("ui/widgets/checkbox")
local TextField   = require("ui/widgets/text_field")
local NumberField = require("ui/widgets/number_field")
local Dropdown    = require("ui/widgets/dropdown")
local Button      = require("ui/widgets/button")
local Toggle      = require("ui/widgets/toggle")

-- A recording canvas: counts each primitive so a Draw's shape can be asserted headlessly. Methods
-- are called as `canvas:Add…`, so the leading self is ignored along with the geometry args.
local function makeFakeCanvas()
    local calls = { rects = 0, outlines = 0, texts = 0, triangles = 0, lines = 0 }
    return {
        width = 1920,
        AddRectangle = function() calls.rects = calls.rects + 1 end,
        AddOutline   = function() calls.outlines = calls.outlines + 1 end,
        AddText      = function() calls.texts = calls.texts + 1 end,
        AddTriangle  = function() calls.triangles = calls.triangles + 1 end,
        AddLine      = function() calls.lines = calls.lines + 1 end,
    }, calls
end

local RECT = { x = 0, y = 0, w = 46, h = 16 }

-- The projected draw context the Node hands a Widget. `font` nil => text is skipped (zoomed too
-- small); a truthy font id exercises the text path. `scale` is identity so screen == graph here.
local function dctx(hot, font)
    return { hot = hot or false, font = font, zoom = 1, scale = function(n) return n end }
end

--- swatch Widget draw ---------------------------------------------------------------------

TestSwatchDraw = {}

function TestSwatchDraw:testEmptyValueIsOnePlainBoxPlusOutline()
    -- #30: a never-set color draws as a single empty box (no checker, no fill), framed by one outline.
    local canvas, calls = makeFakeCanvas()
    Swatch.Draw(canvas, RECT, { value = nil }, dctx(false, nil))
    luaunit.assertEquals(calls.rects, 1)
    luaunit.assertEquals(calls.outlines, 1)
    luaunit.assertEquals(calls.texts, 0)
end

function TestSwatchDraw:testFilledValueCheckersThenFills()
    -- A set color paints the checkerboard (many cell rects, so alpha reads) then the fill rect on
    -- top - strictly more rects than the empty case - still one framing outline.
    local canvas, calls = makeFakeCanvas()
    Swatch.Draw(canvas, RECT, { value = { r = 255, g = 0, b = 16, a = 128 } }, dctx(false, nil))
    luaunit.assertTrue(calls.rects > 1)   -- checker cells + fill
    luaunit.assertEquals(calls.outlines, 1)
end

--- checkbox Widget draw (mode rows) -------------------------------------------------------

TestCheckboxDraw = {}

function TestCheckboxDraw:testCheckedRowDrawsBoxPlusTwoTickLines()
    local canvas, calls = makeFakeCanvas()
    Checkbox.Draw(canvas, RECT,
        { enabled = true, axis = "tile", value = { tile = true }, display = "Tile" }, dctx(false, 1))
    luaunit.assertTrue(calls.rects >= 1)
    luaunit.assertEquals(calls.outlines, 1)
    luaunit.assertEquals(calls.lines, 2)
    luaunit.assertEquals(calls.texts, 1)
end

function TestCheckboxDraw:testUncheckedRowDrawsNoTick()
    local canvas, calls = makeFakeCanvas()
    Checkbox.Draw(canvas, RECT,
        { enabled = true, axis = "tile", value = { tile = false }, display = "Tile" }, dctx(false, 1))
    luaunit.assertEquals(calls.lines, 0)
end

function TestCheckboxDraw:testDisabledRowNeverTicksEvenIfStoredTrue()
    -- A disabled row is inert: even a stored `true` shows no tick (the enabled gate in the Widget).
    local canvas, calls = makeFakeCanvas()
    Checkbox.Draw(canvas, RECT,
        { enabled = false, axis = "hull", value = { hull = true }, display = "Hull - needs render API" },
        dctx(false, 1))
    luaunit.assertEquals(calls.lines, 0)
end

function TestCheckboxDraw:testLabelClipBoxIsTheGapBeforeTheTickNotMeasuredWidth()
    -- areaWidth is the leftover left of the tick, not Theme.TextWidth of the label.
    local recorded = {}
    local canvas, calls = makeFakeCanvas()
    canvas.AddText = function(_self, _x, _y, w, _h, text)
        recorded.w = w
        recorded.text = text
        calls.texts = calls.texts + 1
    end
    local rect = { x = 0, y = 0, w = 230, h = 16 }
    Checkbox.Draw(canvas, rect,
        { enabled = false, axis = "hull", value = {}, display = "Hull - needs render API" },
        dctx(false, 1))
    local boxSz = rect.h * 0.72
    local boxX = rect.w - Theme.CONTROL_PAD_X - boxSz
    luaunit.assertEquals(recorded.w, boxX - Theme.CONTROL_PAD_X - Theme.CONTROL_PAD_X)
    luaunit.assertEquals(recorded.text, "Hull - needs render API")
end

--- dropdown Widget draw (enum) ------------------------------------------------------------

TestDropdownDraw = {}

function TestDropdownDraw:testDrawsBoxPlusOneCaretTriangle()
    local canvas, calls = makeFakeCanvas()
    local d = Dropdown.new({ { value = true, label = "true" } })
    d:Draw(canvas, RECT, { display = "true" }, dctx(false, nil))
    luaunit.assertEquals(calls.rects, 1)
    luaunit.assertEquals(calls.outlines, 1)
    luaunit.assertEquals(calls.triangles, 1)
end

--- field / button / toggle Widget draw (plain and action boxes) ---------------------------

TestBoxWidgetDraw = {}

function TestBoxWidgetDraw:testTextFieldDrawsBoxAndText()
    local canvas, calls = makeFakeCanvas()
    TextField.Draw(canvas, RECT, { display = "zulrah" }, dctx(false, 1))
    luaunit.assertEquals(calls.rects, 1)
    luaunit.assertEquals(calls.outlines, 1)
    luaunit.assertEquals(calls.texts, 1)
    luaunit.assertEquals(calls.triangles, 0)   -- no caret (not a dropdown)
end

function TestBoxWidgetDraw:testEmptyFieldStillDrawsPlaceholderText()
    -- An empty display falls back to the placeholder, so the text primitive is still emitted.
    local canvas, calls = makeFakeCanvas()
    NumberField.Draw(canvas, RECT, { display = "", placeholder = "…" }, dctx(false, 1))
    luaunit.assertEquals(calls.texts, 1)
end

function TestBoxWidgetDraw:testNoFontSkipsTextButStillDrawsBox()
    -- Zoomed too small to letter (font nil): the box is still framed, but no text is drawn.
    local canvas, calls = makeFakeCanvas()
    NumberField.Draw(canvas, RECT, { display = "50" }, dctx(false, nil))
    luaunit.assertEquals(calls.rects, 1)
    luaunit.assertEquals(calls.outlines, 1)
    luaunit.assertEquals(calls.texts, 0)
end

function TestBoxWidgetDraw:testButtonAndToggleDrawActionBoxes()
    local canvas, calls = makeFakeCanvas()
    Button.Draw(canvas, RECT, { display = "Set to current position" }, dctx(false, 1))
    Toggle.Draw(canvas, RECT, { display = "Substring" }, dctx(false, 1))
    luaunit.assertEquals(calls.rects, 2)
    luaunit.assertEquals(calls.outlines, 2)
    luaunit.assertEquals(calls.texts, 2)
end

return {}
