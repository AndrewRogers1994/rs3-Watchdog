-- Exercises action.screen_flash's shaping and dismiss-on math (#37), plus the draw-delta
-- clock on BuildHandle. No Canvas. Register/run stays with the graph tests.

local luaunit = require("luaunit")
local ScreenFlash = require("src/nodes/actions/screen_flash")

TestScreenFlashAlphaAt = {}

-- Rise is [0, 1) and fall is [1, 2). Fade is the fraction through that half.

function TestScreenFlashAlphaAt:testInstantRiseHoldsPeakForWholeRiseSegment()
    luaunit.assertEquals(ScreenFlash.AlphaAt(0, 200, "instant", "instant"), 200)
    luaunit.assertEquals(ScreenFlash.AlphaAt(0.5, 200, "instant", "instant"), 200)
    luaunit.assertEquals(ScreenFlash.AlphaAt(0.999, 200, "instant", "instant"), 200)
end

function TestScreenFlashAlphaAt:testInstantFallDropsToZeroForWholeFallSegment()
    luaunit.assertEquals(ScreenFlash.AlphaAt(1, 200, "instant", "instant"), 0)
    luaunit.assertEquals(ScreenFlash.AlphaAt(1.5, 200, "instant", "instant"), 0)
    luaunit.assertEquals(ScreenFlash.AlphaAt(1.999, 200, "instant", "instant"), 0)
end

function TestScreenFlashAlphaAt:testInstantInstantIsASquareWaveAcrossCycles()
    luaunit.assertEquals(ScreenFlash.AlphaAt(0, 255, "instant", "instant"), 255)
    luaunit.assertEquals(ScreenFlash.AlphaAt(1.5, 255, "instant", "instant"), 0)
    -- Second cycle repeats identically -- this is a repeating pulse, not a one-shot.
    luaunit.assertEquals(ScreenFlash.AlphaAt(2, 255, "instant", "instant"), 255)
    luaunit.assertEquals(ScreenFlash.AlphaAt(3.5, 255, "instant", "instant"), 0)
end

function TestScreenFlashAlphaAt:testFadeRiseRampsLinearlyAndMeetsTheFallBoundary()
    luaunit.assertEquals(ScreenFlash.AlphaAt(0, 250, "fade", "instant"), 0)
    luaunit.assertEquals(ScreenFlash.AlphaAt(0.5, 250, "fade", "instant"), 125)
    luaunit.assertEquals(ScreenFlash.AlphaAt(1, 250, "fade", "instant"), 0)
end

function TestScreenFlashAlphaAt:testFadeFallRampsLinearlyFromPeakToTheNextRise()
    luaunit.assertEquals(ScreenFlash.AlphaAt(1, 250, "instant", "fade"), 250)
    luaunit.assertEquals(ScreenFlash.AlphaAt(1.5, 250, "instant", "fade"), 125)
    luaunit.assertEquals(ScreenFlash.AlphaAt(2, 250, "instant", "fade"), 250)
end

TestScreenFlashClock = {}

local function pulse(inShape, outShape)
    return ScreenFlash.BuildHandle(
        { r = 255, g = 0, b = 0, a = 200 },
        inShape, outShape, "none",
        { mouse = 0, keyboard = 0 },
        { mouseActivityTick = 0, keyboardActivityTick = 0 })
end

function TestScreenFlashClock:testSameWallTimeFromDifferentFrameSplits()
    local fine = pulse("fade", "instant")
    fine.update(0.25)
    fine.update(0.25)
    local coarse = pulse("fade", "instant")
    coarse.update(0.5)
    luaunit.assertEquals(fine.state.elapsed, 0.5)
    luaunit.assertEquals(coarse.state.elapsed, 0.5)
    luaunit.assertEquals(fine.state.alpha, 100)
    luaunit.assertEquals(coarse.state.alpha, 100)
end

function TestScreenFlashClock:testLargeDeltaLandsOnTheSamePhaseAsElapsedTime()
    local handle = pulse("fade", "fade")
    handle.update(2.5)
    luaunit.assertEquals(handle.state.elapsed, 2.5)
    luaunit.assertEquals(handle.state.alpha, 100)
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
