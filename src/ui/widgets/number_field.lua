local Theme = require("src/ui/theme")
local Box   = require("src/ui/widgets/box")

---@class NumberField
local NumberField = {}

---@param value number|nil
---@return string
function NumberField.Format(value)
    if value == nil then return "" end
    return tostring(value)
end

-- Prefer InputField contentQuantity (honors 1K/1M). Empty/whitespace is nil so we don't commit 0.
---@param raw string
---@param quantity number|nil
---@return number|nil
function NumberField.Parse(raw, quantity)
    if type(raw) == "string" and raw:match("^%s*$") then return nil end
    if quantity ~= nil then return quantity end
    return tonumber(raw)
end

---@param canvas any
---@param rect { x: number, y: number, w: number, h: number }
---@param ctrl table
---@param dctx DrawContext
function NumberField.Draw(canvas, rect, ctrl, dctx)
    Box.Draw(canvas, rect, ctrl.display, ctrl.placeholder, Theme.COL_CONTROL_BG, dctx)
end

return NumberField
