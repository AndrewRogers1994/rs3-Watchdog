local Popup = {}

Popup.IN_SECONDS = 0.3
Popup.OUT_SECONDS = 0.4
Popup.DEFAULT_HOLD_SECONDS = 4.0

Popup.OWNER = "action.popup"

local function normalizeHold(hold)
    hold = tonumber(hold) or Popup.DEFAULT_HOLD_SECONDS
    if hold < 0 then hold = 0 end
    return hold
end

-- Split from the handle so animation is unit-testable without Canvas.
function Popup.Anim(elapsed, hold)
    hold = normalizeHold(hold)
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
-- RegisterTheme is the AC registry seam. themeOrder keeps declaration order so Parchment stays first.

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

-- Unknown/nil names fall back to Parchment so a stale theme control still draws.
function Popup.ThemeFor(name)
    return themes[name] or themes[Popup.DEFAULT_THEME]
end

function Popup.ThemeChoices()
    local choices = {}
    for _, name in ipairs(themeOrder) do
        choices[#choices + 1] = { value = name, label = themes[name].label or name }
    end
    return choices
end

-- Sprite-free default (no sprite-id assumptions).
Popup.RegisterTheme("parchment", {
    kind = "primitive",
    label = "Parchment",
    bg     = { 0.90, 0.83, 0.63, 0.97 },
    border = { 0.36, 0.26, 0.12, 1.0 },
    title  = { 0.24, 0.16, 0.06, 1.0 },
    body   = { 0.16, 0.11, 0.05, 1.0 },
})

-- 3-part frame sidesteps AddSprite stretch distortion (#20). Native end-cap width is BUILD-VERIFY.
Popup.RegisterTheme("leagues", {
    kind = "sprites",
    label = "Leagues",
    sprites = {
        left  = 35186, -- id.Sprite.RS3_RIBBON_LEAGUES_GOLD_0
        mid   = 35187, -- id.Sprite.RS3_RIBBON_LEAGUES_GOLD_1  (stretch this)
        right = 35188, -- id.Sprite.RS3_RIBBON_LEAGUES_GOLD_2
    },
    edgeW = 24, -- BUILD-VERIFY: measured end-cap width in px.
    title = { 1.0, 0.92, 0.60, 1.0 },
    body  = { 1.0, 1.0, 1.0, 1.0 },
})

--- Curated notification-icon dropdown ----------------------------------------------------
-- Subset of #20 research icon ids (high-confidence). nil = no icon.
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
-- Guard client globals here so a missing global / bad sprite id draws nothing this frame.

local BANNER_W = 420
local BANNER_H = 74
local TOP_MARGIN = 24

local function vec4(c, alpha)
    return Vector4.new(c[1], c[2], c[3], (c[4] or 1) * alpha)
end

-- Overlay Canvas often has no pixel width; fall back to 1920.
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

    -- AddSprite colour is Uint RGBA, not Vector4 (docs/research/popup-frame-sprites.md).
    local Color = require("ui/color")
    local white = Color.ToRGBA(1, 1, 1, alpha)
    if theme.kind == "sprites" and canvas.AddSprite ~= nil and id ~= nil then
        local s = theme.sprites
        local edge = theme.edgeW or 24
        canvas:AddSprite(x, y, edge, BANNER_H, s.left, white)
        canvas:AddSprite(x + edge, y, BANNER_W - edge * 2, BANNER_H, s.mid, white)
        canvas:AddSprite(x + BANNER_W - edge, y, edge, BANNER_H, s.right, white)
    else
        canvas:AddRectangle(x, y, BANNER_W, BANNER_H, vec4(theme.bg or { 0.1, 0.1, 0.12, 0.95 }, alpha))
        if canvas.AddOutline ~= nil then
            canvas:AddOutline(x, y, BANNER_W, BANNER_H, 2, vec4(theme.border or { 0, 0, 0, 1 }, alpha))
        end
    end

    local textX = x + 16
    if opts.icon ~= nil and canvas.AddSprite ~= nil then
        local iconSize = 40
        pcall(function()
            canvas:AddSprite(x + 12, y + (BANNER_H - iconSize) * 0.5, iconSize, iconSize,
                opts.icon, white)
        end)
        textX = x + 12 + iconSize + 12
    end

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
function Popup.BuildHandle(spec)
    spec = spec or {}
    local hold = normalizeHold(spec.hold)
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

---@param registry LibNodeGraph.Registry
---@param runtime Watchdog.Runtime
function Popup.Register(registry, runtime)
    -- pcall so a headless/test require still registers the node without the ui layer.
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
            { name = "body", kind = "data", direction = "in", dataType = "string", default = "" },
            { name = "title", kind = "data", direction = "in", dataType = "string", default = "Notification" },
            { name = "icon", kind = "data", direction = "in", dataType = "popup.icon", default = nil },
            { name = "theme", kind = "data", direction = "in", dataType = "popup.theme",
              default = Popup.DEFAULT_THEME },
            { name = "hold", label = "Hold (seconds)", kind = "data", direction = "in", dataType = "number",
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
            -- Queue-only: one banner on screen at a time (AC).
            if runtime ~= nil and runtime.effects ~= nil then
                runtime.effects:PushQueue(Popup.OWNER, handle)
            end
        end,
    })
end

return Popup
