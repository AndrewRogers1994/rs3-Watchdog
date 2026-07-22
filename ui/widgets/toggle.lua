-- toggle.lua — the toggle Widget (ADR-0005): a generic input primitive that cycles one value through
-- a fixed, ordered list of {value, label} modes on each press. It owns the current-mode LABEL, the
-- NEXT mode (wrapping for any length), and its action-button DRAW; the composing Pin Control decides
-- where that mode lives. matcher's Substring/Pattern toggle routes its Draw here.

local Theme = require("ui/theme")
local Box   = require("ui/widgets/box")

---@class ToggleWidget
---@field modes table[]  -- { { value = <any>, label = <string> }, ... }, in cycle order
local Toggle = {}
Toggle.__index = Toggle

---@param modes table[]|nil
---@return ToggleWidget
function Toggle.new(modes)
    return setmetatable({ modes = modes or {} }, Toggle)
end

-- The label for the current mode value. An unknown value (or nil) falls back to the first mode's
-- label, so an unseeded Control reads as its default mode rather than blank.
---@param value any
---@return string
function Toggle:Label(value)
    for _, m in ipairs(self.modes) do
        if m.value == value then return m.label end
    end
    local first = self.modes[1]
    return (first ~= nil) and first.label or ""
end

-- The next mode value after `value`, wrapping past the end. An unknown value (or nil) yields the
-- first mode, so the first press off an unseeded Control lands on a defined mode.
---@param value any
---@return any
function Toggle:Next(value)
    for i, m in ipairs(self.modes) do
        if m.value == value then
            return self.modes[(i % #self.modes) + 1].value
        end
    end
    local first = self.modes[1]
    return (first ~= nil) and first.value or nil
end

-- Draws the toggle at an already-projected screen `rect`: an action-tinted value box showing the
-- current mode's label (ctrl.display, always a defined mode — never the placeholder). Static — the
-- drawn text is the Pin Control's ctrl.display, matching how the other action boxes draw. `dctx` is
-- the projected draw context.
---@param canvas any
---@param rect { x: number, y: number, w: number, h: number }
---@param ctrl table
---@param dctx DrawContext
function Toggle.Draw(canvas, rect, ctrl, dctx)
    Box.Draw(canvas, rect, ctrl.display, ctrl.placeholder, Theme.COL_CONTROL_ACTION_BG, dctx)
end

return Toggle
