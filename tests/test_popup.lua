-- Exercises the Popup action node (nodes/actions/popup.lua, #38) through its pure seams:
-- the in->hold->out auto-expiry animation, the theme registry (Parchment default + the three
-- Leagues image themes, plus the RegisterTheme extension seam), the curated icon dropdown,
-- and the node's `run` pushing a Queue-only effect handle onto a real EffectRegistry.
--
-- The Canvas draw is a client primitive (ui.Canvas / id.Sprite) and is intentionally not
-- asserted here - the handle's draw is only exercised for not-erroring against a fake canvas,
-- never against real pixels, matching test_effects' convention. No LibNodeGraph is required:
-- the node's `run` is driven through a fake registry + fake ctx + a real EffectRegistry, so
-- this file runs standalone even where the engine isn't deployed.

local luaunit = require("luaunit")
local Popup = require("src/nodes/actions/popup")
local EffectRegistry = require("src/effects")

-- Popup.Draw early-returns unless Vector4 exists (its primitive-frame path uses it); stub it
-- so the draw path is actually exercised. AddSprite's own colour arg is a Uint, not a Vector4.
_G.Vector4 = _G.Vector4 or { new = function(r, g, b, a) return { r, g, b, a } end }

TestPopup = {}

--- Animation: in -> hold -> out, auto-expiring -------------------------------------------

function TestPopup:testAnimStartsInFadingUpFromZero()
    local a = Popup.Anim(0, 4)
    luaunit.assertEquals(a.phase, "in")
    luaunit.assertEquals(a.alpha, 0)
end

function TestPopup:testAnimHoldIsFullyOpaque()
    local a = Popup.Anim(Popup.IN_SECONDS + 1.0, 4)
    luaunit.assertEquals(a.phase, "hold")
    luaunit.assertEquals(a.alpha, 1)
end

function TestPopup:testAnimOutFadesTowardZero()
    local mid = Popup.IN_SECONDS + 4 + (Popup.OUT_SECONDS * 0.5)
    local a = Popup.Anim(mid, 4)
    luaunit.assertEquals(a.phase, "out")
    luaunit.assertTrue(a.alpha > 0 and a.alpha < 1)
end

function TestPopup:testAnimPastTotalIsDone()
    local total = Popup.IN_SECONDS + 4 + Popup.OUT_SECONDS
    local a = Popup.Anim(total + 0.01, 4)
    luaunit.assertEquals(a.phase, "done")
    luaunit.assertEquals(a.alpha, 0)
end

function TestPopup:testAnimClampsNegativeHoldToZero()
    -- A zero/negative hold still yields a valid (in -> out) timeline, never erroring.
    local a = Popup.Anim(Popup.IN_SECONDS + 0.001, -5)
    luaunit.assertEquals(a.phase, "out")
end

--- BuildHandle: uniform effect handle that expires on its own ----------------------------

function TestPopup:testBuildHandleIsAWellFormedEffectHandle()
    local h = Popup.BuildHandle({ body = "hi", hold = 1 })
    luaunit.assertEquals(h.kind, "popup")
    luaunit.assertEquals(type(h.update), "function")
    luaunit.assertEquals(type(h.draw), "function")
end

function TestPopup:testBuildHandleStaysAliveThenExpires()
    local hold = 1
    local h = Popup.BuildHandle({ body = "hi", hold = hold })
    local total = Popup.IN_SECONDS + hold + Popup.OUT_SECONDS
    luaunit.assertTrue(h.update(total - 0.01))
    luaunit.assertFalse(h.update(0.02))
end

-- A fake overlay Canvas recording draw calls, covering every method Popup.Draw may touch.
local function makeFakeCanvas()
    local calls = { rects = 0, outlines = 0, texts = 0, sprites = 0, spriteColours = {} }
    return {
        width = 1920,
        AddRectangle = function(_self) calls.rects = calls.rects + 1 end,
        AddOutline   = function(_self) calls.outlines = calls.outlines + 1 end,
        AddText      = function(_self) calls.texts = calls.texts + 1 end,
        AddSprite    = function(_self, _x, _y, _w, _h, _sprite, colour)
            calls.sprites = calls.sprites + 1
            calls.spriteColours[#calls.spriteColours + 1] = colour
        end,
    }, calls
end

function TestPopup:testDrawIsInvokedThroughRegistryWithoutPropagatingErrors()
    -- The real safety net is EffectRegistry:Draw wrapping each handle's draw (a bad frame
    -- can't kill sibling effects). Drive the popup handle through it with a recording canvas
    -- and assert nothing propagates - pixels themselves are never asserted (test_effects AC).
    local effects = EffectRegistry.new()
    local h = Popup.BuildHandle({ body = "hi", title = "Nice", hold = 4 })
    effects:PushQueue(Popup.OWNER, h)
    h.update(0.01)
    local canvas = makeFakeCanvas()
    local ok = pcall(function() effects:Draw(canvas) end)
    luaunit.assertTrue(ok)
end

function TestPopup:testAddSpriteColoursAreUintNotVector4()
    -- Regression (#47): ui.Canvas:AddSprite's colour arg is a Uint RGBA - there is no Vector4
    -- overload - so a Vector4 there renders nothing. The parchment icon is the remaining
    -- AddSprite path (Leagues frames are plugin images on ui.Sprite, not cache ids).
    local canvas, calls = makeFakeCanvas()
    Popup.Draw(canvas, {
        theme = Popup.ThemeFor("parchment"),
        icon = 4,
        title = "T", body = "b",
        anim = { alpha = 1 },
    })
    luaunit.assertEquals(calls.sprites, 1)
    for _, colour in ipairs(calls.spriteColours) do
        luaunit.assertEquals(type(colour), "number")
    end
end

--- Theme registry: Parchment default + Leagues + extension seam --------------------------

function TestPopup:testDefaultThemeIsParchment()
    luaunit.assertEquals(Popup.DEFAULT_THEME, "parchment")
    luaunit.assertNotNil(Popup.ThemeFor("parchment"))
end

function TestPopup:testLeaguesThemesAreRegisteredInOrder()
    local choices = Popup.ThemeChoices()
    luaunit.assertEquals(choices[1].value, "parchment")
    luaunit.assertEquals(choices[2].value, "leagues_gold")
    luaunit.assertEquals(choices[2].label, "Leagues Gold")
    luaunit.assertEquals(choices[3].value, "leagues_red")
    luaunit.assertEquals(choices[3].label, "Leagues Red")
    luaunit.assertEquals(choices[4].value, "leagues_red_gold")
    luaunit.assertEquals(choices[4].label, "Leagues Red/Gold")
end

-- ui.Sprite / ui.Text stand-ins. One shared image table so Popup's load cache and later
-- tests agree on the same resource objects.
local leaguesImages

local function installFakeUi()
    local created = { layers = {}, sprites = {}, texts = {} }
    local function component()
        local c = { hidden = false, alpha = 1 }
        function c:SetPos(x, y) self.x, self.y = x, y end
        function c:SetSize(w, h, pw, ph) self.w, self.h, self.pw, self.ph = w, h, pw, ph end
        function c:AlignTo(mode) self.align = mode end
        function c:MoveToFront() self.front = (self.front or 0) + 1 end
        function c:Destroy() self.destroyed = true end
        return c
    end
    local previousUi = _G.ui
    _G.ui = {
        AlignMode = { CENTRE = "CENTRE" },
        Layer = { new = function()
            local layer = component()
            created.layers[#created.layers + 1] = layer
            return layer
        end },
        Sprite = { new = function()
            local sprite = component()
            created.sprites[#created.sprites + 1] = sprite
            return sprite
        end },
        Text = { new = function()
            local text = component()
            created.texts[#created.texts + 1] = text
            return text
        end },
    }
    return created, previousUi
end

local function installImages()
    if leaguesImages == nil then
        leaguesImages = {}
        local names = {
            "leagues_default_background",
            "popup_leagues_trim_header",
            "popup_leagues_trim_footer",
            "popup_leagues_trim_side",
            "ribbon_leagues_gold_0", "ribbon_leagues_gold_1", "ribbon_leagues_gold_2",
            "ribbon_leagues_red_0", "ribbon_leagues_red_1", "ribbon_leagues_red_2",
            "ribbon_leagues_red_gold_0", "ribbon_leagues_red_gold_1", "ribbon_leagues_red_gold_2",
        }
        for _, name in ipairs(names) do
            leaguesImages[name] = {
                name = name,
                loaded = false,
                Load = function(self)
                    self.loaded = true
                    self.loads = (self.loads or 0) + 1
                    return "success"
                end,
            }
        end
    end
    local previousPlugin = _G.Plugin
    _G.Plugin = { resources = { images = leaguesImages } }
    return leaguesImages, previousPlugin
end

function TestPopup:testLeaguesImageThemesAssignRibbonFiles()
    local created, previousUi = installFakeUi()
    local images, previousPlugin = installImages()
    local canvas = makeFakeCanvas()
    canvas.parent = { id = "leagues-assign" }

    local function draw(themeName, alpha)
        Popup.Draw(canvas, {
            theme = Popup.ThemeFor(themeName),
            title = "Relic Activated!",
            body = "Excavator",
            icon = 17127,
            anim = { alpha = alpha or 1 },
        })
    end

    draw("leagues_gold", 0.5)
    local sprites = created.sprites
    luaunit.assertEquals(#sprites, 9)
    luaunit.assertEquals(sprites[1].sprite, images.leagues_default_background)
    luaunit.assertTrue(sprites[1].isTiling)
    luaunit.assertEquals(sprites[1].alpha, 0.5)
    luaunit.assertEquals(sprites[1].x, 834)
    luaunit.assertFalse(sprites[2].isFlippedHorizontally)
    luaunit.assertTrue(sprites[3].isFlippedHorizontally)
    luaunit.assertEquals(sprites[2].sprite, images.popup_leagues_trim_side)
    luaunit.assertEquals(sprites[3].sprite, images.popup_leagues_trim_side)
    luaunit.assertEquals(sprites[4].sprite, images.popup_leagues_trim_header)
    luaunit.assertEquals(sprites[4].w, 173)
    luaunit.assertEquals(sprites[4].h, 33)
    luaunit.assertEquals(sprites[5].sprite, images.popup_leagues_trim_footer)
    luaunit.assertEquals(sprites[5].w, 141)
    luaunit.assertEquals(sprites[5].h, 34)
    luaunit.assertEquals(sprites[6].sprite.name, "ribbon_leagues_gold_0")
    luaunit.assertEquals(sprites[6].h, 75)
    luaunit.assertEquals(sprites[7].sprite.name, "ribbon_leagues_gold_1")
    luaunit.assertEquals(sprites[7].h, sprites[6].h)
    luaunit.assertTrue(sprites[7].w > 1)
    luaunit.assertEquals(sprites[8].sprite.name, "ribbon_leagues_gold_2")
    luaunit.assertEquals(sprites[9].spriteID, 17127)
    luaunit.assertFalse(sprites[9].hidden)
    luaunit.assertFalse(created.layers[1].hidden)
    luaunit.assertEquals(created.texts[1].content, "Relic Activated!")
    luaunit.assertEquals(created.texts[1].align, "CENTRE")
    luaunit.assertEquals(created.texts[2].content, "Excavator")
    luaunit.assertTrue(images.ribbon_leagues_gold_0.loaded)
    luaunit.assertEquals(images.leagues_default_background.loads, 1)

    draw("leagues_red")
    luaunit.assertEquals(sprites[6].sprite.name, "ribbon_leagues_red_0")
    luaunit.assertEquals(sprites[7].sprite.name, "ribbon_leagues_red_1")
    luaunit.assertEquals(sprites[8].sprite.name, "ribbon_leagues_red_2")
    -- Already loaded on the first gold draw; a second theme must not Load the background again.
    luaunit.assertEquals(images.leagues_default_background.loads, 1)

    draw("leagues_red_gold")
    luaunit.assertEquals(sprites[6].sprite.name, "ribbon_leagues_red_gold_0")
    luaunit.assertEquals(sprites[7].sprite.name, "ribbon_leagues_red_gold_1")
    luaunit.assertEquals(sprites[8].sprite.name, "ribbon_leagues_red_gold_2")

    Popup.Draw(canvas, {
        theme = Popup.ThemeFor("leagues_gold"),
        anim = { alpha = 0 },
    })
    luaunit.assertTrue(created.layers[1].hidden)

    Popup.Draw(canvas, {
        theme = Popup.ThemeFor("parchment"),
        title = "T", body = "b",
        anim = { alpha = 1 },
    })
    luaunit.assertTrue(created.layers[1].hidden)

    _G.ui = previousUi
    _G.Plugin = previousPlugin
end

function TestPopup:testLeaguesDrawWithoutUiDoesNotThrow()
    local previousUi = _G.ui
    _G.ui = nil
    local canvas, calls = makeFakeCanvas()
    canvas.parent = { id = "leagues-headless" }
    local ok = pcall(function()
        Popup.Draw(canvas, {
            theme = Popup.ThemeFor("leagues_red"),
            title = "League task complete!",
            body = "Mine 10 tin ore.",
            anim = { alpha = 1 },
        })
    end)
    _G.ui = previousUi
    luaunit.assertTrue(ok)
    luaunit.assertEquals(calls.rects, 0)
end

function TestPopup:testLeaguesLayerHidesWhenTheHandleExpires()
    local created, previousUi = installFakeUi()
    local _, previousPlugin = installImages()
    local canvas = makeFakeCanvas()
    canvas.parent = { id = "leagues-expiry" }
    local effects = EffectRegistry.new()
    local handle = Popup.BuildHandle({
        theme = "leagues_gold",
        title = "Relic Activated!",
        body = "Excavator",
        hold = 1,
    })
    effects:PushQueue(Popup.OWNER, handle)
    -- Elapsed 0 is alpha 0, which hides before the layer is built. Step into the fade first.
    effects:Update(0.05)
    effects:Draw(canvas)
    local layer = created.layers[#created.layers]
    luaunit.assertNotNil(layer)
    luaunit.assertFalse(layer.hidden)
    local total = Popup.IN_SECONDS + 1 + Popup.OUT_SECONDS
    effects:Update(total)
    luaunit.assertTrue(layer.hidden)
    _G.ui = previousUi
    _G.Plugin = previousPlugin
end

function TestPopup:testUnknownThemeFallsBackToDefault()
    luaunit.assertEquals(Popup.ThemeFor("nope"), Popup.ThemeFor(Popup.DEFAULT_THEME))
    luaunit.assertEquals(Popup.ThemeFor(nil), Popup.ThemeFor(Popup.DEFAULT_THEME))
end

function TestPopup:testThemeChoicesCoverRegisteredThemesInOrder()
    local choices = Popup.ThemeChoices()
    luaunit.assertTrue(#choices >= 2)
    -- The default (Parchment) is listed first so a fresh node's control defaults to it.
    luaunit.assertEquals(choices[1].value, "parchment")
end

function TestPopup:testRegisterThemeSeamAddsANewTheme()
    Popup.RegisterTheme("test_seam", { kind = "primitive", label = "Seam" })
    luaunit.assertNotNil(Popup.ThemeFor("test_seam"))
    local found = false
    for _, c in ipairs(Popup.ThemeChoices()) do
        if c.value == "test_seam" then found = true end
    end
    luaunit.assertTrue(found)
end

--- Icons: a curated, non-empty dropdown reusing the enum control -------------------------

function TestPopup:testIconChoicesAreCuratedAndNonEmpty()
    local choices = Popup.IconChoices()
    luaunit.assertTrue(#choices >= 2)
    for _, c in ipairs(choices) do
        luaunit.assertNotNil(c.label)
    end
end

--- Node registration + run: Queue-only handle, single body pin, no dismiss pin -----------

local function makeFakeRegistry()
    return {
        types = {},
        RegisterNodeType = function(self, key, desc) self.types[key] = desc end,
    }
end

local function makeCtx(values)
    return {
        In = function(_self, name) return values[name] end,
        firedExec = {},
        Out = function(_self) end,
        Fire = function(self, pin) self.firedExec[pin] = true end,
    }
end

function TestPopup:testRegistersActionPopupWithBodyPinAndNoDismiss()
    local reg = makeFakeRegistry()
    Popup.Register(reg, { effects = EffectRegistry.new() })

    local desc = reg.types["action.popup"]
    luaunit.assertNotNil(desc)
    luaunit.assertEquals(desc.category, "action")

    -- `body` is the one wire-able data input; title/icon/theme/hold ride along as node-config
    -- (this engine stores per-node config only as data-input pin Controls, ADR-0004). The AC
    -- that this node *can* enforce is opting out of the dismiss idiom: no `dismiss` pin and no
    -- exec output - it auto-expires, so there's nothing to dismiss or chain from.
    local byName, hasDismiss, hasExecOut = {}, false, false
    for _, pin in ipairs(desc.pins) do
        byName[pin.name] = pin
        if pin.name == "dismiss" then hasDismiss = true end
        if pin.kind == "exec" and pin.direction == "out" then hasExecOut = true end
    end
    luaunit.assertNotNil(byName.body)
    luaunit.assertEquals(byName.body.kind, "data")
    luaunit.assertNotNil(byName.title)
    luaunit.assertNotNil(byName.icon)
    luaunit.assertNotNil(byName.theme)
    luaunit.assertNotNil(byName.hold)
    luaunit.assertFalse(hasDismiss)
    luaunit.assertFalse(hasExecOut)
end

function TestPopup:testRunPushesOneQueuedAutoExpiringHandle()
    local reg = makeFakeRegistry()
    local effects = EffectRegistry.new()
    Popup.Register(reg, { effects = effects })
    local desc = reg.types["action.popup"]

    desc.run(makeCtx({ body = "You did it!", title = "Done", hold = 1 }))

    local q = effects.queues[Popup.OWNER]
    luaunit.assertNotNil(q)
    luaunit.assertNotNil(q.active)
    luaunit.assertEquals(#q.pending, 0)

    desc.run(makeCtx({ body = "Second", hold = 1 }))
    luaunit.assertEquals(#q.pending, 1)
end

function TestPopup:testRunReadsHoldConfigForExpiry()
    local reg = makeFakeRegistry()
    local effects = EffectRegistry.new()
    Popup.Register(reg, { effects = effects })
    local desc = reg.types["action.popup"]

    desc.run(makeCtx({ body = "hi", hold = 0 }))
    local handle = effects.queues[Popup.OWNER].active
    -- hold = 0 -> only the in+out ramps remain; it expires quickly and cleanly.
    effects:Update(Popup.IN_SECONDS + Popup.OUT_SECONDS + 0.02)
    luaunit.assertNil(effects.queues[Popup.OWNER].active)
end

return TestPopup
