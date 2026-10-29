local Theme = require("src/ui/theme")
local Box   = require("src/ui/widgets/box")

local Checkbox = {}

---@param canvas any
---@param rect { x: number, y: number, w: number, h: number }
---@param ctrl table
---@param dctx DrawContext
function Checkbox.Draw(canvas, rect, ctrl, dctx)
    local scale = dctx.scale
    local disabled = not ctrl.enabled
    local checked = ctrl.enabled and type(ctrl.value) == "table" and ctrl.value[ctrl.axis] == true
    local labelCol = disabled and Theme.COL_CONTROL_EMPTY or Theme.COL_CONTROL_TEXT
    local pad = scale(Theme.CONTROL_PAD_X)
    local boxSz = rect.h * 0.72
    local boxX = rect.x + pad
    local boxY = rect.y + (rect.h - boxSz) * 0.5
    if dctx.font ~= nil then
        -- Label sits to the right of the tick. Clip to that gap; measured width ellipsizes early.
        local textX = boxX + boxSz + pad
        local text = ctrl.display or ""
        canvas:AddText(textX, rect.y + rect.h * 0.5 - scale(6),
            rect.x + rect.w - pad - textX, rect.h, text, Box.TextData(dctx.font, Theme.Vec4(labelCol)))
    end
    canvas:AddRectangle(boxX, boxY, boxSz, boxSz, Theme.Vec4(Theme.COL_CHECK_BOX_BG))
    Box.Outline(canvas, boxX, boxY, boxSz, boxSz, scale, dctx.hot and not disabled)
    if checked then
        local tick = math.max(1, scale(1.5))
        local markCol = Theme.Vec4(disabled and Theme.COL_CONTROL_EMPTY or Theme.COL_CHECK_MARK)
        canvas:AddLine(boxX + boxSz * 0.20, boxY + boxSz * 0.52,
            boxX + boxSz * 0.42, boxY + boxSz * 0.74, tick, markCol)
        canvas:AddLine(boxX + boxSz * 0.42, boxY + boxSz * 0.74,
            boxX + boxSz * 0.80, boxY + boxSz * 0.26, tick, markCol)
    end
end

return Checkbox
