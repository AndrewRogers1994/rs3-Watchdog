-- dropdown.lua — the dropdown Widget (ADR-0005): a generic input primitive selecting one value from
-- a fixed list of {value, label} choices. It owns only the value<->label mapping (the real
-- ui.ComboField is host-mounted). Selection round-trips by LABEL TEXT, never id — a ComboField
-- reorders alphabetically and reassigns ids (ADR-0004). A choice's `value` may legitimately be nil
-- (e.g. "None"), so ValueForLabel returns a `found` boolean rather than overloading nil as no-match.

---@class DropdownWidget
---@field choices table[]  -- { { value = <any>, label = <string> }, ... }
local Dropdown = {}
Dropdown.__index = Dropdown

-- A dropdown over a fixed choice list (declaration order preserved; it need not be alphabetical —
-- the mount re-sorts for display but selection is by label, so order here is purely cosmetic).
---@param choices table[]|nil
---@return DropdownWidget
function Dropdown.new(choices)
    return setmetatable({ choices = choices or {} }, Dropdown)
end

-- The choice labels, in declaration order — what the host feeds ComboField:Add.
---@return string[]
function Dropdown:Labels()
    local labels = {}
    for i, c in ipairs(self.choices) do labels[i] = c.label end
    return labels
end

-- The label for a stored value, or nil when no choice matches (the composing Pin Control decides
-- what an unmatched value displays as). A nil value matches a nil-valued choice (e.g. "None").
---@param value any
---@return string|nil
function Dropdown:LabelForValue(value)
    for _, c in ipairs(self.choices) do
        if c.value == value then return c.label end
    end
    return nil
end

-- The value a label maps to, plus a `found` flag. `found` is what lets a nil-valued choice
-- ("None") round-trip: ValueForLabel("None") returns (nil, true), distinct from (nil, false) for
-- a label that isn't a choice at all.
---@param label string
---@return any value, boolean found
function Dropdown:ValueForLabel(label)
    for _, c in ipairs(self.choices) do
        if c.label == label then return c.value, true end
    end
    return nil, false
end

return Dropdown
