-- theme.lua — colors, sizing, and font resolution for the graph Editor.
--
-- Pure data + a couple of defensive lookups. Colors are stored as plain {r,g,b,a}
-- tables (channels 0..1) and converted to the client's Vector4 only at draw time via
-- Theme.Vec4, so this module has no hard dependency on client globals at load. All
-- sizes are in Graph-space interface units at zoom = 1.0; the View scales them.

local Theme = {}

-- Builds a color table from 0..255 RGB and 0..1 alpha.
local function col(r, g, b, a)
    return { r / 255, g / 255, b / 255, a or 1 }
end

--- Sizing (Graph-space units at zoom 1.0) -------------------------------------------

Theme.NODE_WIDTH       = 190   -- default node body width
Theme.HEADER_HEIGHT    = 26    -- category-colored title band
Theme.PIN_ROW_HEIGHT   = 24    -- vertical stride between pin rows
Theme.BODY_PAD_TOP     = 8     -- gap between header and first pin row
Theme.BODY_PAD_BOTTOM  = 10    -- gap below the last pin row
Theme.PIN_MARGIN_X     = 10    -- inset of a pin glyph's center from the node edge
Theme.PIN_GLYPH        = 12    -- pin glyph bounding size (square/triangle extent)
Theme.PIN_LABEL_GAP    = 8     -- gap between a pin glyph and its label
Theme.PIN_HIT_PAD      = 4     -- extra hit-test padding around a pin glyph
Theme.BORDER_THICKNESS = 2
Theme.WIRE_THICKNESS   = 3
Theme.WIRE_SEGMENTS    = 16    -- straight segments a bezier Wire is tessellated into
Theme.GRID_SPACING     = 32    -- background grid cell size

-- Text can't shrink past the smallest font (font IDs are discrete — ADR-0001), so labels
-- are dropped when zoomed out rather than left to overflow. Degrades in two stages: pin
-- labels go first, node titles persist further out so nodes stay identifiable.
Theme.LABEL_MIN_ZOOM   = 0.45   -- pin labels
Theme.TITLE_MIN_ZOOM   = 0.30   -- node titles

Theme.ZOOM_MIN = 0.25
Theme.ZOOM_MAX = 2.0

--- Window (screen-space) ----------------------------------------------------------------

Theme.WINDOW_X        = 220
Theme.WINDOW_Y        = 140
Theme.WINDOW_W        = 900
Theme.WINDOW_H        = 560
Theme.WINDOW_HEADER_H = 28
Theme.WINDOW_TITLE    = "Watchdog — Node Graph"

--- Palette (screen-space popup) + toolbar -----------------------------------------------

Theme.PALETTE_W     = 220   -- popup width (clamped to the Viewport if narrower)
Theme.PALETTE_ROW_H = 20    -- uniform row height (headers and items share it)
Theme.PALETTE_PAD   = 6      -- inner padding above/below the row list

-- Two clicks pairing into a double-click that opens the Palette on empty space.
Theme.DOUBLECLICK_TICKS = 12  -- Logic ticks (~0.02s each) allowed between the two clicks
Theme.DOUBLECLICK_DIST  = 6   -- max screen-px drift between the two clicks

--- Colors --------------------------------------------------------------------------

Theme.COL_VIEWPORT_BG = col(26, 26, 30, 1.0)
Theme.COL_GRID        = col(40, 40, 47, 1.0)
Theme.COL_GRID_MAJOR  = col(52, 52, 60, 1.0)

Theme.COL_WINDOW_BORDER = col(12, 12, 15, 1.0)

-- Palette popup + its toolbar launcher.
Theme.COL_PALETTE_BG        = col(32, 32, 38, 0.98)
Theme.COL_PALETTE_BORDER    = col(12, 12, 15, 1.0)
Theme.COL_PALETTE_HEADER_BG = col(48, 48, 58, 1.0)
Theme.COL_PALETTE_HEADER_TX = col(150, 190, 230, 1.0)  -- category label
Theme.COL_PALETTE_HOVER     = col(60, 70, 90, 1.0)      -- row under the cursor
Theme.COL_PALETTE_TEXT      = col(220, 222, 230, 1.0)

Theme.COL_NODE_BODY   = col(43, 43, 48, 0.96)
Theme.COL_NODE_BORDER = col(15, 15, 18, 1.0)
Theme.COL_NODE_SEL    = col(240, 160, 32, 1.0)  -- selected/hovered node border
Theme.COL_TITLE       = col(240, 240, 244, 1.0)
Theme.COL_PIN_LABEL   = col(198, 200, 208, 1.0)

-- Execution pins and wires use one fixed neutral color (they carry no Type Tag).
Theme.COL_EXEC        = col(242, 242, 242, 1.0)

-- Category -> header band color. Opaque consumer tags; unknowns fall back.
Theme.CATEGORY_COLORS = {
    trigger = col(155, 47, 47, 1.0),   -- red-ish (events)
    action  = col(47, 95, 155, 1.0),   -- blue (side effects)
    flow    = col(70, 70, 80, 1.0),    -- grey (branch/sequence)
    math    = col(47, 130, 90, 1.0),   -- green
    logic   = col(120, 90, 150, 1.0),  -- purple (boolean/compare)
}
Theme.DEFAULT_CATEGORY_COLOR = col(85, 85, 96, 1.0)

-- Type Tag -> Data pin/wire color (loosely following Blueprint conventions).
Theme.TYPE_COLORS = {
    any    = col(176, 176, 176, 1.0),  -- wildcard: grey
    bool   = col(150, 47, 47, 1.0),    -- red
    number = col(63, 159, 111, 1.0),   -- green
    string = col(192, 63, 159, 1.0),   -- magenta
    coord  = col(208, 160, 32, 1.0),   -- gold
}
Theme.DEFAULT_TYPE_COLOR = col(176, 176, 176, 1.0)

--- Lookups -------------------------------------------------------------------------

function Theme.CategoryColor(category)
    return Theme.CATEGORY_COLORS[category] or Theme.DEFAULT_CATEGORY_COLOR
end

function Theme.TypeColor(tag)
    return Theme.TYPE_COLORS[tag] or Theme.DEFAULT_TYPE_COLOR
end

-- Converts a {r,g,b,a} color to the client's Vector4. Deferred to draw time because
-- Vector4 is a client global that may be absent under a bare Lua runtime.
function Theme.Vec4(c)
    return Vector4.new(c[1], c[2], c[3], c[4])
end

--- Fonts ---------------------------------------------------------------------------

local fontCache = {}

local function fontByName(name)
    if id == nil or id.Font == nil then
        return nil
    end
    local ok, font = pcall(function() return id.Font[name] end)
    -- A missing size can come back as a truthy-but-invalid sentinel (0/-1) rather than
    -- nil; only a positive numeric id is a real font. Rejecting the rest lets Theme.Font's
    -- nearest-size search find a font that actually renders (fixes text vanishing at some
    -- zoom levels).
    if ok and type(font) == "number" and font > 0 then
        return font
    end
    return nil
end

-- Resolves a MUSEO_SANS font ID at (or near) the requested point size, searching
-- outward for the nearest available bucket. Cached per size. Returns nil if fonts
-- are unavailable (caller then skips text).
function Theme.Font(pt)
    pt = math.max(8, math.min(40, math.floor(pt + 0.5)))
    if fontCache[pt] ~= nil then
        return fontCache[pt] or nil
    end

    local function fontAt(sz)
        return fontByName("MUSEO_SANS_" .. sz .. "PT_REGULAR")
            or fontByName("MUSEO_SANS_" .. sz .. "PT")
    end

    local font = fontAt(pt)
    if font == nil then
        for offset = 1, 32 do
            local lo, hi = pt - offset, pt + offset
            if lo >= 8 then font = fontAt(lo) end
            if font == nil and hi <= 40 then font = fontAt(hi) end
            if font ~= nil then break end
        end
    end

    fontCache[pt] = font or false  -- cache the miss too, so we don't re-scan every frame
    return font or nil
end

return Theme
