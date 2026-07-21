-- enum.lua — the enum Pin Control factory (ADR-0005): the per-Type-Tag module for a Control that
-- picks one value from a fixed choice list — the `bool` demonstrator and every domain enum Type
-- Tag (chat groups, toast icon, skill, …). Like a scalar it renders INLINE in the value column
-- (Inline = true), but drawn with a dropdown caret (the "enum" widget hint) and edited through a
-- transient ComboField the host mounts rather than a text field. One factory serves every enum
-- tag: it is built from that tag's registered choice list, so a new enum is still one
-- Controls.Register call with no Pin Control code of its own (controls.lua wires this factory in
-- automatically — see its auto-registration).
--
-- Selection round-trips by LABEL, never id (ADR-0004): the Widget maps value<->label, the host
-- reports back the picked label, and this module maps it home. A nil-valued choice ("None") is a
-- real selection, distinguished from "no match" by the Widget's `found` flag. A Pin Control reaches
-- the Editor only through the passed `host` (mount a dropdown, commit); its test adapter is the
-- fake host in tests/test_enum_control.lua, driving press->pick->commit headless.

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

    local M = {}
    M.Inline = true

    ---@return number
    function M.ReservedHeight(_pin) return 0 end

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
