local Theme     = require("src/ui/theme")
local TextField = require("src/ui/widgets/text_field")
local Toggle    = require("src/ui/widgets/toggle")
local Text      = require("src/text")

---@class MatcherPinControl
local Matcher = {}

-- Unseeded matcher reads as Substring.
local toggle = Toggle.new({
    { value = "substring", label = "Substring" },
    { value = "pattern",   label = "Pattern" },
})

---@param value any
---@return string|nil
local function needleOf(value)
    return (type(value) == "table" and type(value.needle) == "string") and value.needle or nil
end

-- Never nil: toggle always cycles from a real mode.
---@param value any
---@return string  -- "substring" | "pattern"
local function modeOf(value)
    if type(value) == "table" and (value.mode == "pattern" or value.mode == "substring") then
        return value.mode
    end
    return "substring"
end

-- Fresh {needle, mode} with BOTH keys so setting one cannot drop the other.
---@param stored any
---@param default any
---@return { needle: string, mode: string }
local function rmw(stored, default)
    local updated = { needle = "", mode = "substring" }
    local base = (type(stored) == "table") and stored
        or ((type(default) == "table") and default or nil)
    if base ~= nil then
        if type(base.needle) == "string" then updated.needle = base.needle end
        if base.mode == "pattern" or base.mode == "substring" then updated.mode = base.mode end
    end
    return updated
end

---@return number
function Matcher.ReservedHeight(_pin)
    return Theme.MATCHER_BAND_H
end

-- Empty matcher matches anything (placeholder is generic, not per-node).
---@param band { x: number, y: number, w: number, h: number }
---@return table[]
function Matcher.Layout(band)
    local y = band.y + Theme.MATCHER_TOP_GAP
    local h = Theme.MATCHER_FIELD_H
    local toggleW = math.min(Theme.MATCHER_TOGGLE_W, band.w)
    local fieldW = band.w - toggleW - Theme.MATCHER_GAP
    if fieldW < 0 then fieldW = 0 end
    return {
        { kind = "needle", placeholder = "matches anything",
          x = band.x, y = y, w = fieldW, h = h },
        { kind = "toggle",
          x = band.x + fieldW + Theme.MATCHER_GAP, y = y, w = toggleW, h = h },
    }
end

---@param ctrl table
---@return string
function Matcher.Display(ctrl)
    if ctrl.kind == "toggle" then
        return toggle:Label(modeOf(ctrl.value))
    end
    return needleOf(ctrl.value) or ""
end

---@param host ControlHost
---@param ctrl table
function Matcher.Press(host, ctrl)
    if ctrl.kind == "toggle" then
        Matcher.ToggleMode(host, ctrl)
    else
        Matcher.EditNeedle(host, ctrl)
    end
end

-- Flip from ctrl.value (default-resolved) so a default-only matcher toggles from the shown mode.
---@param host ControlHost
---@param ctrl table
function Matcher.ToggleMode(host, ctrl)
    local updated = rmw(ctrl.value, ctrl.default)
    updated.mode = toggle:Next(updated.mode)
    host:Commit(updated)
end

-- Re-read from host so a concurrent mode flip isn't lost. Empty needle is a valid "match anything".
---@param host ControlHost
---@param ctrl table
function Matcher.EditNeedle(host, ctrl)
    host:MountField(ctrl, {
        filter = "NONE", maxLen = 128, initial = needleOf(ctrl.value) or "",
    }, function(raw)
        local updated = rmw(host:GetControl(), ctrl.default)
        updated.needle = (type(raw) == "string") and Text.StripTags(raw) or ""
        host:Commit(updated)
    end)
end

---@param canvas any
---@param rect { x: number, y: number, w: number, h: number }
---@param ctrl table
---@param dctx DrawContext
function Matcher.Draw(canvas, rect, ctrl, dctx)
    if ctrl.kind == "toggle" then
        Toggle.Draw(canvas, rect, ctrl, dctx)
    else
        TextField.Draw(canvas, rect, ctrl, dctx)
    end
end

return Matcher
