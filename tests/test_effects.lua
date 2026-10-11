-- effects.lua EffectRegistry through Update/Dismiss/Clear against hand-built handles.
-- Canvas drawing is a client primitive and is not asserted here - draw is only recorded as called (#29 AC).

local luaunit = require("luaunit")
local EffectRegistry = require("src/effects")

TestEffects = {}

function TestEffects:setUp()
    self.registry = EffectRegistry.new()
end

-- A minimal handle whose `alive` and `onDone` are test-controlled: `ticksLeft` counts down
-- on each update() call, going not-alive once it hits zero.
local function makeHandle(ticksLeft)
    local calls = { updates = 0, draws = 0, done = false }
    local handle = {
        kind = "fixture",
        state = {},
        update = function(dt)
            calls.updates = calls.updates + 1
            ticksLeft = ticksLeft - 1
            return ticksLeft > 0
        end,
        draw = function(canvas)
            calls.draws = calls.draws + 1
        end,
        onDone = function()
            calls.done = true
        end,
    }
    return handle, calls
end

--- Update(dt): culls expired handles and fires onDone -----------------------------------

function TestEffects:testUpdateAdvancesLiveStackHandle()
    local handle, calls = makeHandle(3)
    self.registry:PushStack("owner", handle)

    self.registry:Update(1)

    luaunit.assertEquals(calls.updates, 1)
    luaunit.assertFalse(calls.done)
end

function TestEffects:testUpdateCullsExpiredHandleAndFiresOnDone()
    local handle, calls = makeHandle(1)
    self.registry:PushStack("owner", handle)

    self.registry:Update(1)

    luaunit.assertTrue(calls.done)
    -- A second Update must not touch the already-removed handle.
    self.registry:Update(1)
    luaunit.assertEquals(calls.updates, 1)
end

function TestEffects:testUpdateCullsExpiredQueueActiveAndPromotesNext()
    local first, firstCalls = makeHandle(1)
    local second, secondCalls = makeHandle(2)
    self.registry:PushQueue("owner", first)
    self.registry:PushQueue("owner", second)

    self.registry:Update(1)

    luaunit.assertTrue(firstCalls.done)
    luaunit.assertEquals(firstCalls.updates, 1)
    luaunit.assertEquals(secondCalls.updates, 0)

    self.registry:Update(1)
    luaunit.assertEquals(secondCalls.updates, 1)
end

--- Stack: N concurrent per owner ---------------------------------------------------------

function TestEffects:testStackKeepsAllHandlesUpToMax()
    local a = makeHandle(10)
    local b = makeHandle(10)
    self.registry:PushStack("owner", a, 2)
    self.registry:PushStack("owner", b, 2)

    self.registry:Update(1)

    luaunit.assertEquals(self.registry:StackCount("owner"), 2)
end

function TestEffects:testStackEvictsOldestPastMax()
    local a, aCalls = makeHandle(10)
    local b = makeHandle(10)
    local c = makeHandle(10)
    self.registry:PushStack("owner", a, 2)
    self.registry:PushStack("owner", b, 2)
    self.registry:PushStack("owner", c, 2)

    luaunit.assertTrue(aCalls.done)
    luaunit.assertEquals(self.registry:StackCount("owner"), 2)
end

function TestEffects:testDifferentOwnersHaveIndependentStacks()
    local a = makeHandle(10)
    local b = makeHandle(10)
    self.registry:PushStack("ownerA", a, 1)
    self.registry:PushStack("ownerB", b, 1)

    luaunit.assertEquals(self.registry:StackCount("ownerA"), 1)
    luaunit.assertEquals(self.registry:StackCount("ownerB"), 1)
end

--- Dismiss: removes the right handle by direct reference ---------------------------------

function TestEffects:testDismissRemovesTheRightStackHandle()
    local a, aCalls = makeHandle(10)
    local b, bCalls = makeHandle(10)
    self.registry:PushStack("owner", a)
    self.registry:PushStack("owner", b)

    self.registry:Dismiss(a)

    luaunit.assertTrue(aCalls.done)
    luaunit.assertFalse(bCalls.done)
    self.registry:Update(1)
    luaunit.assertEquals(aCalls.updates, 0)
    luaunit.assertEquals(bCalls.updates, 1)
end

function TestEffects:testDismissOnQueueActivePromotesNext()
    local first, firstCalls = makeHandle(10)
    local second, secondCalls = makeHandle(10)
    self.registry:PushQueue("owner", first)
    self.registry:PushQueue("owner", second)

    self.registry:Dismiss(first)

    luaunit.assertTrue(firstCalls.done)
    self.registry:Update(1)
    luaunit.assertEquals(firstCalls.updates, 0)
    luaunit.assertEquals(secondCalls.updates, 1)
end

function TestEffects:testDismissOnPendingQueueEntryRemovesWithoutPromoting()
    local first = makeHandle(10)
    local second, secondCalls = makeHandle(10)
    self.registry:PushQueue("owner", first)
    self.registry:PushQueue("owner", second)

    self.registry:Dismiss(second)

    self.registry:Update(1)
    luaunit.assertEquals(secondCalls.updates, 0)
end

function TestEffects:testDismissOfUnknownHandleIsANoOp()
    local handle = makeHandle(10)
    -- Never pushed anywhere; must not error.
    self.registry:Dismiss(handle)
end

--- Clear(): empties everything, no onDone callbacks --------------------------------------

function TestEffects:testClearEmptiesStackAndQueueWithoutFiringOnDone()
    local a, aCalls = makeHandle(10)
    local b, bCalls = makeHandle(10)
    self.registry:PushStack("ownerA", a)
    self.registry:PushQueue("ownerB", b)

    self.registry:Clear()

    luaunit.assertFalse(aCalls.done)
    luaunit.assertFalse(bCalls.done)
    self.registry:Update(1)
    luaunit.assertEquals(aCalls.updates, 0)
    luaunit.assertEquals(bCalls.updates, 0)
end

--- BeginFrame(): wipes the retained Canvas once per frame (distinct from Clear) ----------

function TestEffects:testBeginFrameClearsTheCanvas()
    local cleared = 0
    local fakeCanvas = { Clear = function() cleared = cleared + 1 end }

    self.registry:BeginFrame(fakeCanvas)

    luaunit.assertEquals(cleared, 1)
end

function TestEffects:testBeginFrameLeavesHandlesUntouched()
    -- Clearing the Canvas pixels must not disturb the live handle set (that's Clear's job).
    local a, aCalls = makeHandle(10)
    self.registry:PushStack("owner", a)

    self.registry:BeginFrame({ Clear = function() end })

    luaunit.assertEquals(self.registry:StackCount("owner"), 1)
    self.registry:Update(1)
    luaunit.assertEquals(aCalls.updates, 1)
end

function TestEffects:testBeginFrameIsANoOpWithNoCanvas()
    -- Unmounted (canvas nil) and no override passed - must not error.
    self.registry:BeginFrame()
end

--- Draw: not asserted against real rendering, just that it's invoked on live handles -----

function TestEffects:testDrawInvokesLiveStackAndActiveQueueHandlesOnly()
    local stacked, stackedCalls = makeHandle(10)
    local active, activeCalls = makeHandle(10)
    local pending, pendingCalls = makeHandle(10)
    self.registry:PushStack("ownerA", stacked)
    self.registry:PushQueue("ownerB", active)
    self.registry:PushQueue("ownerB", pending)

    local fakeCanvas = {}
    self.registry:Draw(fakeCanvas)

    luaunit.assertEquals(stackedCalls.draws, 1)
    luaunit.assertEquals(activeCalls.draws, 1)
    luaunit.assertEquals(pendingCalls.draws, 0)
end

return TestEffects
