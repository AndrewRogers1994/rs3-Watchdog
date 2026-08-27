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

    -- One sub-rect: the value-column box. The dropdown caret is the dropdown Widget's own draw
    -- (#63), so the box carries no "enum" hint for the Node to branch on — it is a plain field rect.
    ---@param box { x: number, y: number, w: number, h: number }
    ---@return table[]
    function M.Layout(box)
        return { { kind = "field", x = box.x, y = box.y, w = box.w, h = box.h } }
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

    -- Draw: route to the dropdown Widget (box + ▾ caret). The Node hands an already-projected
    -- screen rect + draw context; the caret is the Widget's own, so the Node needs no "enum" branch.
    ---@param canvas any
    ---@param rect { x: number, y: number, w: number, h: number }
    ---@param ctrl table
    ---@param dctx DrawContext
    function M.Draw(canvas, rect, ctrl, dctx)
        dropdown:Draw(canvas, rect, ctrl, dctx)
    end

    return M
end

return Enum
