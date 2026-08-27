local Theme = require("ui/theme")
local Color = require("ui/color")

---@class DrawContext
---@field hot boolean                    # the cursor is over this control box
---@field font any                       # the draw-size font id (Theme.Font), or nil when zoomed too small to letter
---@field zoom number                    # the View zoom, for text-width measurement
---@field scale fun(n: number): number   # projects a graph-space length to screen (View:Scale, pre-bound)

local Box = {}

---@param font any
---@param colVec4 any
---@return ui.TextDataConfig
function Box.TextData(font, colVec4)
    ---@type ui.TextDataConfig
    local textData = ui.TextDataConfig.new()
    textData.font = font
    textData.colour = colVec4
    textData.isShadowed = true
    textData.shadowRGBA = Color.ToRGBA(0, 0, 0, 1)
    textData.maxLines = 1
    return textData
end

---@param canvas any
---@param x number
---@param y number
---@param w number
---@param h number
---@param scale fun(n: number): number
---@param hot boolean
function Box.Outline(canvas, x, y, w, h, scale, hot)
    canvas:AddOutline(x, y, w, h, math.max(1, scale(1)),
        Theme.Vec4(hot and Theme.COL_CONTROL_HOT or Theme.COL_CONTROL_BORDER))
end

---@param canvas any
---@param rect { x: number, y: number, w: number, h: number }
---@param display string|nil
---@param placeholder string|nil
---@param bg any
---@param dctx DrawContext
function Box.Draw(canvas, rect, display, placeholder, bg, dctx)
    local scale = dctx.scale
    canvas:AddRectangle(rect.x, rect.y, rect.w, rect.h, Theme.Vec4(bg))
    Box.Outline(canvas, rect.x, rect.y, rect.w, rect.h, scale, dctx.hot)

    if dctx.font ~= nil then
        local text = display
        local col = Theme.Vec4(Theme.COL_CONTROL_TEXT)
        if text == nil or text == "" then
            text, col = placeholder or "…", Theme.Vec4(Theme.COL_CONTROL_EMPTY)
        end
        local tw = Theme.TextWidth(11 * dctx.zoom, text) or (#text * scale(7))
        canvas:AddText(rect.x + scale(Theme.CONTROL_PAD_X), rect.y + rect.h * 0.5 - scale(6),
            tw, 0, text, Box.TextData(dctx.font, col))
    end
end

return Box
