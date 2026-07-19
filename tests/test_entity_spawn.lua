-- Exercises the Entity Spawn trigger (`trigger.entity_spawn`, #32) end-to-end through the
-- real event dispatcher. The node fans in all 7 entity channels — NPC/Player/ObjStack ×
-- Added/Removed plus ObjStackEntityChanged — and abstracts them to Spawned / Despawned exec
-- pins, so these tests push representative raw events through a fake event source and assert
-- which exec pin fired plus the shaped data outputs (kind / name / coordGrid / count / entity).
--
-- Everything rides the same injected fake event source the other runtime tests use; no client
-- globals are touched by the node's transform/filter/run, so nothing needs stubbing here.

local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local Runtime = require("runtime")
local newFakeEventSource = require("fake_event_source")
local EntitySpawn = require("nodes/triggers/entity_spawn")

TestEntitySpawn = {}

function TestEntitySpawn:setUp()
    self.registry = Registry.new()
    self.source = newFakeEventSource()
    self.runtime = Runtime.new(self.source.source)
    self.graph = Graph.new(self.registry)
    self.runtime:SetGraph(self.graph)

    EntitySpawn.Register(self.registry, self.runtime)

    -- Downstream counters wired to each exec pin, so a test can prove which transition fired.
    self.counts = { spawned = 0, despawned = 0 }
    local counts = self.counts
    self.registry:RegisterNodeType("fixture.spawned", {
        category = "action",
        pins = { { name = "in", kind = "exec", direction = "in" } },
        run = function() counts.spawned = counts.spawned + 1 end,
    })
    self.registry:RegisterNodeType("fixture.despawned", {
        category = "action",
        pins = { { name = "in", kind = "exec", direction = "in" } },
        run = function() counts.despawned = counts.despawned + 1 end,
    })
end

-- Adds an entity_spawn node with the given controls and wires Spawned+Despawned to the counters.
function TestEntitySpawn:addTrigger(controls)
    local id = self.graph:AddNode("trigger.entity_spawn", controls)
    self.graph:Connect(id, "Spawned", self.graph:AddNode("fixture.spawned"), "in")
    self.graph:Connect(id, "Despawned", self.graph:AddNode("fixture.despawned"), "in")
    return id
end

--- Sample raw events (mirroring the documented payload field names) ----------------------

local function npcAdded(name, coord)
    return { npcEntity = { displayName = name, coordGrid = coord }, entityType = "npc" }
end
local function npcRemoved(name, coord)
    return { npcEntity = { displayName = name, coordGrid = coord }, entityType = "npc" }
end
local function playerAdded(name, coord)
    return { playerEntity = { displayName = name, coordGrid = coord }, entityType = "player" }
end
local function objAdded(name, coord, count)
    return { objStackEntity = { coordGrid = coord }, objType = { name = name }, count = count }
end
local function objRemoved(name, coord, count)
    return { objStackEntity = { coordGrid = coord }, objType = { name = name }, count = count }
end
local function objChanged(name, coord, oldCount, newCount)
    return {
        objStackEntity = { coordGrid = coord },
        objType = { name = name },
        oldCount = oldCount,
        newCount = newCount,
    }
end

--- Spawned / Despawned transitions per channel -------------------------------------------

function TestEntitySpawn:testNpcAddedFiresSpawned()
    self:addTrigger({})
    self.source:Push("NPCEntityAdded", npcAdded("Goblin", { x = 1, z = 2, level = 0 }))
    luaunit.assertEquals(self.counts.spawned, 1)
    luaunit.assertEquals(self.counts.despawned, 0)
end

function TestEntitySpawn:testNpcRemovedFiresDespawned()
    self:addTrigger({})
    self.source:Push("NPCEntityRemoved", npcRemoved("Goblin", { x = 1, z = 2, level = 0 }))
    luaunit.assertEquals(self.counts.spawned, 0)
    luaunit.assertEquals(self.counts.despawned, 1)
end

function TestEntitySpawn:testPlayerAddedFiresSpawned()
    self:addTrigger({})
    self.source:Push("PlayerEntityAdded", playerAdded("Zezima", { x = 3, z = 4, level = 1 }))
    luaunit.assertEquals(self.counts.spawned, 1)
end

function TestEntitySpawn:testPlayerRemovedFiresDespawned()
    self:addTrigger({})
    self.source:Push("PlayerEntityRemoved", playerAdded("Zezima", { x = 3, z = 4, level = 1 }))
    luaunit.assertEquals(self.counts.despawned, 1)
end

function TestEntitySpawn:testObjAddedFiresSpawned()
    self:addTrigger({})
    self.source:Push("ObjStackEntityAdded", objAdded("Coins", { x = 5, z = 5, level = 0 }, 100))
    luaunit.assertEquals(self.counts.spawned, 1)
end

function TestEntitySpawn:testObjRemovedFiresDespawned()
    self:addTrigger({})
    self.source:Push("ObjStackEntityRemoved", objRemoved("Coins", { x = 5, z = 5, level = 0 }, 100))
    luaunit.assertEquals(self.counts.despawned, 1)
end

--- ObjStackEntityChanged folds in by delta sign -----------------------------------------

function TestEntitySpawn:testObjChangedGrowthFiresSpawned()
    self:addTrigger({})
    self.source:Push("ObjStackEntityChanged", objChanged("Coins", { x = 5, z = 5, level = 0 }, 100, 250))
    luaunit.assertEquals(self.counts.spawned, 1)
    luaunit.assertEquals(self.counts.despawned, 0)
end

function TestEntitySpawn:testObjChangedShrinkFiresDespawned()
    self:addTrigger({})
    self.source:Push("ObjStackEntityChanged", objChanged("Coins", { x = 5, z = 5, level = 0 }, 250, 100))
    luaunit.assertEquals(self.counts.spawned, 0)
    luaunit.assertEquals(self.counts.despawned, 1)
end

function TestEntitySpawn:testObjChangedNoDeltaFiresNothing()
    self:addTrigger({})
    self.source:Push("ObjStackEntityChanged", objChanged("Coins", { x = 5, z = 5, level = 0 }, 100, 100))
    luaunit.assertEquals(self.counts.spawned, 0)
    luaunit.assertEquals(self.counts.despawned, 0)
end

--- kind dropdown gates in filter ---------------------------------------------------------

function TestEntitySpawn:testDefaultKindIsAnyAndCatchesEveryChannel()
    self:addTrigger({}) -- no kind control => default "any"
    self.source:Push("NPCEntityAdded", npcAdded("Goblin", { x = 0, z = 0, level = 0 }))
    self.source:Push("PlayerEntityAdded", playerAdded("Zezima", { x = 0, z = 0, level = 0 }))
    self.source:Push("ObjStackEntityAdded", objAdded("Coins", { x = 0, z = 0, level = 0 }, 1))
    luaunit.assertEquals(self.counts.spawned, 3)
end

function TestEntitySpawn:testKindNpcIgnoresPlayerAndObject()
    self:addTrigger({ kind = "npc" })
    self.source:Push("PlayerEntityAdded", playerAdded("Zezima", { x = 0, z = 0, level = 0 }))
    self.source:Push("ObjStackEntityAdded", objAdded("Coins", { x = 0, z = 0, level = 0 }, 1))
    luaunit.assertEquals(self.counts.spawned, 0)
    self.source:Push("NPCEntityAdded", npcAdded("Goblin", { x = 0, z = 0, level = 0 }))
    luaunit.assertEquals(self.counts.spawned, 1)
end

function TestEntitySpawn:testKindObjectMatchesAddedRemovedAndChanged()
    self:addTrigger({ kind = "object" })
    self.source:Push("ObjStackEntityAdded", objAdded("Coins", { x = 0, z = 0, level = 0 }, 1))
    self.source:Push("ObjStackEntityChanged", objChanged("Coins", { x = 0, z = 0, level = 0 }, 1, 2))
    self.source:Push("ObjStackEntityRemoved", objRemoved("Coins", { x = 0, z = 0, level = 0 }, 2))
    luaunit.assertEquals(self.counts.spawned, 2)
    luaunit.assertEquals(self.counts.despawned, 1)
end

--- nameMatch contains-filter gates in filter --------------------------------------------

function TestEntitySpawn:testNameMatchFiltersBySubstring()
    self:addTrigger({ nameMatch = "Gob" })
    self.source:Push("NPCEntityAdded", npcAdded("Cow", { x = 0, z = 0, level = 0 }))
    luaunit.assertEquals(self.counts.spawned, 0)
    self.source:Push("NPCEntityAdded", npcAdded("Goblin", { x = 0, z = 0, level = 0 }))
    luaunit.assertEquals(self.counts.spawned, 1)
end

function TestEntitySpawn:testEmptyNameMatchMatchesEverything()
    self:addTrigger({ nameMatch = "" })
    self.source:Push("NPCEntityAdded", npcAdded("Cow", { x = 0, z = 0, level = 0 }))
    luaunit.assertEquals(self.counts.spawned, 1)
end

function TestEntitySpawn:testNameMatchIsPlainSubstringNotPattern()
    -- A Lua pattern metacharacter in the needle must be treated literally: "a.b" matches the
    -- literal string, not "a<any>b".
    self:addTrigger({ nameMatch = "a.b" })
    self.source:Push("NPCEntityAdded", npcAdded("axb", { x = 0, z = 0, level = 0 }))
    luaunit.assertEquals(self.counts.spawned, 0)
    self.source:Push("NPCEntityAdded", npcAdded("a.b thing", { x = 0, z = 0, level = 0 }))
    luaunit.assertEquals(self.counts.spawned, 1)
end

function TestEntitySpawn:testKindAndNameMatchBothGate()
    self:addTrigger({ kind = "object", nameMatch = "Coins" })
    self.source:Push("NPCEntityAdded", npcAdded("Coins", { x = 0, z = 0, level = 0 })) -- name ok, kind wrong
    self.source:Push("ObjStackEntityAdded", objAdded("Bones", { x = 0, z = 0, level = 0 }, 1)) -- kind ok, name wrong
    luaunit.assertEquals(self.counts.spawned, 0)
    self.source:Push("ObjStackEntityAdded", objAdded("Coins", { x = 0, z = 0, level = 0 }, 1)) -- both ok
    luaunit.assertEquals(self.counts.spawned, 1)
end

--- Shaped data outputs -------------------------------------------------------------------

function TestEntitySpawn:testNpcDataOutputs()
    local entity = { displayName = "Goblin", coordGrid = { x = 7, z = 8, level = 0 } }
    local id = self:addTrigger({})
    self.source:Push("NPCEntityAdded", { npcEntity = entity, entityType = "npc" })
    luaunit.assertEquals(self.graph:GetLastValue(id, "entityKind"), "npc")
    luaunit.assertEquals(self.graph:GetLastValue(id, "name"), "Goblin")
    luaunit.assertEquals(self.graph:GetLastValue(id, "coordGrid"), { x = 7, z = 8, level = 0 })
    luaunit.assertEquals(self.graph:GetLastValue(id, "entity"), entity)
end

function TestEntitySpawn:testObjDataOutputsUseObjTypeNameAndCount()
    local id = self:addTrigger({})
    self.source:Push("ObjStackEntityAdded", objAdded("Coins", { x = 1, z = 1, level = 0 }, 42))
    luaunit.assertEquals(self.graph:GetLastValue(id, "entityKind"), "object")
    luaunit.assertEquals(self.graph:GetLastValue(id, "name"), "Coins")
    luaunit.assertEquals(self.graph:GetLastValue(id, "count"), 42)
end

function TestEntitySpawn:testObjChangedCountReflectsNewCount()
    local id = self:addTrigger({})
    self.source:Push("ObjStackEntityChanged", objChanged("Coins", { x = 1, z = 1, level = 0 }, 10, 30))
    luaunit.assertEquals(self.graph:GetLastValue(id, "count"), 30)
end

--- Fan-in subscribes each distinct channel exactly once ---------------------------------

function TestEntitySpawn:testEachChannelSubscribedExactlyOnce()
    self:addTrigger({})
    self:addTrigger({}) -- a second node must not re-subscribe any channel
    for _, channel in ipairs({
        "NPCEntityAdded", "NPCEntityRemoved",
        "PlayerEntityAdded", "PlayerEntityRemoved",
        "ObjStackEntityAdded", "ObjStackEntityRemoved", "ObjStackEntityChanged",
    }) do
        luaunit.assertEquals(self.source:SubscribeCount(channel), 1, channel .. " subscribe count")
    end
end

return TestEntitySpawn
