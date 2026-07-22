-- swatch.lua — the swatch Widget (ADR-0005): a generic color-chip primitive that turns a stored
-- `{ r, g, b, a }` value into what an editor needs to render/edit a color: its VISUAL decomposition
-- (IsEmpty/Fill, which the Node blits to Canvas) and the hex CODEC the Color Popup round-trips
-- through. A never-set color (nil value) is EMPTY — drawn as a plain box, not a phantom color (#30).

local Color = require("ui/color")

---@class SwatchWidget
local Swatch = {}

-- Whether the chip has no color to show (never set): a nil value draws as an empty box, any table
-- as its fill. The one branch the Node's swatch draw keys off before pulling Fill().
---@param value any
---@return boolean
function Swatch.IsEmpty(value)
    return value == nil
end

-- The chip's fill as four 0..255 channels, alpha defaulting to fully opaque when the stored table
-- omits it (mirrors Color.FormatHex8's own alpha default). Returns nil for an empty value so a
-- caller that skipped IsEmpty still can't draw a phantom color. The Node normalizes these to a
-- Vector4; keeping them 0..255 here matches the stored table's own units and stays trivially
-- testable without a canvas.
---@param value any
---@return number|nil r, number|nil g, number|nil b, number|nil a
function Swatch.Fill(value)
    if type(value) ~= "table" then return nil end
    local a = (value.a == nil) and 255 or value.a
    return value.r, value.g, value.b, a
end

-- Renders a stored color as the "RRGGBBAA" hex text the popup's hex field shows (no '#'; nil -> "").
-- The popup composes this through its own :Format, so a plain codec table { format = Swatch.Format,
-- parse = Swatch.Parse } is all the popup needs from the swatch Pin Control — no Control Spec.
---@param value any
---@return string
function Swatch.Format(value)
    return Color.FormatHex8(value)
end

-- Interprets edited hex text back into a stored `{ r, g, b, a }`. A too-short/unparsable string
-- leaves `current` untouched (Color.ParseHex8's own guard) so a mid-typed hex never nukes the color.
---@param raw string
---@param current any
---@return any
function Swatch.Parse(raw, current)
    return Color.ParseHex8(raw, current)
end

return Swatch
