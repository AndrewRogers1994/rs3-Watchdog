local Inline   = require("src/ui/controls/inline")
local Dropdown = require("src/ui/widgets/dropdown")

---@class EnumPinControl
local Enum = {}

---@param choices table[]
---@return table
function Enum.new(choices)
    local dropdown = Dropdown.new(choices)

    local M = Inline.apply({})

    -- Caret is the dropdown Widget's draw (#63).
    ---@param box { x: number, y: number, w: number, h: number }
    ---@return table[]
    function M.Layout(box)
        return { { kind = "field", x = box.x, y = box.y, w = box.w, h = box.h } }
    end

    -- Unmatched non-nil falls back to tostring (old Controls.Format enum path); unmatched nil is "".
    ---@param ctrl table
    ---@return string
    function M.Display(ctrl)
        local label = dropdown:LabelForValue(ctrl.value)
        if label ~= nil then return label end
        if ctrl.value == nil then return "" end
        return tostring(ctrl.value)
    end

    -- `found` lets a nil-valued "None" pick commit nil rather than be dropped.
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
