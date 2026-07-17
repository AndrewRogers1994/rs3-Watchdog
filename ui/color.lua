-- color.lua — pure RGBA/HSV/hex8 color math shared by the "color" Control Spec
-- (controls.lua's swatch widget) and the color-picker popup (color_popup.lua). No client
-- globals except Vector4 inside DrawChecker's caller-supplied colors — this module itself
-- takes/returns plain tables, so it's directly unit-testable under a bare Lua runtime.

local Color = {}

-- Rounds and clamps to a valid RGBA channel byte.
function Color.ClampByte(n)
    if n < 0 then return 0 end
    if n > 255 then return 255 end
    return math.floor(n + 0.5)
end

-- RGB (0..255 each) -> HSV (h in [0,360), s/v in [0,1]). Hue is 0 for any achromatic
-- (grey/black/white) input — callers that need to preserve a user-picked hue through an
-- achromatic value (e.g. dragging the SV field to v=0) must keep H as their own source of
-- truth rather than round-tripping through this function (see color_popup.lua).
function Color.RGBtoHSV(r, g, b)
    r, g, b = r / 255, g / 255, b / 255
    local mx, mn = math.max(r, g, b), math.min(r, g, b)
    local d = mx - mn
    local h = 0
    if d > 0 then
        if mx == r then h = ((g - b) / d) % 6
        elseif mx == g then h = (b - r) / d + 2
        else h = (r - g) / d + 4 end
        h = h * 60
        if h < 0 then h = h + 360 end
    end
    local s = (mx == 0) and 0 or (d / mx)
    return h, s, mx
end

-- HSV (h in [0,360), s/v in [0,1]) -> RGB (0..255 each, rounded).
function Color.HSVtoRGB(h, s, v)
    local c = v * s
    local x = c * (1 - math.abs((h / 60) % 2 - 1))
    local m = v - c
    local r, g, b
    if h < 60 then r, g, b = c, x, 0
    elseif h < 120 then r, g, b = x, c, 0
    elseif h < 180 then r, g, b = 0, c, x
    elseif h < 240 then r, g, b = 0, x, c
    elseif h < 300 then r, g, b = x, 0, c
    else r, g, b = c, 0, x end
    return Color.ClampByte((r + m) * 255), Color.ClampByte((g + m) * 255), Color.ClampByte((b + m) * 255)
end

-- {r,g,b,a} (0..255 each, a optional) -> "RRGGBBAA" hex8 (uppercase, no '#'). nil -> "".
function Color.FormatHex8(value)
    if value == nil then return "" end
    local function h2(n) return string.format("%02X", Color.ClampByte(n or 0)) end
    local a = (value.a == nil) and 255 or value.a
    return h2(value.r) .. h2(value.g) .. h2(value.b) .. h2(a)
end

-- hex8 string (optional leading '#', 6 or 8 hex digits) -> {r,g,b,a}. Too short/unparsable
-- returns `current` unchanged (mirrors Controls.Parse/CommitAxis's empty-box guard elsewhere
-- — a mid-typed hex string must not clobber the working color). A 6-digit string keeps
-- `current`'s alpha (or 255 with no current) since RRGGBB has none of its own.
function Color.ParseHex8(raw, current)
    if type(raw) ~= "string" then return current end
    local hex = raw:gsub("^#", ""):gsub("[^0-9a-fA-F]", "")
    if #hex < 6 then return current end
    local r = tonumber(hex:sub(1, 2), 16)
    local g = tonumber(hex:sub(3, 4), 16)
    local b = tonumber(hex:sub(5, 6), 16)
    if r == nil or g == nil or b == nil then return current end
    local a
    if #hex >= 8 then
        a = tonumber(hex:sub(7, 8), 16)
    end
    if a == nil then
        a = (current ~= nil) and current.a or 255
    end
    return { r = r, g = g, b = b, a = a }
end

-- Tiles a checkerboard of `cell`-sized squares over (x,y,w,h), alternating `colA`/`colB`
-- (already-resolved Vector4s — this module has no Theme/client dependency of its own).
-- Edge tiles are clipped to the requested area rather than overflowing it. Shared by the
-- on-pin swatch chip (node.lua) and the popup's SV/alpha previews (color_popup.lua) so
-- transparency always reads the same way everywhere a color is shown.
function Color.DrawChecker(canvas, x, y, w, h, cell, colA, colB)
    if cell == nil or cell <= 0 then return end
    local cols = math.ceil(w / cell)
    local rows = math.ceil(h / cell)
    for ry = 0, rows - 1 do
        for cx = 0, cols - 1 do
            local col = ((cx + ry) % 2 == 0) and colA or colB
            local cw = math.min(cell, w - cx * cell)
            local ch = math.min(cell, h - ry * cell)
            canvas:AddRectangle(x + cx * cell, y + ry * cell, cw, ch, col)
        end
    end
end

function Color.ToRGBA(r, g, b, a)
    local function to255(x)
        return math.floor(x * 255 + 0.5)
    end
    return (to255(r) << 24) | (to255(g) << 16) | (to255(b) << 8) | to255(a)
end

return Color
