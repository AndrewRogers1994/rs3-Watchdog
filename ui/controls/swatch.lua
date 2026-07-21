-- swatch.lua — the swatch Pin Control (ADR-0005 / #60): the per-Type-Tag module for a color pin.
-- It composes the swatch Widget and binds it to a `{ r, g, b, a }` Control value. Unlike the scalar
-- and enum Pin Controls it edits nothing itself — the whole edit lives in the Color Popup (#30,
-- ui/color_popup.lua), which keeps its own file and lifecycle. This module's job is just to place
-- the chip in the value column, project the stored color onto the swatch Widget for the Node's
-- draw, and OPEN the popup through the host on press, handing it the Widget's hex codec so the
-- popup needs no Control Spec of its own.
--
-- Like coordgrid/scalar/enum it is a plain module of DOT-functions the Node/Editor call
-- (Layout/ReservedHeight/Display/Press); the only Editor capability it reaches for — opening the
-- popup — goes through the `host` seam, whose test adapter (tests/fake_control_host.lua) records
-- the call so the press is asserted headless.

local Theme  = require("ui/theme")
local Swatch = require("ui/widgets/swatch")

-- The codec the Color Popup round-trips its one hex field through: a plain table the popup consumes
-- via its own :Format/:Parse (which call these hooks), so the popup keeps working with no Control
-- Spec knowledge at all. Module-shared — it closes over nothing per-instance.
local POPUP_CODEC = { widget = "swatch", format = Swatch.Format, parse = Swatch.Parse }

---@class SwatchPinControl
local SwatchControl = {}

-- A swatch Pin Control. Takes no config — every color pin edits the same way — but stays a factory
-- for symmetry with the other Pin Controls (and so a future per-tag palette could be threaded in).
---@return table
function SwatchControl.new()
    local M = {}

    -- INLINE: the chip sits in the single value-column box to the right of the label, like a scalar.
    M.Inline = true

    ---@return number
    function M.ReservedHeight(_pin) return 0 end

    -- A fixed-width chip flush against the value column's right edge (#30) — narrower than the full
    -- box so it reads as a color swatch, not a text field. `kind`/`widget` = "swatch" route the
    -- Node's draw to its checker+fill branch (via the swatch Widget) and the Editor's press here.
    ---@param box { x: number, y: number, w: number, h: number }
    ---@return table[]
    function M.Layout(box)
        local swW = math.min(Theme.SWATCH_W, box.w)
        return { {
            kind = "swatch", widget = "swatch",
            x = box.x + box.w - swW, y = box.y, w = swW, h = box.h,
        } }
    end

    -- The chip is drawn from ctrl.value directly (the swatch Widget's IsEmpty/Fill); Display is the
    -- textual projection the rest of the machinery expects, so it returns the hex the popup shows.
    ---@param ctrl table
    ---@return string
    function M.Display(ctrl)
        return Swatch.Format(ctrl.value)
    end

    -- Opens the Color Popup over the chip through the host, handing it the hex codec. The popup
    -- owns everything after that (sliders, hex field, dismiss); it commits live through the same
    -- setControl path every Control edit uses — this module never sees the picked color.
    ---@param host ControlHost
    ---@param _ctrl table
    function M.Press(host, _ctrl)
        host:OpenColorPopup(POPUP_CODEC)
    end

    return M
end

return SwatchControl
