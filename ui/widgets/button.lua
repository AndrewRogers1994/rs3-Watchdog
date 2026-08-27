local Theme = require("ui/theme")
local Box   = require("ui/widgets/box")

---@class ButtonWidget
---@field label string
local Button = {}
Button.__index = Button

---@param label string|nil
---@return ButtonWidget
function Button.new(label)
    return setmetatable({ label = label or "" }, Button)
end

---@return string
function Button:Label()
    return self.label
end

---@param rect { x: number, y: number, w: number, h: number }
---@param x number
---@param y number
---@return boolean
function Button:HitTest(rect, x, y)
    return x >= rect.x and x <= rect.x + rect.w
        and y >= rect.y and y <= rect.y + rect.h
end

---@param canvas any
---@param rect { x: number, y: number, w: number, h: number }
---@param ctrl table
---@param dctx DrawContext
function Button.Draw(canvas, rect, ctrl, dctx)
    Box.Draw(canvas, rect, ctrl.display, ctrl.placeholder, Theme.COL_CONTROL_ACTION_BG, dctx)
end

return Button
