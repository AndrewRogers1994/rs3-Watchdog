local Theme = require("src/ui/theme")
local Box   = require("src/ui/widgets/box")
local Text  = require("src/text")

---@class TextField
local TextField = {}

---@param value any
---@return string
function TextField.Format(value)
    if value == nil then return "" end
    return tostring(value)
end

---@param raw string
---@param _quantity number|nil
---@return string
function TextField.Parse(raw, _quantity)
    if type(raw) ~= "string" then return "" end
    return Text.StripTags(raw)
end

---@param canvas any
---@param rect { x: number, y: number, w: number, h: number }
---@param ctrl table
---@param dctx DrawContext
function TextField.Draw(canvas, rect, ctrl, dctx)
    Box.Draw(canvas, rect, ctrl.display, ctrl.placeholder, Theme.COL_CONTROL_BG, dctx)
end

return TextField
