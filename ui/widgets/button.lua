-- button.lua — the button Widget (ADR-0005): a generic input primitive whose "value" is a one-shot
-- press. It owns only its label and hit-test; the composing Pin Control decides what the press DOES.

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

return Button
