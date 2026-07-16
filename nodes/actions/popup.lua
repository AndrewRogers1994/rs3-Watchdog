-- popup.lua — the Popup action node (`action.popup`, #38): a collection-log / league-task
-- style banner that animates in at top-centre, holds, and fades out, all on the always-on
-- overlay Canvas (see effects.lua / #29). It is *self-drawn* (RS3 has no native popup API,
-- per TODO.md) and *auto-expiring*, so unlike the dismiss-pin effects it needs no dismiss
-- exec pin — the single `body` data pin is the only wire-able input.
--
-- Config vs. wiring: `title` / `icon` / `theme` / `hold` are node-config expressed the only
-- way this engine stores per-node config — as data-input pins carrying Controls (ADR-0004's
-- Control Box). They default to sensible values and are meant to be set inline rather than
-- wired; `body` is the one input a graph typically connects. `icon` and `theme` reuse the
-- enum Control (a curated dropdown), registered via ui/controls.lua's Control Spec seam.
--
-- Concurrency is Queue-only (AC): every popup, from any Popup node in any alert, shares one
-- owner key so at most one banner is on screen at a time and the rest wait their turn —
-- exactly how a real collection-log / task-complete popup behaves.
--
-- Sprite ids for the Leagues theme come from the #20 research (docs/research/popup-frame-
-- sprites.md), stored as bare numeric literals (with their `id.Sprite` constant name in a
-- comment) rather than `id.Sprite.X` lookups so this module loads under the standalone Lua
-- test harness where the client `id` global is absent. Native piece dimensions and the
-- STATICONS skill-index map are flagged build-verify in the research and the theme table.

local Popup = {}

--- Animation timeline --------------------------------------------------------------------
-- Fixed in/out ramps; only HOLD is author-configurable (~4s default, per AC). Durations are
-- in seconds and advanced against main.lua's LOGIC_TICK_SECONDS via the effect handle's
-- update(dt), the same fixed-dt convention every effect uses.
Popup.IN_SECONDS = 0.3
Popup.OUT_SECONDS = 0.4
Popup.DEFAULT_HOLD_SECONDS = 4.0

-- Owner key every popup handle is queued under, so all popups (across all Popup nodes and
-- all alerts) share a single Queue — one banner live, the rest pending (AC: Queue-only).
Popup.OWNER = "action.popup"

-- Pure animation state for a given `elapsed` time and `hold` duration: the phase name and a
-- 0..1 alpha for fading. Split out from the handle so it's unit-testable without any Canvas.
-- A zero/negative hold collapses to just the in->out ramps (still valid, never divides by 0).
function Popup.Anim(elapsed, hold)
    hold = tonumber(hold) or Popup.DEFAULT_HOLD_SECONDS
    if hold < 0 then hold = 0 end
    local inT = Popup.IN_SECONDS
    local outT = Popup.OUT_SECONDS
    local holdEnd = inT + hold
    local total = holdEnd + outT
    if elapsed < inT then
        local t = inT > 0 and (elapsed / inT) or 1
        return { phase = "in", alpha = t, progress = t }
    elseif elapsed < holdEnd then
        return { phase = "hold", alpha = 1, progress = 1 }
    elseif elapsed < total then
        local t = outT > 0 and ((elapsed - holdEnd) / outT) or 1
        local alpha = 1 - t
        if alpha < 0 then alpha = 0 end
        return { phase = "out", alpha = alpha, progress = 1 - t }
    end
    return { phase = "done", alpha = 0, progress = 0 }
end

--- Theme registry -----------------------------------------------------------------------
-- A theme is a plain descriptor the Draw reads: `kind` ("primitive" = Canvas rectangles;
-- "sprites" = multi-part sprite frame), a `label` for the dropdown, colors, and (for the
-- sprite kind) the assembled left/mid/right sprite ids. New themes are one RegisterTheme
-- call — the registry seam the AC asks for. `_order` keeps declaration order for the
-- dropdown so Parchment (the default) stays first.

Popup.DEFAULT_THEME = "parchment"

local themes = {}
local themeOrder = {}

function Popup.RegisterTheme(name, descriptor)
    assert(type(name) == "string" and name ~= "", "theme name must be a non-empty string")
    assert(type(descriptor) == "table", "theme descriptor must be a table")
    if themes[name] == nil then
        themeOrder[#themeOrder + 1] = name
    end
    descriptor.name = name
    themes[name] = descriptor
    return descriptor
end

-- The theme for `name`, falling back to the default (Parchment) for nil/unknown names so a
-- stale or blank `theme` control never leaves the banner un-drawable.
function Popup.ThemeFor(name)
    return themes[name] or themes[Popup.DEFAULT_THEME]
end

-- { value, label } choices for the `theme` enum Control, in registration order.
function Popup.ThemeChoices()
    local choices = {}
    for _, name in ipairs(themeOrder) do
        choices[#choices + 1] = { value = name, label = themes[name].label or name }
    end
    return choices
end

-- Parchment (default): a primitive, sprite-free banner drawn from Canvas rectangles + text,
-- so it works with zero sprite-id assumptions. Colors are {r,g,b,a} 0..1, converted to the
-- client Vector4 at draw time.
Popup.RegisterTheme("parchment", {
    kind = "primitive",
    label = "Parchment",
    bg     = { 0.90, 0.83, 0.63, 0.97 }, -- aged-paper fill
    border = { 0.36, 0.26, 0.12, 1.0 },
    title  = { 0.24, 0.16, 0.06, 1.0 },
    body   = { 0.16, 0.11, 0.05, 1.0 },
})

-- Leagues: the authentic league-task ribbon, assembled multi-part (left / stretchable middle
-- / right) from the RS3_RIBBON_LEAGUES_GOLD_* sprite set so it sidesteps the AddSprite-stretch
-- unknown flagged in the #20 research (single sprites distort; a 3-part frame keeps its ends
-- crisp). ids are the gold variant; swap `sprites` for RED (35189-35191) or RED_GOLD
-- (35192-35194) to reskin. Native piece widths are unknown from the docs — BUILD-VERIFY in
-- client and set `edgeW` to the measured end-cap width.
Popup.RegisterTheme("leagues", {
    kind = "sprites",
    label = "Leagues",
    sprites = {
        left  = 35186, -- id.Sprite.RS3_RIBBON_LEAGUES_GOLD_0
        mid   = 35187, -- id.Sprite.RS3_RIBBON_LEAGUES_GOLD_1  (stretch this)
        right = 35188, -- id.Sprite.RS3_RIBBON_LEAGUES_GOLD_2
    },
    edgeW = 24, -- BUILD-VERIFY: end-cap width in px; middle stretches to fill the remainder.
    title = { 1.0, 0.92, 0.60, 1.0 },
    body  = { 1.0, 1.0, 1.0, 1.0 },
})

--- Curated notification-icon dropdown ----------------------------------------------------
-- A hand-picked subset of the #20 research's icon table (ids are High-confidence *icons*).
-- Reuses the enum Control like `theme`. "None" (value nil) draws no icon. Skill icons come
-- from STATICONS_* (build-verify the exact index->skill map — the research notes 0 = Attack).
Popup.ICONS = {
    { value = nil,   label = "None" },
    { value = 17127, label = "Checkmark" },      -- id.Sprite.RS3_ICON_CHECK_MARK_24PX_0
    { value = 12764, label = "Star" },           -- id.Sprite.ICON_STAR_FILL
    { value = 431,   label = "Coins" },          -- id.Sprite.COINS
    { value = 937,   label = "Exclamation" },    -- id.Sprite.EXCLAMATION_MARK
    { value = 15064, label = "Collection Log" }, -- id.Sprite.RS3_ICON_BOSS_COLLECTION_LOG_0
    { value = 6953,  label = "Quest" },          -- id.Sprite.ICON_RIBBON_QUESTS_INACTIVE
}

function Popup.IconChoices()
    return Popup.ICONS
end

--- Draw (client-only; untested under the standalone harness) -----------------------------
-- Assembles the banner top-centre on the overlay `canvas`, fading with `anim.alpha`. Every
-- client-global touch (Vector4, id.Sprite, canvas methods) is inside the pcall the caller
-- (EffectRegistry:Draw) already wraps and additionally guarded here, so a missing global or
-- a bad sprite id degrades to "nothing drawn this frame" instead of erroring sibling effects.

local BANNER_W = 420
local BANNER_H = 74
local TOP_MARGIN = 24

local function vec4(c, alpha)
    return Vector4.new(c[1], c[2], c[3], (c[4] or 1) * alpha)
end

-- Best-effort screen width so the banner centres horizontally; the percent-sized overlay
-- Canvas doesn't reliably expose pixel width, so fall back to a sane default (1920).
local function screenWidth(canvas)
    local w = 1920
    if canvas ~= nil and type(canvas.width) == "number" and canvas.width > 0 then
        w = canvas.width
    end
    return w
end

function Popup.Draw(canvas, opts)
    if canvas == nil or Vector4 == nil then
        return
    end
    local anim = opts.anim or { alpha = 1 }
    local alpha = anim.alpha or 1
    if alpha <= 0 then
        return
    end
    local theme = opts.theme or Popup.ThemeFor(Popup.DEFAULT_THEME)
    local sw = screenWidth(canvas)
    local x = (sw - BANNER_W) * 0.5
    local y = TOP_MARGIN

    -- Frame: primitive rectangles, or the assembled 3-part sprite ribbon.
    if theme.kind == "sprites" and canvas.AddSprite ~= nil and id ~= nil then
        local s = theme.sprites
        local edge = theme.edgeW or 24
        local white = Vector4.new(1, 1, 1, alpha)
        canvas:AddSprite(x, y, edge, BANNER_H, s.left, white)
        canvas:AddSprite(x + edge, y, BANNER_W - edge * 2, BANNER_H, s.mid, white)
        canvas:AddSprite(x + BANNER_W - edge, y, edge, BANNER_H, s.right, white)
    else
        canvas:AddRectangle(x, y, BANNER_W, BANNER_H, vec4(theme.bg or { 0.1, 0.1, 0.12, 0.95 }, alpha))
        if canvas.AddOutline ~= nil then
            canvas:AddOutline(x, y, BANNER_W, BANNER_H, 2, vec4(theme.border or { 0, 0, 0, 1 }, alpha))
        end
    end

    -- Icon on the left, if one was picked and sprites are available.
    local textX = x + 16
    if opts.icon ~= nil and canvas.AddSprite ~= nil then
        local iconSize = 40
        pcall(function()
            canvas:AddSprite(x + 12, y + (BANNER_H - iconSize) * 0.5, iconSize, iconSize,
                opts.icon, Vector4.new(1, 1, 1, alpha))
        end)
        textX = x + 12 + iconSize + 12
    end

    -- Title + body, if fonts resolve.
    if canvas.AddText ~= nil then
        local Theme = require("ui/theme")
        local titleFont = Theme.Font(18)
        local bodyFont = Theme.Font(14)
        local title = opts.title
        if title ~= nil and title ~= "" and titleFont ~= nil then
            canvas:AddText(textX, y + 12, tostring(title), titleFont, vec4(theme.title or { 1, 1, 1, 1 }, alpha))
        end
        local body = opts.body
        if body ~= nil and body ~= "" and bodyFont ~= nil then
            canvas:AddText(textX, y + 40, tostring(body), bodyFont, vec4(theme.body or { 1, 1, 1, 1 }, alpha))
        end
    end
end

--- Effect handle -------------------------------------------------------------------------
-- The uniform { kind, state, update(dt) -> alive, draw(canvas) } handle EffectRegistry holds.
-- `update` accumulates elapsed time and recomputes the animation; it returns falsy once the
-- timeline is spent, at which point the registry culls it (and promotes the next queued
-- popup). No onDone is needed — auto-expiry is the whole lifecycle.
function Popup.BuildHandle(spec)
    spec = spec or {}
    local hold = tonumber(spec.hold) or Popup.DEFAULT_HOLD_SECONDS
    if hold < 0 then hold = 0 end
    local total = Popup.IN_SECONDS + hold + Popup.OUT_SECONDS
    local theme = Popup.ThemeFor(spec.theme)
    local elapsed = 0
    local state = { elapsed = 0, anim = Popup.Anim(0, hold) }

    return {
        kind = "popup",
        state = state,
        update = function(dt)
            elapsed = elapsed + (tonumber(dt) or 0)
            state.elapsed = elapsed
            state.anim = Popup.Anim(elapsed, hold)
            return elapsed < total
        end,
        draw = function(canvas)
            Popup.Draw(canvas, {
                title = spec.title,
                body = spec.body,
                icon = spec.icon,
                theme = theme,
                anim = state.anim,
            })
        end,
    }
end

--- Node registration ---------------------------------------------------------------------

function Popup.Register(registry, runtime)
    -- Register the two enum Control Specs the config pins use (curated dropdowns), reusing
    -- ADR-0004's Control Spec seam. Presentation lives in ui/controls.lua; the domain data
    -- (themes/icons) lives here, so this is where the two meet. Guarded so a headless/test
    -- require of this module (no ui layer wanted) still registers the node itself.
    pcall(function()
        local Controls = require("ui/controls")
        Controls.Register("popup.theme", { widget = "enum", choices = Popup.ThemeChoices() })
        Controls.Register("popup.icon", { widget = "enum", choices = Popup.IconChoices() })
    end)

    registry:RegisterNodeType("action.popup", {
        category = "action",
        displayName = "Popup",
        pins = {
            { name = "in", kind = "exec", direction = "in" },
            -- The one wire-able input. The rest are node-config (Control-only, per the header).
            { name = "body", kind = "data", direction = "in", dataType = "string", default = "" },
            { name = "title", kind = "data", direction = "in", dataType = "string", default = "Notification" },
            { name = "icon", kind = "data", direction = "in", dataType = "popup.icon", default = nil },
            { name = "theme", kind = "data", direction = "in", dataType = "popup.theme",
              default = Popup.DEFAULT_THEME },
            { name = "hold", kind = "data", direction = "in", dataType = "number",
              default = Popup.DEFAULT_HOLD_SECONDS },
        },
        run = function(ctx)
            local handle = Popup.BuildHandle({
                title = ctx:In("title"),
                body = ctx:In("body"),
                icon = ctx:In("icon"),
                theme = ctx:In("theme"),
                hold = ctx:In("hold"),
            })
            -- Queue-only: one banner on screen at a time; the rest wait (AC). A nil effects
            -- registry (misconfigured runtime) is a silent no-op rather than a crash.
            if runtime ~= nil and runtime.effects ~= nil then
                runtime.effects:PushQueue(Popup.OWNER, handle)
            end
        end,
    })
end

return Popup
