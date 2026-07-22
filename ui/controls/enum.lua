-- enum.lua — the enum Pin Control factory (ADR-0005): the inline Control that picks one value from a
-- fixed choice list (the `bool` demonstrator and every domain enum tag). Drawn with a dropdown caret
-- and edited through a host-mounted ComboField. Selection round-trips by LABEL, never id (ADR-0004),
-- so a nil-valued choice ("None") is distinguished from "no match" by the Widget's `found` flag.

local Inline   = require("ui/controls/inline")
local Dropdown = require("ui/widgets/dropdown")

---@class EnumPinControl
local Enum = {}

-- Builds an enum Pin Control module over a choice list ({ {value, label}, ... }). Returns a plain
-- module table (dot-functions, like coordgrid) so the Node/Editor call it uniformly; the Dropdown
-- Widget is captured in the closures.
---@param choices table[]
---@return table
function Enum.new(choices)
    local dropdown = Dropdown.new(choices)

    local M = Inline.apply({})

    -- One sub-rect: the value-column box, tagged with the "enum" widget hint so node.lua draws the
    -- dropdown caret (the box is otherwise a plain text box).
    ---@param box { x: number, y: number, w: number, h: number }
    ---@return table[]
    function M.Layout(box)
        return { { kind = "field", widget = "enum", x = box.x, y = box.y, w = box.w, h = box.h } }
    end

    -- The label for the current value. An unmatched non-nil value falls back to its raw string
    -- (mirrors the old Controls.Format enum path); an unmatched nil shows empty.
    ---@param ctrl table
    ---@return string
    function M.Display(ctrl)
        local label = dropdown:LabelForValue(ctrl.value)
        if label ~= nil then return label end
        if ctrl.value == nil then return "" end
        return tostring(ctrl.value)
    end

    -- Click: mount the dropdown seeded to the current value's label (or the first choice when the
    -- value matches nothing), committing the picked label's value. `found` guards a stray label the
    -- widget doesn't know — and lets a nil-valued "None" pick commit nil rather than be dropped.
    ---@param host ControlHost
    ---@param ctrl table
    function M.Press(host, ctrl)
        local labels = dropdown:Labels()
        local initial = dropdown:LabelForValue(ctrl.value) or labels[1]
        host:MountDropdown(ctrl, { labels = labels, initial = initial }, function(label)
            local value, found = dropdown:ValueForLabel(label)
            if found then host:Commit(value) end
        end)
    end

    return M
end

return Enum
