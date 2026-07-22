-- button.lua — the button Widget (ADR-0005): a generic input primitive whose "value" is a one-shot
-- press. It owns its label, hit-test, and its action-button DRAW; the composing Pin Control decides
-- what the press DOES. coordgrid's grab button and the capture arm-button route their Draw here.

local Theme = require("ui/theme")
local Box   = require("ui/widgets/box")

---@class ButtonWidget
---@field label string
local Button = {}
Button.__index = Button

-- A button carrying a fixed label (e.g. "Set to current position"). A nil label is normalized
-- to "" so :Label() and any draw of it are always a string.
---@param label string|nil
---@return ButtonWidget
function Button.new(label)
    return setmetatable({ label = label or "" }, Button)
end

---@return string
function Button:Label()
    return self.label
end

-- Whether a point lands on the button, given its rect. Coordinates share the button rect's
-- own space (both edges inclusive) — the composing Pin Control passes a point already in that
-- space, so the Widget never has to know about the View, zoom, or the node origin.
---@param rect { x: number, y: number, w: number, h: number }
---@param x number
---@param y number
---@return boolean
function Button:HitTest(rect, x, y)
    return x >= rect.x and x <= rect.x + rect.w
        and y >= rect.y and y <= rect.y + rect.h
end

-- Draws the button at an already-projected screen `rect`: an action-tinted value box showing the
-- label (ctrl.display), or a dimmed placeholder when nothing is summarized yet (a capture's empty
-- state). Static — the drawn text is the Pin Control's ctrl.display, not an instance's own label,
-- because one module (coordgrid, capture) may draw many rows. `dctx` is the projected draw context.
---@param canvas any
---@param rect { x: number, y: number, w: number, h: number }
---@param ctrl table
---@param dctx DrawContext
function Button.Draw(canvas, rect, ctrl, dctx)
    Box.Draw(canvas, rect, ctrl.display, ctrl.placeholder, Theme.COL_CONTROL_ACTION_BG, dctx)
end

return Button
