local Theme = require("src/ui/theme")
local Box   = require("src/ui/widgets/box")

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

--- One entry per label, with `order` set to the sequence index. A combo that
--- sorts by order and only then by label keeps this sequence. Native
--- ComboField:Add sorts by label and would not.
---@param labels string[]|nil
---@return { label: string, id: integer, order: integer }[]
function Dropdown.StableEntries(labels)
    local entries = {}
    for i, label in ipairs(labels or {}) do
        entries[i] = { label = label, id = i, order = i }
    end
    return entries
end

--- The sequence after an order-then-label sort. Distinct orders keep the
--- list that was passed in, which is the list the player sees.
---@param entries { label: string, order: integer|nil }[]|nil
---@return string[]
function Dropdown.VisibleOrder(entries)
    local result = {}
    for index, entry in ipairs(entries or {}) do
        result[index] = {
            label = entry.label,
            order = entry.order,
            index = index,
        }
    end
    table.sort(result, function(left, right)
        if left.order ~= right.order then
            if left.order == nil then return false end
            if right.order == nil then return true end
            return left.order < right.order
        end
        if left.label ~= right.label then return left.label < right.label end
        return left.index < right.index
    end)
    local labels = {}
    for i, entry in ipairs(result) do
        labels[i] = entry.label
    end
    return labels
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
