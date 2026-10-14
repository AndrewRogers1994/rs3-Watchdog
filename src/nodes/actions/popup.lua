local Color = require("src/ui/color")
local Theme = require("src/ui/theme")

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

-- local LEAGUES_TITLE = { 1.0, 0.92, 0.60, 1.0 }
-- local LEAGUES_TITLE = { 209/255, 169/255, 69/255, 1.0 }
local LEAGUES_TITLE = { 222/255, 176/255, 91/255, 1.0 }
local LEAGUES_BODY = { 0.8, 0.8, 0.8, 1.0 }
local LEAGUES_FRAME = {
    background = "leagues_default_background",
    header = "popup_leagues_trim_header",
    footer = "popup_leagues_trim_footer",
    side = "popup_leagues_trim_side",
}

local function leaguesTheme(name, label, prefix)
    return Popup.RegisterTheme(name, {
        kind = "images",
        label = label,
        frame = LEAGUES_FRAME,
        ribbon = { prefix .. "_0", prefix .. "_1", prefix .. "_2" },
        title = LEAGUES_TITLE,
        body = LEAGUES_BODY,
    })
end

leaguesTheme("leagues_gold", "Leagues Gold", "ribbon_leagues_gold")
leaguesTheme("leagues_red", "Leagues Red", "ribbon_leagues_red")
leaguesTheme("leagues_red_gold", "Leagues Red/Gold", "ribbon_leagues_red_gold")

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

local PNG_HEADER_W, PNG_HEADER_H = 173, 33
local PNG_FOOTER_W, PNG_FOOTER_H = 141, 34
local PNG_SIDE_W, PNG_SIDE_H = 24, 54
local PNG_RIBBON_W, PNG_RIBBON_H = 133, 75
local PNG_RIBBON_BAND = 36
local PNG_SIDE_TOP, PNG_SIDE_BOTTOM = 28, 10

local PANEL_W = 252
local HEADER_H = PNG_HEADER_H
local HEADER_W = PNG_HEADER_W
local FOOTER_W = PNG_FOOTER_W
local FOOTER_H = PNG_FOOTER_H
local SIDE_W = math.max(1, PNG_SIDE_W)
local SIDE_H = PNG_SIDE_H

local RIBBON_OVERHANG = 32
local RIBBON_MID_W = 120
local RIBBON_W = PANEL_W + RIBBON_OVERHANG * 2
local RIBBON_CAP_W = math.floor((RIBBON_W - RIBBON_MID_W) / 2)
local RIBBON_H = PNG_RIBBON_H
local RIBBON_BAND_H = math.max(1, math.floor(RIBBON_H * PNG_RIBBON_BAND / PNG_RIBBON_H + 0.5))
local BAND_OVERLAP = math.max(2, math.floor(RIBBON_BAND_H * 0.25 + 0.5))

local ICON_SIZE = 32
local BODY_LINE = 18
local CONTENT_PAD = 8

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

local function px(n)
    return math.floor(n + 0.5)
end

-- Plugin.resources.images keys are the filename with or without the extension,
-- depending on the client build. Try both, and Load() once so the first frame is ready.
local imageCache = {}

local function pluginImage(name)
    if name == nil then return nil end
    local cached = imageCache[name]
    if cached ~= nil then return cached end
    local images = Plugin ~= nil and Plugin.resources ~= nil and Plugin.resources.images or nil
    if images == nil then return nil end
    local resource = images[name] or images[name .. ".png"]
    if resource == nil then return nil end
    if resource.Load ~= nil and resource.loaded ~= true then
        local ok, err = pcall(function() resource:Load() end)
        if not ok and log ~= nil then
            log("Watchdog popup: image load failed for " .. name .. " - " .. tostring(err))
        end
    end
    imageCache[name] = resource
    return resource
end

-- Canvas:AddSprite only accepts a cache sprite id. Bundled PNGs are PluginResource
-- objects assigned to ui.Sprite.sprite (same path prettymap uses for map tiles).
-- The layer is a sibling of the effect canvas: Clear() wipes canvas drawables, not children.
local chrome

local function hideChrome()
    if chrome ~= nil and chrome.layer ~= nil then
        chrome.layer.hidden = true
    end
end

local function ensureChrome(parent)
    if parent == nil or ui == nil or ui.Layer == nil or ui.Sprite == nil or ui.Text == nil then
        return nil
    end
    if chrome ~= nil and chrome.parent == parent then
        return chrome
    end
    if chrome ~= nil and chrome.layer ~= nil and chrome.layer.Destroy ~= nil then
        local ok, err = pcall(function() chrome.layer:Destroy() end)
        if not ok and log ~= nil then
            log("Watchdog popup: chrome destroy failed - " .. tostring(err))
        end
    end

    local layer = ui.Layer.new(parent)
    layer.clickthrough = true
    layer.hidden = true
    layer:SetPos(0, 0)
    layer:SetSize(0, 0, 1.0, 1.0)

    local function sprite()
        local s = ui.Sprite.new(layer)
        s.clickthrough = true
        return s
    end

    local function text()
        local t = ui.Text.new(layer)
        t.clickthrough = true
        t.isShadowed = true
        if ui.AlignMode ~= nil then
            t:AlignTo(ui.AlignMode.CENTRE)
        end
        return t
    end

    chrome = {
        parent = parent,
        layer = layer,
        background = sprite(),
        sideLeft = sprite(),
        sideRight = sprite(),
        header = sprite(),
        footer = sprite(),
        ribbonLeft = sprite(),
        ribbonMid = sprite(),
        ribbonRight = sprite(),
        icon = sprite(),
        title = text(),
        body = text(),
    }
    return chrome
end

local function protectSideEnds(sprite)
    if ui == nil or ui.Margin == nil then return end
    -- Offsets are source pixels. The centre stem is what grows with the panel.
    sprite.visualMargins = ui.Margin.new(0, PNG_SIDE_TOP, 0, PNG_SIDE_BOTTOM)
end

local function placeSprite(sprite, x, y, w, h, resource, alpha)
    sprite.hidden = false
    sprite:SetPos(px(x), px(y))
    sprite:SetSize(math.max(1, px(w)), math.max(1, px(h)))
    -- Each piece carries the fade. Parent alpha is not documented to multiply into children,
    -- and setting both would square the ramp. The layer stays at 1.
    sprite.alpha = alpha
    if resource ~= nil then
        sprite.sprite = resource
    end
end

local function placeText(text, content, font, colour, alpha, x, y, w, h)
    local show = content ~= nil and content ~= "" and font ~= nil
    text.hidden = not show
    if not show then return end
    text:SetPos(px(x), px(y))
    text:SetSize(math.max(1, px(w)), math.max(1, px(h)))
    text.content = tostring(content)
    text.font = font
    text.alpha = alpha
    text.colour = vec4(colour, 1)
    text.rgba = Color.ToRGBA(colour[1], colour[2], colour[3], alpha)
    -- text.shadowRGBA = Color.ToRGBA(0, 0, 0, 0.85 * alpha)
end

local function drawParchment(canvas, opts, theme, alpha, x, y)
    canvas:AddRectangle(x, y, BANNER_W, BANNER_H, vec4(theme.bg or { 0.1, 0.1, 0.12, 0.95 }, alpha))
    if canvas.AddOutline ~= nil then
        canvas:AddOutline(x, y, BANNER_W, BANNER_H, 2, vec4(theme.border or { 0, 0, 0, 1 }, alpha))
    end

    -- AddSprite colour is Uint RGBA, not Vector4 (docs/research/popup-frame-sprites.md).
    local white = Color.ToRGBA(1, 1, 1, alpha)
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

local function drawLeagues(canvas, opts, theme, alpha)
    local parent = canvas.parent
    local frame = ensureChrome(parent)
    if frame == nil then
        return
    end

    local sw = screenWidth(canvas)
    local panelX = (sw - PANEL_W) * 0.5
    local ribbonW = PANEL_W + RIBBON_OVERHANG * 2
    local ribbonX = panelX - RIBBON_OVERHANG
    local headerY = TOP_MARGIN
    local ribbonY = headerY + HEADER_H
    local panelY = ribbonY + RIBBON_BAND_H - BAND_OVERLAP

    local hasIcon = opts.icon ~= nil
    local hasBody = opts.body ~= nil and opts.body ~= ""
    local stack = CONTENT_PAD
    if hasIcon then stack = stack + ICON_SIZE end
    if hasBody then
        if hasIcon then stack = stack + 8 end
        stack = stack + BODY_LINE
    end
    stack = stack + CONTENT_PAD
    local panelH = RIBBON_H * 0.5 + stack + FOOTER_H

    local images = theme.frame or LEAGUES_FRAME
    local ribbon = theme.ribbon or {}

    frame.layer.hidden = false
    frame.layer.alpha = 1
    if frame.layer.MoveToFront ~= nil then
        frame.layer:MoveToFront()
    end

    placeSprite(frame.background, panelX, panelY, PANEL_W, panelH,
        pluginImage(images.background), alpha)
    frame.background.isTiling = true

    placeSprite(frame.sideLeft, panelX - SIDE_W, panelY + 16, SIDE_W, SIDE_H,
        pluginImage(images.side), alpha)
    frame.sideLeft.isFlippedHorizontally = false
    frame.sideLeft.isTiling = false
    protectSideEnds(frame.sideLeft)

    placeSprite(frame.sideRight, panelX + PANEL_W, panelY + 16, SIDE_W, SIDE_H,
        pluginImage(images.side), alpha)
    frame.sideRight.isFlippedHorizontally = true
    frame.sideRight.isTiling = false
    protectSideEnds(frame.sideRight)

    placeSprite(frame.header, panelX + (PANEL_W - HEADER_W) * 0.5, headerY, HEADER_W, HEADER_H,
        pluginImage(images.header), alpha)
    frame.header.isTiling = false

    placeSprite(frame.footer, panelX + (PANEL_W - FOOTER_W) * 0.5, panelY + panelH - FOOTER_H + 8,
        FOOTER_W, FOOTER_H, pluginImage(images.footer), alpha)
    frame.footer.isTiling = false

    local midW = ribbonW - RIBBON_CAP_W * 2
    placeSprite(frame.ribbonLeft, ribbonX, ribbonY, RIBBON_CAP_W, RIBBON_H,
        pluginImage(ribbon[1]), alpha)
    frame.ribbonLeft.isTiling = false
    placeSprite(frame.ribbonMid, ribbonX + RIBBON_CAP_W, ribbonY, midW, RIBBON_H,
        pluginImage(ribbon[2]), alpha)
    frame.ribbonMid.isTiling = true
    placeSprite(frame.ribbonRight, ribbonX + ribbonW - RIBBON_CAP_W, ribbonY, RIBBON_CAP_W, RIBBON_H,
        pluginImage(ribbon[3]), alpha)
    frame.ribbonRight.isTiling = false

    local contentX = panelX + SIDE_W + CONTENT_PAD
    local contentW = PANEL_W - (SIDE_W + CONTENT_PAD) * 2
    local contentTop = panelY + HEADER_H + CONTENT_PAD
    local contentBottom = panelY + panelH - FOOTER_H - CONTENT_PAD
    local contentH = math.max(1, contentBottom - contentTop)
    local stackH = 0
    if hasIcon then stackH = stackH + ICON_SIZE end
    if hasBody then
        if hasIcon then stackH = stackH + 8 end
        stackH = stackH + BODY_LINE
    end
    local cursor = contentTop + math.max(0, (contentH - stackH) * 0.5)

    frame.icon.hidden = not hasIcon
    if hasIcon then
        placeSprite(frame.icon, contentX + (contentW - ICON_SIZE) * 0.5, cursor, ICON_SIZE, ICON_SIZE,
            nil, alpha)
        frame.icon.spriteID = opts.icon
        frame.icon.isTiling = false
        cursor = cursor + ICON_SIZE + 8
    end

    local titleColour = theme.title or LEAGUES_TITLE
    local bodyColour = theme.body or LEAGUES_BODY
    placeText(frame.title, opts.title, Theme.Font(14, true), titleColour, alpha,
        ribbonX + RIBBON_CAP_W, ribbonY, midW, RIBBON_BAND_H)
    if hasBody then
        placeText(frame.body, opts.body, Theme.Font(14), bodyColour, alpha,
            contentX, cursor, contentW, BODY_LINE)
    else
        frame.body.hidden = true
    end
end

function Popup.Draw(canvas, opts)
    if canvas == nil or Vector4 == nil then
        return
    end
    opts = opts or {}
    local anim = opts.anim or { alpha = 1 }
    local alpha = anim.alpha or 1
    local theme = opts.theme or Popup.ThemeFor(Popup.DEFAULT_THEME)

    if alpha <= 0 or theme.kind ~= "images" then
        hideChrome()
    end
    if alpha <= 0 then
        return
    end

    local sw = screenWidth(canvas)
    local x = (sw - BANNER_W) * 0.5
    local y = TOP_MARGIN
    if theme.kind == "images" then
        drawLeagues(canvas, opts, theme, alpha)
    else
        drawParchment(canvas, opts, theme, alpha, x, y)
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
        -- Update removes the handle before the next Draw, so the layer would stay up
        -- without this. onDone runs in that same Update, before Draw of whatever is next.
        onDone = hideChrome,
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
        local Controls = require("src/ui/controls")
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
