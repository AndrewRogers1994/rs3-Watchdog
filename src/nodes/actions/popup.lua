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

local function leaguesTheme(name, label, prefix, frame, layout)
    return Popup.RegisterTheme(name, {
        kind = "images",
        label = label,
        frame = frame or LEAGUES_FRAME,
        layout = layout,
        ribbon = { prefix .. "_0", prefix .. "_1", prefix .. "_2" },
        title = LEAGUES_TITLE,
        body = LEAGUES_BODY,
    })
end

--- Curated notification-icon dropdown ----------------------------------------------------
-- nil = no icon. Values are cache sprite ids from the client `id` global.
Popup.ICONS = {
    { value = nil, label = "None" },
    { value = id.Sprite.RS3_ICON_CHECK_MARK_24PX_0, label = "Checkmark" },
    { value = id.Sprite.ICON_STAR_FILL, label = "Star" },
    { value = id.Sprite.COINS, label = "Coins" },
    { value = id.Sprite.EXCLAMATION_MARK, label = "Exclamation" },
    { value = id.Sprite.RS3_ICON_BOSS_COLLECTION_LOG_0, label = "Collection Log" },
    { value = id.Sprite.ICON_RIBBON_QUESTS_INACTIVE, label = "Quest" },
    { value = id.Sprite.RS3_ICON_LEAGUES_TASK_LEVEL_1_ACTIVE, label = "Easy Task" },
    { value = id.Sprite.RS3_ICON_LEAGUES_TASK_LEVEL_2_ACTIVE, label = "Medium Task" },
    { value = id.Sprite.RS3_ICON_LEAGUES_TASK_LEVEL_3_ACTIVE, label = "Hard Task" },
    { value = id.Sprite.RS3_ICON_LEAGUES_TASK_LEVEL_4_ACTIVE, label = "Elite Task" },
    { value = id.Sprite.RS3_ICON_LEAGUES_TASK_LEVEL_5_ACTIVE, label = "Master Task" },
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

local RIBBON_OVERHANG = 32
local RIBBON_CAP_W = PNG_RIBBON_W
local RIBBON_MID_W = PNG_RIBBON_W
local RIBBON_W = RIBBON_CAP_W + RIBBON_MID_W + RIBBON_CAP_W
-- The panel sits inside the ribbon. Each side loses one overhang.
local PANEL_W = RIBBON_W - RIBBON_OVERHANG * 2
local HEADER_H = PNG_HEADER_H
local HEADER_W = PNG_HEADER_W
local FOOTER_W = PNG_FOOTER_W
local FOOTER_H = PNG_FOOTER_H
local SIDE_W = math.max(1, PNG_SIDE_W)
local SIDE_H = PNG_SIDE_H
local RIBBON_H = PNG_RIBBON_H
local RIBBON_BAND_H = math.max(1, math.floor(RIBBON_H * PNG_RIBBON_BAND / PNG_RIBBON_H + 0.5))
local BAND_OVERLAP = math.max(2, math.floor(RIBBON_BAND_H * 0.25 + 0.5))

local ICON_SIZE = 48
local BODY_LINE = 18
local CONTENT_PAD = 8

-- Shared draw path. panelH nil means the panel grows with the text stack.
local LEAGUES1_LAYOUT = {
    panelW = PANEL_W,
    headerW = HEADER_W,
    headerH = HEADER_H,
    footerW = FOOTER_W,
    footerH = FOOTER_H,
    footerNudge = 8,
    ribbonH = RIBBON_H,
    ribbonBand = RIBBON_BAND_H,
    ribbonCapW = RIBBON_CAP_W,
    ribbonMidW = RIBBON_MID_W,
    ribbonDrop = HEADER_H,
    panelDrop = HEADER_H + RIBBON_BAND_H - BAND_OVERLAP,
    contentInset = SIDE_W + CONTENT_PAD,
    contentTopPanel = HEADER_H,
    contentBottomTrim = FOOTER_H,
    sideW = SIDE_W,
    sideH = SIDE_H,
    sideDrop = 16,
    sideMarginTop = PNG_SIDE_TOP,
    sideMarginBottom = PNG_SIDE_BOTTOM,
}

-- Header and footer stay at PNG size. The three ribbon pieces share the Leagues 1
-- ribbon width and keep the PNG aspect, so none of them is stretched.
local PNG2_HEADER_W, PNG2_HEADER_H = 304, 120
local PNG2_FOOTER_W, PNG2_FOOTER_H = 80, 80
local PNG2_RIBBON_W, PNG2_RIBBON_H = 266, 150
local PNG2_RIBBON_BAND = 78
local LEAGUES2_CAP_W = RIBBON_W / 3
local LEAGUES2_MID_W = RIBBON_W / 3
local LEAGUES2_RIBBON_H = LEAGUES2_CAP_W * PNG2_RIBBON_H / PNG2_RIBBON_W
local LEAGUES2_BAND_H = LEAGUES2_RIBBON_H * PNG2_RIBBON_BAND / PNG2_RIBBON_H
local LEAGUES2_FRAME = {
    header = "leagues2_popup_header",
    footer = "leagues2_popup_footer",
}
local scaleFactor = 192 / 304
local LEAGUES2_LAYOUT = {
    panelW = RIBBON_W - RIBBON_OVERHANG * 2,
    panelH = 120,
    headerW = 192,
    headerH = PNG2_HEADER_H * scaleFactor,
    footerW = PNG2_FOOTER_W * scaleFactor,
    footerH = PNG2_FOOTER_H * scaleFactor,
    footerNudge = PNG2_FOOTER_H * scaleFactor * 0.25,
    ribbonH = LEAGUES2_RIBBON_H,
    ribbonBand = LEAGUES2_BAND_H,
    ribbonCapW = LEAGUES2_CAP_W,
    ribbonMidW = LEAGUES2_MID_W,
    ribbonDrop = 40,
    panelDrop = 75,
    contentInset = CONTENT_PAD,
    contentTopPanel = -40,
    contentBottomTrim = 0,
    headerRelic = { x = 120, y = 8, size = 64 },
    footerRelic = { x = 5, y = 4, size = 72 },
    border = {
        background = "RS3_PARENT_CONTENT_TILE",
        side = "RS3_CHILD_FRAME_SIDE",
        bottom = "RS3_CHILD_FRAME_BOTTOM_TILE",
        corner = "RS3_CHILD_FRAME_BOTTOM_CORNER",
        thickness = 4,
        cornerSize = 22,
    },
}

leaguesTheme("leagues_gold", "Leagues Gold", "ribbon_leagues_gold", LEAGUES_FRAME, LEAGUES1_LAYOUT)
leaguesTheme("leagues_red", "Leagues Red", "ribbon_leagues_red", LEAGUES_FRAME, LEAGUES1_LAYOUT)
leaguesTheme("leagues_red_gold", "Leagues Red/Gold", "ribbon_leagues_red_gold", LEAGUES_FRAME, LEAGUES1_LAYOUT)
leaguesTheme("leagues2_gold", "Leagues 2 Gold", "ribbon_leagues2_gold", LEAGUES2_FRAME, LEAGUES2_LAYOUT)
leaguesTheme("leagues2_green", "Leagues 2 Green", "ribbon_leagues2_green", LEAGUES2_FRAME, LEAGUES2_LAYOUT)
leaguesTheme("leagues2_green_gold", "Leagues 2 Green/Gold", "ribbon_leagues2_green_gold", LEAGUES2_FRAME, LEAGUES2_LAYOUT)

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
        headerRelic = sprite(),
        footerRelic = sprite(),
        ribbonLeft = sprite(),
        ribbonMid = sprite(),
        ribbonRight = sprite(),
        icon = sprite(),
        fill = sprite(),
        borderLeft = sprite(),
        borderRight = sprite(),
        borderBottom = sprite(),
        cornerLeft = sprite(),
        cornerRight = sprite(),
        title = text(),
        body = text(),
    }
    return chrome
end

local function setMargins(sprite, left, top, right, bottom)
    if ui == nil or ui.Margin == nil then return end
    -- Offsets are source pixels. The centre is what grows when the sprite is larger.
    sprite.visualMargins = ui.Margin.new(left, top, right, bottom)
end

local function hideSprite(sprite)
    sprite.hidden = true
end

local function cacheSprite(name)
    if name == nil or id == nil or id.Sprite == nil then return nil end
    return id.Sprite[name]
end

local function placeCacheSprite(sprite, x, y, w, h, spriteID, alpha, tiling, flipX)
    sprite.hidden = false
    sprite:SetPos(px(x), px(y))
    sprite:SetSize(math.max(1, px(w)), math.max(1, px(h)))
    sprite.alpha = alpha
    sprite.isTiling = tiling == true
    sprite.isFlippedHorizontally = flipX == true
    if spriteID ~= nil then
        sprite.spriteID = spriteID
    end
end

local BORDER_KEYS = { "fill", "borderLeft", "borderRight", "borderBottom", "cornerLeft", "cornerRight" }

local function hideBorder(frame)
    for _, key in ipairs(BORDER_KEYS) do
        hideSprite(frame[key])
    end
end

-- Fill, then the bottom and side tiles, then the corners so they cover the tile ends.
local function drawBorder(frame, border, x, y, w, h, alpha)
    local thickness = border.thickness
    local corner = border.cornerSize
    placeCacheSprite(frame.fill, x, y, w, h, cacheSprite(border.background), alpha, true, false)
    placeCacheSprite(frame.borderBottom, x, y + h - thickness, w, thickness,
        cacheSprite(border.bottom), alpha, true, false)
    placeCacheSprite(frame.borderLeft, x, y, thickness, h, cacheSprite(border.side), alpha, true, false)
    placeCacheSprite(frame.borderRight, x + w - thickness, y, thickness, h,
        cacheSprite(border.side), alpha, true, false)
    placeCacheSprite(frame.cornerLeft, x, y + h - corner, corner, corner,
        cacheSprite(border.corner), alpha, false, false)
    placeCacheSprite(frame.cornerRight, x + w - corner, y + h - corner, corner, corner,
        cacheSprite(border.corner), alpha, false, true)
    -- Created after the header and ribbon, so they paint above them until sent back.
    -- Last call lands furthest back: fill, then edge tiles, then corners.
    local function sink(sprite)
        if sprite.MoveToBack ~= nil then
            sprite:MoveToBack()
        end
    end
    sink(frame.cornerRight)
    sink(frame.cornerLeft)
    sink(frame.borderRight)
    sink(frame.borderLeft)
    sink(frame.borderBottom)
    sink(frame.fill)
end

-- well is a square in the PNG's pixels. It scales with the piece so the icon stays in the circle.
local LEAGUES2_RELIC_SPRITE = "RS3_ICON_LEAGUES_2_UNLOCK_RELIC"

local function placeRelic(sprite, pieceX, pieceY, pieceW, pieceH, pngW, pngH, well, alpha)
    if well == nil then
        hideSprite(sprite)
        return
    end
    local sx = pieceW / pngW
    local sy = pieceH / pngH
    placeCacheSprite(sprite,
        pieceX + well.x * sx, pieceY + well.y * sy,
        well.size * sx, well.size * sy,
        cacheSprite(LEAGUES2_RELIC_SPRITE), alpha, false, false)
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
    local layout = theme.layout or LEAGUES1_LAYOUT

    local hasIcon = opts.icon ~= nil
    local hasBody = opts.body ~= nil and opts.body ~= ""
    local stack = CONTENT_PAD
    if hasIcon then stack = stack + ICON_SIZE end
    if hasBody then
        if hasIcon then stack = stack + 8 end
        stack = stack + BODY_LINE
    end
    stack = stack + CONTENT_PAD

    local panelW = layout.panelW
    local panelX = (sw - panelW) * 0.5
    local headerW = layout.headerW
    local headerH = layout.headerH
    local headerY = TOP_MARGIN
    local headerX = panelX + (panelW - headerW) * 0.5
    local ribbonH = layout.ribbonH
    local bandH = layout.ribbonBand
    local capW = layout.ribbonCapW
    local midW = layout.ribbonMidW
    local ribbonW = capW * 2 + midW
    local ribbonX = panelX + (panelW - ribbonW) * 0.5
    local ribbonY = headerY + layout.ribbonDrop
    local panelY = headerY + layout.panelDrop
    local footerW = layout.footerW
    local footerH = layout.footerH
    local panelH = layout.panelH or (ribbonH * 0.5 + stack + footerH)
    local footerX = panelX + (panelW - footerW) * 0.5
    local footerY = panelY + panelH - footerH + layout.footerNudge
    local inset = layout.contentInset
    local contentX = panelX + inset
    local contentW = panelW - inset * 2
    local contentTop = panelY + layout.contentTopPanel + CONTENT_PAD
    local contentBottom = panelY + panelH - layout.contentBottomTrim - CONTENT_PAD

    local images = theme.frame or LEAGUES_FRAME
    local ribbon = theme.ribbon or {}

    frame.layer.hidden = false
    frame.layer.alpha = 1
    if frame.layer.MoveToFront ~= nil then
        frame.layer:MoveToFront()
    end

    if images.background ~= nil then
        placeSprite(frame.background, panelX, panelY, panelW, panelH,
            pluginImage(images.background), alpha)
        frame.background.isTiling = true
    else
        hideSprite(frame.background)
    end

    if layout.border ~= nil then
        drawBorder(frame, layout.border, panelX, panelY, panelW, panelH, alpha)
    else
        hideBorder(frame)
    end

    if images.side ~= nil then
        local sideW = layout.sideW
        local sideY = panelY + layout.sideDrop
        placeSprite(frame.sideLeft, panelX - sideW, sideY, sideW, layout.sideH,
            pluginImage(images.side), alpha)
        frame.sideLeft.isFlippedHorizontally = false
        frame.sideLeft.isTiling = false
        setMargins(frame.sideLeft, 0, layout.sideMarginTop, 0, layout.sideMarginBottom)

        placeSprite(frame.sideRight, panelX + panelW, sideY, sideW, layout.sideH,
            pluginImage(images.side), alpha)
        frame.sideRight.isFlippedHorizontally = true
        frame.sideRight.isTiling = false
        setMargins(frame.sideRight, 0, layout.sideMarginTop, 0, layout.sideMarginBottom)
    else
        hideSprite(frame.sideLeft)
        hideSprite(frame.sideRight)
    end

    placeSprite(frame.header, headerX, headerY, headerW, headerH,
        pluginImage(images.header), alpha)
    frame.header.isTiling = false
    setMargins(frame.header, 0, 0, 0, 0)

    placeSprite(frame.footer, footerX, footerY, footerW, footerH,
        pluginImage(images.footer), alpha)
    frame.footer.isTiling = false

    placeRelic(frame.headerRelic, headerX, headerY, headerW, headerH,
        PNG2_HEADER_W, PNG2_HEADER_H, layout.headerRelic, alpha)
    placeRelic(frame.footerRelic, footerX, footerY, footerW, footerH,
        PNG2_FOOTER_W, PNG2_FOOTER_H, layout.footerRelic, alpha)

    placeSprite(frame.ribbonLeft, ribbonX, ribbonY, capW, ribbonH,
        pluginImage(ribbon[1]), alpha)
    frame.ribbonLeft.isTiling = false
    placeSprite(frame.ribbonMid, ribbonX + capW, ribbonY, midW, ribbonH,
        pluginImage(ribbon[2]), alpha)
    frame.ribbonMid.isTiling = false
    placeSprite(frame.ribbonRight, ribbonX + ribbonW - capW, ribbonY, capW, ribbonH,
        pluginImage(ribbon[3]), alpha)
    frame.ribbonRight.isTiling = false

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
        ribbonX + capW, ribbonY, midW, bandH)
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
            -- The popup queue is shared by every alert. Stamp the node state so disabling
            -- or deleting this alert can dismiss its banners and leave the others queued.
            handle.source = ctx.state
            -- Queue-only: one banner on screen at a time (AC).
            if runtime ~= nil and runtime.effects ~= nil then
                runtime.effects:PushQueue(Popup.OWNER, handle)
            end
        end,
    })
end

return Popup
