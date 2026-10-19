-- Exercises action.screen_flash's pure shaping/dismiss-on math (#37) in isolation, the same
-- way ui/color.lua's math is tested without a client - ScreenFlash.AlphaAt/ShouldAutoDismiss
-- take/return plain values, no Canvas/Graph/Registry involved. The Register/run wiring against
-- a real LibNodeGraph Graph is exercised only in-client (LibNodeGraph is an external sibling
-- dependency not present under this standalone harness -- see CLAUDE.md and the other
-- Registry/Graph-backed test files, which hit the same gap).

local luaunit = require("luaunit")
local ScreenFlash = require("src/nodes/actions/screen_flash")

TestScreenFlashAlphaAt = {}

-- Rise is ticks 0-49 and fall is 50-99 (50 ticks each, 100-tick cycle), matching
-- ScreenFlash's SEGMENT_TICKS. Fade steps are peak/50, so tick 0 is one step up
-- and the last rise tick lands on peak.

function TestScreenFlashAlphaAt:testInstantRiseHoldsPeakForWholeRiseSegment()
    for tick = 0, 49 do
        luaunit.assertEquals(ScreenFlash.AlphaAt(tick, 200, "instant", "instant"), 200)
    end
end

function TestScreenFlashAlphaAt:testInstantFallDropsToZeroForWholeFallSegment()
    for tick = 50, 99 do
        luaunit.assertEquals(ScreenFlash.AlphaAt(tick, 200, "instant", "instant"), 0)
    end
end

function TestScreenFlashAlphaAt:testInstantInstantIsASquareWaveAcrossCycles()
    luaunit.assertEquals(ScreenFlash.AlphaAt(0, 255, "instant", "instant"), 255)
    luaunit.assertEquals(ScreenFlash.AlphaAt(99, 255, "instant", "instant"), 0)
    -- Second cycle repeats identically -- this is a repeating pulse, not a one-shot.
    luaunit.assertEquals(ScreenFlash.AlphaAt(100, 255, "instant", "instant"), 255)
    luaunit.assertEquals(ScreenFlash.AlphaAt(199, 255, "instant", "instant"), 0)
end

function TestScreenFlashAlphaAt:testFadeRiseRampsLinearlyAndHitsPeakOnLastRiseTick()
    luaunit.assertAlmostEquals(ScreenFlash.AlphaAt(0, 250, "fade", "instant"), 5, 1e-9)
    luaunit.assertAlmostEquals(ScreenFlash.AlphaAt(49, 250, "fade", "instant"), 250, 1e-9)
end

function TestScreenFlashAlphaAt:testFadeFallRampsLinearlyAndHitsZeroOnLastFallTick()
    luaunit.assertAlmostEquals(ScreenFlash.AlphaAt(50, 250, "instant", "fade"), 245, 1e-9)
    luaunit.assertAlmostEquals(ScreenFlash.AlphaAt(99, 250, "instant", "fade"), 0, 1e-9)
end

function TestScreenFlashAlphaAt:testIndependentShapesPerSegment()
    -- fade in, instant out: rise ramps, fall snaps to zero immediately.
    -- Tick 25 is 26/50 of the way up (52); tick 50 is the first fall tick.
    luaunit.assertAlmostEquals(ScreenFlash.AlphaAt(25, 100, "fade", "instant"), 52, 1e-9)
    luaunit.assertEquals(ScreenFlash.AlphaAt(50, 100, "fade", "instant"), 0)
end

TestScreenFlashAutoDismiss = {}

function TestScreenFlashAutoDismiss:testNoneNeverAutoDismisses()
    local baseline = { mouse = 1, keyboard = 1 }
    luaunit.assertFalse(ScreenFlash.ShouldAutoDismiss("none", baseline, { mouse = 99, keyboard = 99 }))
end

function TestScreenFlashAutoDismiss:testMouseOnlyTriggersOnMouseTickChange()
    local baseline = { mouse = 1, keyboard = 1 }
    luaunit.assertTrue(ScreenFlash.ShouldAutoDismiss("mouse", baseline, { mouse = 2, keyboard = 1 }))
    luaunit.assertFalse(ScreenFlash.ShouldAutoDismiss("mouse", baseline, { mouse = 1, keyboard = 2 }))
end

function TestScreenFlashAutoDismiss:testKeyboardOnlyTriggersOnKeyboardTickChange()
    local baseline = { mouse = 1, keyboard = 1 }
    luaunit.assertTrue(ScreenFlash.ShouldAutoDismiss("keyboard", baseline, { mouse = 1, keyboard = 2 }))
    luaunit.assertFalse(ScreenFlash.ShouldAutoDismiss("keyboard", baseline, { mouse = 2, keyboard = 1 }))
end

function TestScreenFlashAutoDismiss:testBothTriggersOnEitherTickChange()
    local baseline = { mouse = 1, keyboard = 1 }
    luaunit.assertTrue(ScreenFlash.ShouldAutoDismiss("both", baseline, { mouse = 2, keyboard = 1 }))
    luaunit.assertTrue(ScreenFlash.ShouldAutoDismiss("both", baseline, { mouse = 1, keyboard = 2 }))
    luaunit.assertFalse(ScreenFlash.ShouldAutoDismiss("both", baseline, { mouse = 1, keyboard = 1 }))
end

return TestScreenFlashAlphaAt
