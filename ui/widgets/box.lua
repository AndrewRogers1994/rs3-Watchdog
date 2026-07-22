-- box.lua — the labeled-box Widget helper (ADR-0005): the shared value box every text-like Widget
-- paints — a filled rect, a hot-aware outline, and left-aligned text (or a dimmed placeholder when
-- empty). text_field/number_field/dropdown/button/toggle all route their Draw through it, so the box
-- look lives in one place instead of a per-`kind` branch in node.lua (the render seam this closes).
-- Depends only on Theme/Color/ui.* — never a Pin Control, the Editor, the Store, or the engine
-- (the Widget dependency rule, ADR-0005).

local Theme = require("ui/theme")
local Color = require("ui/color")

-- The projected draw context the Node hands every Widget's Draw: the screen-space projection facts a
-- Widget needs but must never derive itself (it never sees `view`/ToScreen/Scale — ADR-0005 §1).
---@class DrawContext
---@field hot boolean                    # the cursor is over this control box
---@field font any                       # the draw-size font id (Theme.Font), or nil when zoomed too small to letter
---@field zoom number                    # the View zoom, for text-width measurement
---@field scale fun(n: number): number   # projects a graph-space length to screen (View:Scale, pre-bound)

local Box = {}

-- The 1-line, shadowed TextDataConfig every control-box label uses, mirroring node.lua's own
-- createTextDataConfig so a Widget's text matches the node's labels exactly (same shadow, maxLines).
-- `colVec4` is an already-resolved Vector4 (Theme.Vec4 of a color constant).
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

-- The hot-aware outline every control box shares: a 1px (scaled) border, lit COL_CONTROL_HOT when
-- `hot`, else COL_CONTROL_BORDER. Kept separate from Box.Draw so the swatch and checkbox — whose
-- fills differ, so they can't route through Box.Draw — still frame themselves with the same rule.
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

-- Draws a value box at an already-projected screen `rect`: a `bg`-filled rectangle, a hot-aware
-- outline, and the display text left-aligned inside it. An empty/nil `display` falls back to
-- `placeholder` (or "…") in the dim empty color — the empty-state cue #30/#40 rely on. `bg` is a
-- Theme color constant; `dctx = { hot, font, zoom, scale }` carries the projected draw context —
-- `font` is nil when zoomed too small to letter, and then only the box (rect + outline) is drawn.
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
