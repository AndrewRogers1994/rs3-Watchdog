local Color = require("ui/color")
local Theme = require("ui/theme")
local Box   = require("ui/widgets/box")

---@class SwatchWidget
local Swatch = {}

---@param value any
---@return boolean
function Swatch.IsEmpty(value)
    return value == nil
end

---@param value any
---@return number|nil r, number|nil g, number|nil b, number|nil a
function Swatch.Fill(value)
    if type(value) ~= "table" then return nil end
    local a = (value.a == nil) and 255 or value.a
    return value.r, value.g, value.b, a
end

---@param value any
---@return string
function Swatch.Format(value)
    return Color.FormatHex8(value)
end

---@param raw string
---@param current any
---@return any
function Swatch.Parse(raw, current)
    return Color.ParseHex8(raw, current)
end

---@param canvas any
---@param rect { x: number, y: number, w: number, h: number }
---@param ctrl table
---@param dctx DrawContext
function Swatch.Draw(canvas, rect, ctrl, dctx)
    local scale = dctx.scale
    if Swatch.IsEmpty(ctrl.value) then
        canvas:AddRectangle(rect.x, rect.y, rect.w, rect.h, Theme.Vec4(Theme.COL_CONTROL_BG))
    else
        Color.DrawChecker(canvas, rect.x, rect.y, rect.w, rect.h, scale(Theme.SWATCH_CHECKER_CELL),
            Theme.Vec4(Theme.COL_CHECKER_LIGHT), Theme.Vec4(Theme.COL_CHECKER_DARK))
        local r, g, b, a = Swatch.Fill(ctrl.value)
        canvas:AddRectangle(rect.x, rect.y, rect.w, rect.h,
            Vector4.new(r / 255, g / 255, b / 255, a / 255))
    end
    Box.Outline(canvas, rect.x, rect.y, rect.w, rect.h, scale, dctx.hot)
end

return Swatch
