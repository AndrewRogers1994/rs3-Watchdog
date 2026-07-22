-- checkbox.lua — the checkbox Widget (ADR-0005 / #40): one mode-row draw — a label plus a small,
-- right-aligned box with a gold tick when checked. The mode Pin Control routes each of its rows here.
-- A disabled row (an unavailable mode, "needs render API") dims both the label and the tick and never
-- lights its border, matching the unavailable-node idiom. Depends only on Theme/Box (a Widget helper).

local Theme = require("ui/theme")
local Box   = require("ui/widgets/box")

local Checkbox = {}

-- Draws one mode row at an already-projected screen `rect`. `ctrl` carries the row's baked `enabled`
-- flag, its `axis` (the row's key in the stored `{ [key] = boolean }` table), the current `value`
-- table, and the decorated `display` label. `dctx = { hot, font, zoom, scale }` — `font` is nil when
-- the zoom is too small to letter, and then only the box glyph is drawn.
---@param canvas any
---@param rect { x: number, y: number, w: number, h: number }
---@param ctrl table
---@param dctx DrawContext
function Checkbox.Draw(canvas, rect, ctrl, dctx)
    local scale = dctx.scale
    local disabled = not ctrl.enabled
    local checked = ctrl.enabled and type(ctrl.value) == "table" and ctrl.value[ctrl.axis] == true
    local labelCol = disabled and Theme.COL_CONTROL_EMPTY or Theme.COL_CONTROL_TEXT
    if dctx.font ~= nil then
        local text = ctrl.display or ""
        local tw = Theme.TextWidth(11 * dctx.zoom, text) or (#text * scale(7))
        canvas:AddText(rect.x + scale(Theme.CONTROL_PAD_X), rect.y + rect.h * 0.5 - scale(6),
            tw, 0, text, Box.TextData(dctx.font, Theme.Vec4(labelCol)))
    end
    -- The checkbox: a small square right-aligned in the row, with a gold tick when checked. Box
    -- border tracks hot (unless disabled) so it reads as clickable.
    local boxSz = rect.h * 0.72
    local boxX = rect.x + rect.w - scale(Theme.CONTROL_PAD_X) - boxSz
    local boxY = rect.y + (rect.h - boxSz) * 0.5
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
