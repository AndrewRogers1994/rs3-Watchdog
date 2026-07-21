-- capture.lua — the capture Pin Control (ADR-0005 / #60): the per-Type-Tag module for a pin whose
-- value is authored by ARMING a capture rather than typed. Two flavors share this one module,
-- chosen by `captureKind`: Screen Marker's `rect` arms the full-screen drag overlay
-- (ui/screen_marker_capture.lua), Object Marker's `object` arms the MiniMenu select mode
-- (ui/object_marker_capture.lua). Both overlays keep their own files and lifecycles — this module
-- only TRIGGERS the right one through the host's ArmCapture capability, and the overlay commits the
-- finished value back through the normal setControl path.
--
-- Its box is a full-width value-column "button" (kind = "capture" routes the Node's draw to the
-- action-styled box and never to the transient text/combo editor). Display projects the captured
-- value to a short summary via the format hook the node supplied (a rect "x,y wxh" or the object's
-- name), falling back to the box's placeholder when nothing's been captured yet. Like the other
-- Pin Controls it is a plain module of DOT-functions reached through the host seam, whose test
-- adapter records the ArmCapture call so the press is asserted headless.

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
    local M = {}

    -- INLINE: a single value-column box on the pin's own row, like a scalar — no reserved band.
    M.Inline = true

    ---@return number
    function M.ReservedHeight(_pin) return 0 end

    -- One full-width action box across the value column. `kind = "capture"` marks it a click-to-arm
    -- button (action background, never the transient editor); `placeholder` is its empty-state text.
    ---@param box { x: number, y: number, w: number, h: number }
    ---@return table[]
    function M.Layout(box)
        return { {
            kind = "capture", widget = "capture", placeholder = placeholder,
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

    return M
end

return Capture
