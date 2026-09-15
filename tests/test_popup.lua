-- Exercises the Popup action node (nodes/actions/popup.lua, #38) through its pure seams:
-- the in->hold->out auto-expiry animation, the theme registry (Parchment default + Leagues,
-- plus the RegisterTheme extension seam), the curated icon dropdown, and the node's `run`
-- pushing a Queue-only effect handle onto a real EffectRegistry.
--
-- The Canvas draw is a client primitive (ui.Canvas / id.Sprite) and is intentionally not
-- asserted here - the handle's draw is only exercised for not-erroring against a fake canvas,
-- never against real pixels, matching test_effects' convention. No LibNodeGraph is required:
-- the node's `run` is driven through a fake registry + fake ctx + a real EffectRegistry, so
-- this file runs standalone even where the engine isn't deployed.

local luaunit = require("luaunit")
local Popup = require("nodes/actions/popup")
local EffectRegistry = require("effects")

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
    -- overload - so a Vector4 there renders nothing. Drive both sprite paths (the 3-part frame
    -- ribbon and the left icon) and assert every colour handed to AddSprite is a number.
    _G.id = _G.id or {}
    Popup.RegisterTheme("sprite_regression", {
        kind = "sprites", label = "Sprite Regression", edgeW = 24,
        sprites = { left = 1, mid = 2, right = 3 },
    })
    local canvas, calls = makeFakeCanvas()
    Popup.Draw(canvas, {
        theme = Popup.ThemeFor("sprite_regression"),
        icon = 4,
        title = "T", body = "b",
        anim = { alpha = 1 },
    })
    luaunit.assertEquals(calls.sprites, 4)
    for _, colour in ipairs(calls.spriteColours) do
        luaunit.assertEquals(type(colour), "number")
    end
end

--- Theme registry: Parchment default + Leagues + extension seam --------------------------

function TestPopup:testDefaultThemeIsParchment()
    luaunit.assertEquals(Popup.DEFAULT_THEME, "parchment")
    luaunit.assertNotNil(Popup.ThemeFor("parchment"))
end

function TestPopup:testLeaguesThemeIsRegistered()
    luaunit.assertNotNil(Popup.ThemeFor("leagues"))
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
