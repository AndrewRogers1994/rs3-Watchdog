-- Exercises overlay.lua's OverlayStack through its pure logic seam: Show/Dismiss/Update
-- against a real EffectRegistry (in-memory, no Canvas needed — mirrors test_effects.lua) plus
-- the anchor drag/persistence math. Canvas drawing (_drawHandle) and the client-only capture
-- mount are intentionally not asserted here, same convention as effects.lua's own Mount/Draw.

local luaunit = require("luaunit")
local EffectRegistry = require("effects")
local Overlay = require("overlay")

TestOverlay = {}

-- A minimal in-memory stand-in for the anchor persistence hook: { Load()->pos|nil, Save(pos) }.
local function newFakePersistence()
    local fake = { saved = nil, saves = 0 }
    fake.Load = function() return fake.saved end
    fake.Save = function(pos)
        fake.saved = { dx = pos.dx, dy = pos.dy }
        fake.saves = fake.saves + 1
    end
    return fake
end

function TestOverlay:setUp()
    self.effects = EffectRegistry.new()
    self.overlay = Overlay.new(self.effects)
end

--- Show: creates a live, drawable handle tracked per node --------------------------------

function TestOverlay:testShowAddsOneLiveHandle()
    self.overlay:Show("nodeA", { text = "hi" })
    luaunit.assertEquals(self.overlay:LiveCount(), 1)
    luaunit.assertEquals(self.effects:StackCount(Overlay.OWNER), 1)
end

function TestOverlay:testSameNodeRefireStacksMultipleHandles()
    self.overlay:Show("nodeA", { text = "one" })
    self.overlay:Show("nodeA", { text = "two" })
    luaunit.assertEquals(self.overlay:LiveCount(), 2)
    luaunit.assertEquals(#self.overlay.byOwner["nodeA"], 2)
end

function TestOverlay:testDifferentNodesTrackedIndependently()
    self.overlay:Show("nodeA", { text = "a" })
    self.overlay:Show("nodeB", { text = "b" })
    luaunit.assertEquals(#self.overlay.byOwner["nodeA"], 1)
    luaunit.assertEquals(#self.overlay.byOwner["nodeB"], 1)
end

--- Shared cap: 10 total across every node, oldest evicted -------------------------------

function TestOverlay:testSharedStackCapsAtTenAcrossAllNodes()
    for i = 1, 12 do
        self.overlay:Show("node" .. i, { text = tostring(i) })
    end
    luaunit.assertEquals(self.overlay:LiveCount(), 10)
    luaunit.assertEquals(self.effects:StackCount(Overlay.OWNER), 10)
end

function TestOverlay:testEvictionForgetsTheOldestNodesBookkeepingToo()
    for i = 1, 11 do
        self.overlay:Show("node" .. i, { text = tostring(i) })
    end
    -- node1's single toast was the oldest push and must have been evicted.
    luaunit.assertNil(self.overlay.byOwner["node1"])
    luaunit.assertNotNil(self.overlay.byOwner["node11"])
end

--- TTL / sticky lifecycle (advanced via EffectRegistry:Update) ---------------------------

function TestOverlay:testDefaultTTLExpiresAfterFiveSeconds()
    self.overlay:Show("nodeA", { text = "hi" })
    self.effects:Update(4)
    luaunit.assertEquals(self.overlay:LiveCount(), 1)
    self.effects:Update(1.01)
    luaunit.assertEquals(self.overlay:LiveCount(), 0)
end

function TestOverlay:testStickyNeverExpiresRegardlessOfElapsedTime()
    self.overlay:Show("nodeA", { text = "hi", sticky = true })
    self.effects:Update(1000)
    luaunit.assertEquals(self.overlay:LiveCount(), 1)
end

--- Dismiss: clears only the named node's live overlays -----------------------------------

function TestOverlay:testDismissClearsOnlyThatNodesHandles()
    self.overlay:Show("nodeA", { text = "a1" })
    self.overlay:Show("nodeA", { text = "a2" })
    self.overlay:Show("nodeB", { text = "b1" })

    self.overlay:Dismiss("nodeA")

    luaunit.assertEquals(self.overlay:LiveCount(), 1)
    luaunit.assertNil(self.overlay.byOwner["nodeA"])
    luaunit.assertEquals(#self.overlay.byOwner["nodeB"], 1)
end

function TestOverlay:testDismissOfUnknownNodeIsANoOp()
    self.overlay:Show("nodeA", { text = "a" })
    self.overlay:Dismiss("ghost")
    luaunit.assertEquals(self.overlay:LiveCount(), 1)
end

function TestOverlay:testDismissedStickyOverlayIsGoneEvenThoughItNeverExpires()
    self.overlay:Show("nodeA", { text = "a", sticky = true })
    self.overlay:Dismiss("nodeA")
    self.effects:Update(1)
    luaunit.assertEquals(self.overlay:LiveCount(), 0)
end

--- Anchor: default + persisted round-trip -------------------------------------------------

function TestOverlay:testDefaultAnchorOffsetIsZero()
    local a = self.overlay:GetAnchorOffset()
    luaunit.assertEquals(a, { dx = 0, dy = 0 })
end

function TestOverlay:testLoadsPersistedAnchorOnConstruction()
    local persistence = newFakePersistence()
    persistence.saved = { dx = 12, dy = -4 }
    local overlay = Overlay.new(self.effects, persistence)
    luaunit.assertEquals(overlay:GetAnchorOffset(), { dx = 12, dy = -4 })
end

--- Drag: begin/drag-to/end, persisting only on release ------------------------------------

function TestOverlay:testDragMovesAnchorByMouseDelta()
    self.overlay:BeginDrag({ x = 100, y = 100 })
    self.overlay:DragTo({ x = 130, y = 90 })
    luaunit.assertEquals(self.overlay:GetAnchorOffset(), { dx = 30, dy = -10 })
end

function TestOverlay:testDragToWithoutBeginIsANoOp()
    self.overlay:DragTo({ x = 500, y = 500 })
    luaunit.assertEquals(self.overlay:GetAnchorOffset(), { dx = 0, dy = 0 })
end

function TestOverlay:testEndDragPersistsFinalPosition()
    local persistence = newFakePersistence()
    local overlay = Overlay.new(self.effects, persistence)
    overlay:BeginDrag({ x = 0, y = 0 })
    overlay:DragTo({ x = 10, y = 20 })
    overlay:EndDrag()
    luaunit.assertEquals(persistence.saved, { dx = 10, dy = 20 })
    luaunit.assertEquals(persistence.saves, 1)
end

function TestOverlay:testDragUpdatesDoNotPersistUntilEndDrag()
    local persistence = newFakePersistence()
    local overlay = Overlay.new(self.effects, persistence)
    overlay:BeginDrag({ x = 0, y = 0 })
    overlay:DragTo({ x = 10, y = 20 })
    luaunit.assertEquals(persistence.saves, 0)
end

function TestOverlay:testEndDragWithoutPersistenceHookIsSafe()
    self.overlay:BeginDrag({ x = 0, y = 0 })
    self.overlay:DragTo({ x = 5, y = 5 })
    self.overlay:EndDrag() -- must not error
    luaunit.assertEquals(self.overlay:GetAnchorOffset(), { dx = 5, dy = 5 })
end

function TestOverlay:testSecondDragStartsFromThePreviousAnchor()
    self.overlay:BeginDrag({ x = 0, y = 0 })
    self.overlay:DragTo({ x = 10, y = 10 })
    self.overlay:EndDrag()

    self.overlay:BeginDrag({ x = 50, y = 50 })
    self.overlay:DragTo({ x = 60, y = 45 })
    luaunit.assertEquals(self.overlay:GetAnchorOffset(), { dx = 20, dy = 5 })
end

return TestOverlay
