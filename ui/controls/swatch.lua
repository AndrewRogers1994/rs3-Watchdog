local Theme  = require("ui/theme")
local Inline = require("ui/controls/inline")
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
    local M = Inline.apply({})

    -- A fixed-width chip flush against the value column's right edge (#30) — narrower than the full
    -- box so it reads as a color swatch, not a text field. `kind = "swatch"` names the row for the
    -- Editor's press/hit-test; the checker+fill paint is the swatch Widget's own draw (#63), routed
    -- through this module's Draw — no separate "widget" hint for the Node to branch on.
    ---@param box { x: number, y: number, w: number, h: number }
    ---@return table[]
    function M.Layout(box)
        local swW = math.min(Theme.SWATCH_W, box.w)
        return { {
            kind = "swatch",
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

    -- Draw: route to the swatch Widget (checker+fill / empty box + outline). The Node hands an
    -- already-projected screen rect + draw context; the Widget owns the Canvas blit now (#63).
    ---@param canvas any
    ---@param rect { x: number, y: number, w: number, h: number }
    ---@param ctrl table
    ---@param dctx DrawContext
    function M.Draw(canvas, rect, ctrl, dctx)
        Swatch.Draw(canvas, rect, ctrl, dctx)
    end

    return M
end

return SwatchControl
