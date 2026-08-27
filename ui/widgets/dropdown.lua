local Theme = require("ui/theme")
local Box   = require("ui/widgets/box")

---@class DropdownWidget
---@field choices table[]  -- { { value = <any>, label = <string> }, ... }
local Dropdown = {}
Dropdown.__index = Dropdown

---@param choices table[]|nil
---@return DropdownWidget
function Dropdown.new(choices)
    return setmetatable({ choices = choices or {} }, Dropdown)
end

---@return string[]
function Dropdown:Labels()
    local labels = {}
    for i, c in ipairs(self.choices) do labels[i] = c.label end
    return labels
end

---@param value any
---@return string|nil
function Dropdown:LabelForValue(value)
    for _, c in ipairs(self.choices) do
        if c.value == value then return c.label end
    end
    return nil
end

-- ComboField reorders by label and may assign ids; a nil choice value ("None") needs `found`.
---@param label string
---@return any value, boolean found
function Dropdown:ValueForLabel(label)
    for _, c in ipairs(self.choices) do
        if c.label == label then return c.value, true end
    end
    return nil, false
end

---@param canvas any
---@param rect { x: number, y: number, w: number, h: number }
---@param ctrl table
---@param dctx DrawContext
function Dropdown:Draw(canvas, rect, ctrl, dctx)
    Box.Draw(canvas, rect, ctrl.display, ctrl.placeholder, Theme.COL_CONTROL_BG, dctx)
    local scale = dctx.scale
    local cxr = rect.x + rect.w - scale(7)
    local cyr = rect.y + rect.h * 0.5
    local a = scale(3)
    canvas:AddTriangle(cxr - a, cyr - a, cxr + a, cyr - a, cxr, cyr + a,
        Theme.Vec4(Theme.COL_CONTROL_CARET))
end

return Dropdown
