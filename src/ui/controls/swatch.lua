local Theme  = require("src/ui/theme")
local Inline = require("src/ui/controls/inline")
local Swatch = require("src/ui/widgets/swatch")

-- Hex codec for the Color Popup Format/Parse hooks; no Control Spec. Module-shared.
local POPUP_CODEC = { widget = "swatch", format = Swatch.Format, parse = Swatch.Parse }

---@class SwatchPinControl
local SwatchControl = {}

---@return table
function SwatchControl.new()
    local M = Inline.apply({})

    -- Fixed-width chip on the value column's right edge (#30). Paint is the swatch Widget (#63).
    ---@param box { x: number, y: number, w: number, h: number }
    ---@return table[]
    function M.Layout(box)
        local swW = math.min(Theme.SWATCH_W, box.w)
        return { {
            kind = "swatch",
            x = box.x + box.w - swW, y = box.y, w = swW, h = box.h,
        } }
    end

    ---@param ctrl table
    ---@return string
    function M.Display(ctrl)
        return Swatch.Format(ctrl.value)
    end

    ---@param host ControlHost
    ---@param _ctrl table
    function M.Press(host, _ctrl)
        host:OpenColorPopup(POPUP_CODEC)
    end

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
