local Theme = require("src/ui/theme")
local Box   = require("src/ui/widgets/box")

---@class ToggleWidget
---@field modes table[]  -- { { value = <any>, label = <string> }, ... }, in cycle order
local Toggle = {}
Toggle.__index = Toggle

---@param modes table[]|nil
---@return ToggleWidget
function Toggle.new(modes)
    return setmetatable({ modes = modes or {} }, Toggle)
end

---@param value any
---@return string
function Toggle:Label(value)
    for _, m in ipairs(self.modes) do
        if m.value == value then return m.label end
    end
    local first = self.modes[1]
    return (first ~= nil) and first.label or ""
end

---@param value any
---@return any
function Toggle:Next(value)
    for i, m in ipairs(self.modes) do
        if m.value == value then
            return self.modes[(i % #self.modes) + 1].value
        end
    end
    local first = self.modes[1]
    return (first ~= nil) and first.value or nil
end

---@param canvas any
---@param rect { x: number, y: number, w: number, h: number }
---@param ctrl table
---@param dctx DrawContext
function Toggle.Draw(canvas, rect, ctrl, dctx)
    Box.Draw(canvas, rect, ctrl.display, ctrl.placeholder, Theme.COL_CONTROL_ACTION_BG, dctx)
end

return Toggle
