-- capture.lua — the capture Pin Control (ADR-0005 / #60): the inline Control for a pin whose value is
-- authored by ARMING a capture rather than typed. Two flavors share this module, chosen by
-- `captureKind`: "screen" arms the drag overlay (ui/screen_marker_capture.lua), "object" the MiniMenu
-- select mode (ui/object_marker_capture.lua). This module only TRIGGERS the right one through the
-- host's ArmCapture; the overlay keeps its own lifecycle and commits the finished value itself.

local Inline = require("ui/controls/inline")
local Button = require("ui/widgets/button")

---@class CapturePinControl
local Capture = {}

-- A capture Pin Control. `opts.captureKind` is "screen" (default) or "object"; `opts.placeholder`
-- is the empty-state prompt drawn on the button ("Draw on screen" / "Select object");
-- `opts.format` projects a captured value to its summary text (nil -> the value never summarizes,
-- so the placeholder always shows).
---@param opts { captureKind: string|nil, placeholder: string|nil, format: (fun(value: any): string)|nil }|nil
---@return table
function Capture.new(opts)
    opts = opts or {}
    local captureKind = opts.captureKind or "screen"
    local placeholder = opts.placeholder or "Draw on screen"
    local format = opts.format
    local M = Inline.apply({})

    -- One full-width action box across the value column. `kind = "capture"` marks it a click-to-arm
    -- button (the button Widget's action background, never the transient editor); `placeholder` is
    -- its empty-state text. The action-box paint is routed through this module's Draw (#63).
    ---@param box { x: number, y: number, w: number, h: number }
    ---@return table[]
    function M.Layout(box)
        return { {
            kind = "capture", placeholder = placeholder,
            x = box.x, y = box.y, w = box.w, h = box.h,
        } }
    end

    -- The captured value's summary text (a rect "x,y wxh" or the object's name), or "" when nothing
    -- is captured — the empty string is what makes the Node fall back to the box's placeholder. The
    -- format hook is guarded (pcall) so a malformed stored value degrades to the placeholder rather
    -- than erroring the whole draw.
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

    -- Arms the capture through the host: the Screen Marker drag overlay for "screen", the Object
    -- Marker MiniMenu select mode for "object". The host maps the kind to the right runtime overlay
    -- (a headless/test host without one is a silent no-op) and the overlay commits when it finishes.
    ---@param host ControlHost
    ---@param _ctrl table
    function M.Press(host, _ctrl)
        host:ArmCapture(captureKind)
    end

    -- Draw: route to the button Widget (action box showing the captured summary, or the placeholder
    -- prompt when nothing is captured). The Node hands an already-projected screen rect + draw
    -- context; the empty-state fallback is Box.Draw's own (ctrl.placeholder), set in Layout.
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
