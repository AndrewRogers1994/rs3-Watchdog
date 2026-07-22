-- matcher.lua — the matcher Pin Control (ADR-0005): the composite BAND for the reusable Matcher's
-- `{ needle, mode }` table Control (#56) — a needle text field beside a Substring/Pattern toggle on
-- one row below the pin. It binds both Widgets to the table read-modify-write, so writing the needle
-- preserves the mode and vice versa. Unlike coordgrid's numeric axes, an EMPTY needle is meaningful
-- (an empty Matcher matches every line), so it commits verbatim — no empty-box guard on the needle.

local Theme     = require("ui/theme")
local TextField = require("ui/widgets/text_field")
local Toggle    = require("ui/widgets/toggle")

---@class MatcherPinControl
local Matcher = {}

-- The two modes, in cycle order. Substring is the default (an unseeded matcher reads as Substring).
local toggle = Toggle.new({
    { value = "substring", label = "Substring" },
    { value = "pattern",   label = "Pattern" },
})

-- The needle string of a stored value, or nil when unset/not-a-table.
---@param value any
---@return string|nil
local function needleOf(value)
    return (type(value) == "table" and type(value.needle) == "string") and value.needle or nil
end

-- The mode of a stored value, normalized to a defined mode (defaults to substring). Never nil, so
-- the toggle Widget always cycles from a real mode.
---@param value any
---@return string  -- "substring" | "pattern"
local function modeOf(value)
    if type(value) == "table" and (value.mode == "pattern" or value.mode == "substring") then
        return value.mode
    end
    return "substring"
end

-- Read-modify-write base for the {needle, mode} table: starts from the stored value (or the pin
-- default when unseeded), yielding a fresh table with BOTH keys present so a caller can set one
-- without dropping the other. Same shape as the old Editor:matcherRMW this replaces.
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

-- (a) The band height reserved below the pin row for the needle field + mode toggle.
---@return number
function Matcher.ReservedHeight(_pin)
    return Theme.MATCHER_BAND_H
end

-- (b) Lays the needle field (left) and the mode toggle (right) out on one row within the reserved
-- `band` (graph-space, relative to the node origin). Byte-identical geometry to the old composite
-- spec's Layout so the migrated Control draws exactly where it did. The needle carries a generic
-- empty-state placeholder (an empty matcher matches anything, whatever node it sits on).
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

-- (c) The text a sub-rect shows: the needle field shows just the `needle` string (empty falls back
-- to the placeholder, drawn dimmed by node.lua); the toggle shows the current mode's label.
---@param ctrl table
---@return string
function Matcher.Display(ctrl)
    if ctrl.kind == "toggle" then
        return toggle:Label(modeOf(ctrl.value))
    end
    return needleOf(ctrl.value) or ""
end

-- (d) Click. The needle mounts a transient text editor; the toggle flips the mode in one shot.
---@param host ControlHost
---@param ctrl table
function Matcher.Press(host, ctrl)
    if ctrl.kind == "toggle" then
        Matcher.ToggleMode(host, ctrl)
    else
        Matcher.EditNeedle(host, ctrl)
    end
end

-- Flips Substring <-> Pattern, read-modify-write against the whole table so the needle survives.
-- Bases the flip on ctrl.value (already default-resolved in the geometry rebuild) so the first
-- flip off a default-only matcher toggles from the shown mode rather than re-deriving nil.
---@param host ControlHost
---@param ctrl table
function Matcher.ToggleMode(host, ctrl)
    local updated = rmw(ctrl.value, ctrl.default)
    updated.mode = toggle:Next(updated.mode)
    host:Commit(updated)
end

-- Mounts a text field over the needle box, seeded from the current needle, and commits the whole
-- table on every change with the mode preserved (re-read fresh from the host so a concurrent mode
-- flip isn't lost). Empty text is committed verbatim — an empty needle is a valid "match anything".
---@param host ControlHost
---@param ctrl table
function Matcher.EditNeedle(host, ctrl)
    host:MountField(ctrl, {
        filter = "NONE", maxLen = 128, initial = needleOf(ctrl.value) or "",
    }, function(raw)
        local updated = rmw(host:GetControl(), ctrl.default)
        updated.needle = (type(raw) == "string") and raw or ""
        host:Commit(updated)
    end)
end

-- (e) Draw one sub-rect: the "toggle" is an action button (Toggle) showing the mode label; the
-- needle is a plain text box (TextField) with the "matches anything" placeholder when empty. The
-- kind discriminator stays internal to this composite — the Node calls this once per sub-rect with
-- an already-projected screen rect + draw context.
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
