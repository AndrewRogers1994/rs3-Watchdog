local Inline = require("src/ui/controls/inline")
local Button = require("src/ui/widgets/button")

---@class CapturePinControl
local Capture = {}

-- opts.captureKind: "screen" (default) or "object". nil format -> placeholder always shows.
---@param opts { captureKind: string|nil, placeholder: string|nil, format: (fun(value: any): string)|nil }|nil
---@return table
function Capture.new(opts)
    opts = opts or {}
    local captureKind = opts.captureKind or "screen"
    local placeholder = opts.placeholder or "Draw on screen"
    local format = opts.format
    local M = Inline.apply({})

    -- kind = "capture": click-to-arm action box; paint via Draw (#63).
    ---@param box { x: number, y: number, w: number, h: number }
    ---@return table[]
    function M.Layout(box)
        return { {
            kind = "capture", placeholder = placeholder,
            x = box.x, y = box.y, w = box.w, h = box.h,
        } }
    end

    -- pcall: malformed stored value must not error the draw. "" falls back to placeholder.
    ---@param ctrl table
    ---@return string
    function M.Display(ctrl)
        if ctrl.captureArmed then
            return "Cancel"
        end
        if format ~= nil then
            local ok, s = pcall(format, ctrl.value)
            if ok and s ~= nil then return tostring(s) end
        end
        return ""
    end

    ---@param host ControlHost
    ---@param _ctrl table
    function M.Press(host, _ctrl)
        host:ArmCapture(captureKind)
    end

    ---@param canvas any
    ---@param rect { x: number, y: number, w: number, h: number }
    ---@param ctrl table
    ---@param dctx DrawContext
    function M.Draw(canvas, rect, ctrl, dctx)
        Button.Draw(canvas, rect, ctrl, dctx)
    end

    return M
end

return Capture
