-- text_field.lua — the text-field Widget (ADR-0005): a generic input primitive that owns its value
-- CODEC (Format/Parse) and its box DRAW. Unlike number_field an EMPTY box is a MEANINGFUL value (how
-- the user clears a field), so Parse returns "" verbatim rather than nil — there is no empty-box guard
-- here. The draw is a plain value box (Box.Draw); matcher's needle and the string scalar route here.

local Theme = require("ui/theme")
local Box   = require("ui/widgets/box")

---@class TextField
local TextField = {}

-- Renders a stored value as the text an editor field shows. A nil value (a Control never set)
-- formats to the empty string, so the box reads as empty rather than showing "nil".
---@param value any
---@return string
function TextField.Format(value)
    if value == nil then return "" end
    return tostring(value)
end

-- Interprets an edited field into a committable string. Unlike the number codec there is NO
-- empty-box guard: an empty or whitespace box is a real value (clearing the field), committed
-- verbatim. `quantity` (a numeric field's pre-parsed number) is meaningless for text and ignored.
---@param raw string
---@param _quantity number|nil
---@return string
function TextField.Parse(raw, _quantity)
    if type(raw) ~= "string" then return "" end
    return raw
end

-- Draws the field as a plain value box at an already-projected screen `rect`: the display text,
-- or a dimmed placeholder when empty (ctrl.display / ctrl.placeholder). `dctx` carries the
-- projected draw context. The whole text field Widget is this codec plus this draw.
---@param canvas any
---@param rect { x: number, y: number, w: number, h: number }
---@param ctrl table
---@param dctx DrawContext
function TextField.Draw(canvas, rect, ctrl, dctx)
    Box.Draw(canvas, rect, ctrl.display, ctrl.placeholder, Theme.COL_CONTROL_BG, dctx)
end

return TextField
