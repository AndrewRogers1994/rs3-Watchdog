local Inline = require("ui/controls/inline")

---@class ScalarPinControl
local Scalar = {}

---@param opts { codec: table, filter: string }
---@return table
function Scalar.new(opts)
    local codec = opts.codec
    local filter = opts.filter or "NONE"

    local M = Inline.apply({})

    ---@param box { x: number, y: number, w: number, h: number }
    ---@return table[]
    function M.Layout(box)
        return { { kind = "field", x = box.x, y = box.y, w = box.w, h = box.h } }
    end

    ---@param ctrl table
    ---@return string
    function M.Display(ctrl)
        return codec.Format(ctrl.value)
    end

    -- Nil parse (number empty-box guard) is not committed; any non-nil result is.
    ---@param host ControlHost
    ---@param ctrl table
    function M.Press(host, ctrl)
        host:MountField(ctrl, {
            filter = filter, maxLen = 128, initial = codec.Format(ctrl.value),
        }, function(raw, quantity)
            local value = codec.Parse(raw, quantity)
            if value ~= nil then host:Commit(value) end
        end)
    end

    ---@param canvas any
    ---@param rect { x: number, y: number, w: number, h: number }
    ---@param ctrl table
    ---@param dctx DrawContext
    function M.Draw(canvas, rect, ctrl, dctx)
        codec.Draw(canvas, rect, ctrl, dctx)
    end

    return M
end

return Scalar
