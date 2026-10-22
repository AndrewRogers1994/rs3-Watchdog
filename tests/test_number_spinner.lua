local luaunit = require("luaunit")
local NumberSpinner = require("src/ui/widgets/number_spinner")

TestNumberSpinnerSplit = {}

function TestNumberSpinnerSplit:testPutsTheArrowsInAColumnOnTheRight()
    local field, up, down = NumberSpinner.Split(10, 20, 80, 32)
    luaunit.assertEquals(field, { x = 10, y = 20, w = 64, h = 32 })
    luaunit.assertEquals(up, { x = 74, y = 20, w = 16, h = 16 })
    luaunit.assertEquals(down, { x = 74, y = 36, w = 16, h = 16 })
end

function TestNumberSpinnerSplit:testOpenHeightFitsTwoArrows()
    luaunit.assertEquals(NumberSpinner.OpenHeight(), 32)
    local _, up, down = NumberSpinner.Split(0, 0, 40, NumberSpinner.OpenHeight())
    luaunit.assertEquals(up.h, NumberSpinner.ARROW_H)
    luaunit.assertEquals(down.h, NumberSpinner.ARROW_H)
    luaunit.assertEquals(up.y + up.h, down.y)
end

TestNumberSpinnerStep = {}

function TestNumberSpinnerStep:testUpAndDownMoveByOne()
    luaunit.assertEquals(NumberSpinner.Step("50", nil, 1), 51)
    luaunit.assertEquals(NumberSpinner.Step("50", nil, -1), 49)
end

function TestNumberSpinnerStep:testEmptyStartsAtZeroThenSteps()
    luaunit.assertEquals(NumberSpinner.Step("", nil, 1), 1)
    luaunit.assertEquals(NumberSpinner.Step("", nil, -1), 0)
    luaunit.assertEquals(NumberSpinner.Step("   ", 7, 1), 1)
end

function TestNumberSpinnerStep:testDoesNotGoBelowZero()
    luaunit.assertEquals(NumberSpinner.Step("0", nil, -1), 0)
end

function TestNumberSpinnerStep:testFloorsAFractionBeforeStepping()
    luaunit.assertEquals(NumberSpinner.Step("3.9", nil, 1), 4)
end

function TestNumberSpinnerStep:testQuantityWinsOverTheRawText()
    luaunit.assertEquals(NumberSpinner.Step("1K", 1000, 1), 1001)
end

function TestNumberSpinnerStep:testHoldingDownOnZeroIsANoOp()
    luaunit.assertNil(NumberSpinner.Apply("0", nil, -1))
    luaunit.assertEquals(NumberSpinner.Apply("0", nil, 1), 1)
    luaunit.assertEquals(NumberSpinner.Apply("", nil, -1), 0)
end

TestNumberSpinnerHold = {}

function TestNumberSpinnerHold:testAPressIsOneStepEvenWhenRepeatsArriveImmediately()
    local step, state = NumberSpinner.Gate(nil, "press", 0)
    luaunit.assertTrue(step)
    local extra = 0
    for _ = 1, 20 do
        local again
        again, state = NumberSpinner.Gate(state, "repeat", 0)
        if again then extra = extra + 1 end
    end
    luaunit.assertEquals(extra, 0)
    local trailed
    trailed, state = NumberSpinner.Gate(state, "release", 0)
    luaunit.assertFalse(trailed)
    trailed, state = NumberSpinner.Gate(state, "repeat", 0)
    luaunit.assertFalse(trailed)
end

function TestNumberSpinnerHold:testHoldingStepsAgainAfterTheRepeatInterval()
    local _, state = NumberSpinner.Gate(nil, "press", 0)
    local early
    early, state = NumberSpinner.Gate(state, "repeat", NumberSpinner.REPEAT_TICKS - 1)
    luaunit.assertFalse(early)
    local due
    due, state = NumberSpinner.Gate(state, "repeat", NumberSpinner.REPEAT_TICKS)
    luaunit.assertTrue(due)
    luaunit.assertEquals(NumberSpinner.REPEAT_TICKS, 25)
end

function TestNumberSpinnerHold:testANewPressStepsAgainInsideTheRepeatWindow()
    local _, state = NumberSpinner.Gate(nil, "press", 0)
    _, state = NumberSpinner.Gate(state, "release", 2)
    local again
    again, state = NumberSpinner.Gate(state, "press", 3)
    luaunit.assertTrue(again)
end

function TestNumberSpinnerHold:testARepeatOnALaterTickAfterReleaseIsANewPress()
    local _, state = NumberSpinner.Gate(nil, "press", 0)
    _, state = NumberSpinner.Gate(state, "release", 0)
    local again
    again, state = NumberSpinner.Gate(state, "repeat", 1)
    luaunit.assertTrue(again)
end

TestNumberSpinnerArrows = {}

function TestNumberSpinnerArrows:testArrowSpritesFollowTheClientIdTable()
    local previous = id
    id = { Sprite = { SCROLLBAR_V2_0 = 11, SCROLLBAR_V2_1 = 22 } }
    local ok, up, down = pcall(NumberSpinner.ArrowSprites)
    id = previous
    luaunit.assertTrue(ok)
    luaunit.assertEquals(up, 11)
    luaunit.assertEquals(down, 22)
end

return {}
