-- Location trigger (#34) through poll dispatcher. Load/retarget seed without firing (#72).
-- Fake Player global; Logic ticks via fake event source.

local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local Runtime = require("runtime")
local newFakeEventSource = require("fake_event_source")
local Location = require("nodes/triggers/location")

-- GetEntity mirrors the client API (`.coordGrid`).
Player = {
    available = true,
    coord = { x = 100, z = 100, level = 0 },
    IsAvailable = function() return Player.available end,
    GetEntity = function() return { coordGrid = Player.coord } end,
}

TestLocation = {}

function TestLocation:setUp()
    self.registry = Registry.new()
    self.source = newFakeEventSource()
    self.runtime = Runtime.new(self.source.source)
    self.graph = Graph.new(self.registry)
    self.runtime:SetGraph(self.graph)

    Location.Register(self.registry, self.runtime)

    self.counts = { enter = 0, leave = 0 }
    local counts = self.counts
    self.registry:RegisterNodeType("fixture.enter", {
        category = "action",
        pins = { { name = "in", kind = "exec", direction = "in" } },
        run = function() counts.enter = counts.enter + 1 end,
    })
    self.registry:RegisterNodeType("fixture.leave", {
        category = "action",
        pins = { { name = "in", kind = "exec", direction = "in" } },
        run = function() counts.leave = counts.leave + 1 end,
    })

    Player.available = true
    Player.coord = { x = 0, z = 0, level = 0 }
end

function TestLocation:addLocation(target, radius)
    local id = self.graph:AddNode("trigger.location", { target = target, radius = radius })
    local enterId = self.graph:AddNode("fixture.enter")
    local leaveId = self.graph:AddNode("fixture.leave")
    self.graph:Connect(id, "Enter", enterId, "in")
    self.graph:Connect(id, "Leave", leaveId, "in")
    return id
end

function TestLocation:moveTo(x, z, level)
    Player.coord = { x = x, z = z, level = level or 0 }
    self.source:Push("Logic", {})
end

-- First sample after load reseeds without an edge (#72). Far from targets used here (0/10/50/100).
function TestLocation:primeOutside()
    self:moveTo(9999, 9999)
end

function TestLocation:logOutTick()
    Player.available = false
    self.source:Push("Logic", {})
    Player.available = true
end

--- Enter / Leave edge semantics ----------------------------------------------------------

function TestLocation:testEnterFiresOnceOnEnteringRadius()
    self:addLocation({ x = 100, z = 100, level = 0 }, 5)

    self:moveTo(120, 100) -- 20 tiles away: outside
    luaunit.assertEquals(self.counts.enter, 0)

    self:moveTo(103, 98) -- Chebyshev max(3,2)=3 <= 5: Enter
    luaunit.assertEquals(self.counts.enter, 1)
end

function TestLocation:testNoReEnterWhileStayingInRadius()
    self:addLocation({ x = 100, z = 100, level = 0 }, 5)

    self:primeOutside()
    self:moveTo(100, 100) -- Enter (distance 0)
    self:moveTo(102, 103) -- still in range (max 3)
    self:moveTo(105, 105) -- still in range (max 5, edge)
    luaunit.assertEquals(self.counts.enter, 1)
    luaunit.assertEquals(self.counts.leave, 0)
end

function TestLocation:testLeaveFiresOnLeavingRadius()
    self:addLocation({ x = 100, z = 100, level = 0 }, 5)

    self:primeOutside()
    self:moveTo(100, 100) -- Enter
    self:moveTo(100, 106) -- max 6 > 5: Leave
    luaunit.assertEquals(self.counts.enter, 1)
    luaunit.assertEquals(self.counts.leave, 1)
end

function TestLocation:testEnterLeaveEnterCycles()
    self:addLocation({ x = 50, z = 50, level = 0 }, 2)

    self:primeOutside()
    self:moveTo(50, 50) -- Enter
    self:moveTo(60, 50) -- Leave
    self:moveTo(51, 51) -- Enter again
    luaunit.assertEquals(self.counts.enter, 2)
    luaunit.assertEquals(self.counts.leave, 1)
end

function TestLocation:testRadiusZeroMatchesOnlyExactTile()
    self:addLocation({ x = 10, z = 10, level = 0 }, 0)

    self:moveTo(11, 10) -- one tile off: outside r=0
    luaunit.assertEquals(self.counts.enter, 0)
    self:moveTo(10, 10) -- exact tile: Enter
    luaunit.assertEquals(self.counts.enter, 1)
end

--- Level / plane match -------------------------------------------------------------------

function TestLocation:testDifferentLevelNeverMatchesEvenWhenXZInRange()
    self:addLocation({ x = 100, z = 100, level = 0 }, 5)

    self:moveTo(100, 100, 1) -- exact x/z but wrong plane
    luaunit.assertEquals(self.counts.enter, 0)

    self:moveTo(100, 100, 0) -- same tile, right plane: Enter
    luaunit.assertEquals(self.counts.enter, 1)
end

--- nil / partial target never fires -----------------------------------------------------

function TestLocation:testNilTargetNeverFires()
    self:addLocation(nil, 5)

    self:moveTo(0, 0)
    self:moveTo(1, 1)
    luaunit.assertEquals(self.counts.enter, 0)
    luaunit.assertEquals(self.counts.leave, 0)
end

function TestLocation:testPartialTargetNeverFires()
    self:addLocation({ x = 5 }, 5) -- z/level missing: not a usable tile

    self:moveTo(5, 0)
    luaunit.assertEquals(self.counts.enter, 0)
end

--- Radius normalization -----------------------------------------------------------------

function TestLocation:testNegativeRadiusFlooredToZero()
    self:addLocation({ x = 0, z = 0, level = 0 }, -3)

    self:moveTo(1, 0) -- would be in range for r>=1, but negative floors to 0
    luaunit.assertEquals(self.counts.enter, 0)
    self:moveTo(0, 0) -- exact tile matches r=0
    luaunit.assertEquals(self.counts.enter, 1)
end

--- Load / retarget seed the baseline without emitting an edge (#72) ----------------------

function TestLocation:testAlreadyInRangeAtLoadDoesNotEnter()
    self:addLocation({ x = 0, z = 0, level = 0 }, 5)

    -- First sample after the graph goes live: seed in-range without Enter. Staying inside
    -- must not catch up with a delayed Enter; walking out is a real Leave.
    self:moveTo(2, 2)
    luaunit.assertEquals(self.counts.enter, 0)
    self:moveTo(3, 1)
    luaunit.assertEquals(self.counts.enter, 0)
    self:moveTo(50, 50)
    luaunit.assertEquals(self.counts.leave, 1)
end

function TestLocation:testSettingTargetToCurrentPositionDoesNotEnter()
    local id = self:addLocation({ x = 500, z = 500, level = 0 }, 5)

    self:moveTo(0, 0) -- seed: outside the original target
    luaunit.assertEquals(self.counts.enter, 0)

    self.graph:SetControl(id, "target", { x = 0, z = 0, level = 0 })
    self:moveTo(0, 0) -- first sample of the new target: already inside, must not Enter
    luaunit.assertEquals(self.counts.enter, 0)

    self:moveTo(0, 20)
    luaunit.assertEquals(self.counts.leave, 1)
    self:moveTo(0, 0)
    luaunit.assertEquals(self.counts.enter, 1)
end

--- Logout freezes edge state (no spurious Leave) ----------------------------------------

function TestLocation:testLogoutFreezesStateNoSpuriousLeave()
    self:addLocation({ x = 0, z = 0, level = 0 }, 5)

    self:primeOutside()
    self:moveTo(0, 0)   -- Enter
    self:logOutTick()   -- unreadable: skip + freeze (no Leave)
    self:logOutTick()
    self:moveTo(1, 1)   -- relog still in range: no re-Enter
    luaunit.assertEquals(self.counts.enter, 1)
    luaunit.assertEquals(self.counts.leave, 0)
end

function TestLocation:testRealExitAfterLogoutStillLeaves()
    self:addLocation({ x = 0, z = 0, level = 0 }, 5)

    self:primeOutside()
    self:moveTo(0, 0)     -- Enter
    self:logOutTick()     -- freeze at in-range
    self:moveTo(50, 50)   -- genuinely out of range now: Leave
    luaunit.assertEquals(self.counts.leave, 1)
end

--- Data outputs -------------------------------------------------------------------------

function TestLocation:testCoordAndDistanceDataOutputs()
    local id = self:addLocation({ x = 100, z = 100, level = 2 }, 10)

    self:primeOutside()
    self:moveTo(104, 97, 2) -- Chebyshev max(4,3)=4, in range: Enter
    local coord = self.graph:GetLastValue(id, "coord")
    luaunit.assertEquals(coord, { x = 104, z = 97, level = 2 })
    luaunit.assertEquals(self.graph:GetLastValue(id, "distance"), 4)
end

function TestLocation:testDistanceReflectsExitDistanceOnLeave()
    local id = self:addLocation({ x = 0, z = 0, level = 0 }, 3)

    self:primeOutside()
    self:moveTo(0, 0)   -- Enter, distance 0
    self:moveTo(0, 7)   -- Leave, distance 7
    luaunit.assertEquals(self.graph:GetLastValue(id, "distance"), 7)
    luaunit.assertEquals(self.graph:GetLastValue(id, "coord"), { x = 0, z = 7, level = 0 })
end

--- transform samples once per tick regardless of node count -----------------------------

function TestLocation:testEachNodeKeepsItsOwnEdgeState()
    local hits = { near = 0, far = 0 }
    self.registry:RegisterNodeType("fixture.nearHit", {
        category = "action",
        pins = { { name = "in", kind = "exec", direction = "in" } },
        run = function() hits.near = hits.near + 1 end,
    })
    self.registry:RegisterNodeType("fixture.farHit", {
        category = "action",
        pins = { { name = "in", kind = "exec", direction = "in" } },
        run = function() hits.far = hits.far + 1 end,
    })

    local near = self.graph:AddNode("trigger.location", { target = { x = 0, z = 0, level = 0 }, radius = 2 })
    local far = self.graph:AddNode("trigger.location", { target = { x = 0, z = 0, level = 0 }, radius = 10 })
    self.graph:Connect(near, "Enter", self.graph:AddNode("fixture.nearHit"), "in")
    self.graph:Connect(far, "Enter", self.graph:AddNode("fixture.farHit"), "in")

    self:primeOutside()
    self:moveTo(5, 0) -- distance 5: inside far (10), outside near (2)
    luaunit.assertEquals(hits.near, 0)
    luaunit.assertEquals(hits.far, 1)
end

return TestLocation
