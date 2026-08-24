config = config or {}
config.Inv = config.Inv or {}
config.Inv.INV = config.Inv.INV or { id = 93, size = 28 }
config.Inv.BANK = config.Inv.BANK or { id = 95, size = 28 }

local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local Serialize = require("serialize")
local Json = require("json")
local Runtime = require("runtime")
local newFakeEventSource = require("fake_event_source")
local InventoryTrigger = require("nodes/triggers/inventory")

local INV, BANK = config.Inv.INV, config.Inv.BANK

TestInventory = {}

function TestInventory:setUp()
    config.Inv = { INV = INV, BANK = BANK }

    self.registry = Registry.new()
    self.source = newFakeEventSource()
    self.runtime = Runtime.new(self.source.source)
    self.graph = Graph.new(self.registry)
    self.runtime:SetGraph(self.graph)

    InventoryTrigger.Register(self.registry, self.runtime)

    self.fires = 0
    local t = self
    self.registry:RegisterNodeType("fixture.mark", {
        category = "action",
        pins = { { name = "in", kind = "exec", direction = "in", terminates = true } },
        run = function() t.fires = t.fires + 1 end,
    })

    self.invs = {}
    _G.Inventory = {
        Find = function(invType)
            return t.invs[invType]
        end,
    }
end

function TestInventory:tearDown()
    _G.Inventory = nil
end

function TestInventory:setInv(invType, opts)
    opts = opts or {}
    local slots = opts.slots or {}
    self.invs[invType] = {
        usedSlotCount = opts.usedSlotCount or #slots,
        slotCount = opts.slotCount or 28,
        isValid = true,
        GetSlots = function() return slots end,
    }
end

function TestInventory:addWired(controls)
    controls = controls or { container = INV }
    local id = self.graph:AddNode("trigger.inventory", controls)
    self.graph:Connect(id, "out", self.graph:AddNode("fixture.mark"), "in")
    return id
end

function TestInventory:pushUpdated(invType, size)
    if size ~= nil then
        invType.size = size
    end
    self.source:Push("InventoryUpdated", { inv = invType, slotsUpdated = {} })
end

function TestInventory:pushAdded(invType)
    self.source:Push("InventoryAdded", { inv = invType })
end

function TestInventory:pushRemoved(invType)
    self.source:Push("InventoryRemoved", { inv = invType })
end

local function slot(name, configName, count)
    return { obj = { name = name, configName = configName }, count = count }
end

function TestInventory:testNodeHasNoModesAndNoMatcher()
    local nt = self.registry:GetNodeType("trigger.inventory")
    luaunit.assertEquals(nt.displayName, "Inventory")
    luaunit.assertEquals(nt.category, "trigger")
    luaunit.assertNil(nt.modes)
    luaunit.assertNil(nt.pins.nameMatch)
    luaunit.assertNil(nt.pins.contains)
    luaunit.assertNotNil(nt.pins.container)
    luaunit.assertEquals(nt.pins.container.dataType, "invContainer")
    luaunit.assertEquals(nt.pins.snapshot.dataType, "invSnapshot")
    luaunit.assertEquals(nt.pins.prevSnapshot.dataType, "invSnapshot")
    luaunit.assertEquals(nt.pins.isFull.dataType, "bool")
    luaunit.assertEquals(nt.pins.isEmpty.dataType, "bool")
end

function TestInventory:testConfigInvTypesCompareEqualByIdentity()
    luaunit.assertTrue(config.Inv.INV == INV)
    luaunit.assertTrue(config.Inv.BANK == BANK)
    luaunit.assertFalse(config.Inv.INV == config.Inv.BANK)
    luaunit.assertFalse(config.Inv.INV == { id = 93, size = 28 })
end

function TestInventory:testNNodesCostExactlyOneUpdatedSubscription()
    self:addWired()
    self:addWired({ container = BANK })
    luaunit.assertEquals(self.source:SubscribeCount("InventoryUpdated"), 1)
end

function TestInventory:testFiresOnInventoryUpdated()
    self:setInv(INV, { slots = { slot("Shark", "SHARK", 1) } })
    self:addWired()
    self:pushUpdated(INV)
    luaunit.assertEquals(self.fires, 1)
end

function TestInventory:testAddedAndRemovedDoNotFire()
    self:setInv(INV, { slots = { slot("Shark", "SHARK", 1) } })
    self:addWired()
    self:pushAdded(INV)
    self:pushRemoved(INV)
    luaunit.assertEquals(self.fires, 0)
    self:pushUpdated(INV)
    luaunit.assertEquals(self.fires, 1)
end

function TestInventory:testDefaultContainerIsInventory()
    self:setInv(INV, {})
    self:setInv(BANK, { slotCount = 10 })
    self:addWired()
    self:pushUpdated(BANK, 10)
    luaunit.assertEquals(self.fires, 0)
    self:pushUpdated(INV)
    luaunit.assertEquals(self.fires, 1)
end

function TestInventory:testBankIgnoresInventoryUpdates()
    self:setInv(INV, {})
    self:setInv(BANK, { slotCount = 10 })
    self:addWired({ container = BANK })
    self:pushUpdated(INV)
    luaunit.assertEquals(self.fires, 0)
    self:pushUpdated(BANK, 10)
    luaunit.assertEquals(self.fires, 1)
end

function TestInventory:testColdUpdatedHasEmptyPrevSnapshot()
    self:setInv(INV, { slots = { slot("Shark", "SHARK", 1) }, usedSlotCount = 1 })
    local nodeId = self:addWired()
    self:pushUpdated(INV)
    local prev = self.graph:GetLastValue(nodeId, "prevSnapshot")
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "prevUsedSlots"), 0)
    luaunit.assertEquals(prev.slots, {})
    luaunit.assertEquals(prev.usedSlotCount, 0)
end

function TestInventory:testRemovedClearsPrevForNextUpdated()
    self:setInv(INV, { slots = { slot("Shark", "SHARK", 1) }, usedSlotCount = 1 })
    local nodeId = self:addWired()
    self:pushUpdated(INV)
    self:pushRemoved(INV)
    luaunit.assertEquals(self.fires, 1)

    self:setInv(INV, { slots = { slot("Lobster", "LOBSTER", 1) }, usedSlotCount = 1 })
    self:pushUpdated(INV)
    luaunit.assertEquals(self.fires, 2)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "prevUsedSlots"), 0)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "prevSnapshot").slots, {})
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "snapshot").slots[1].name, "Lobster")
end

function TestInventory:testSnapshotKeepsSlotsAfterANilHole()
    local slots = {}
    slots[2] = slot("Shark", "SHARK", 1)
    self:setInv(INV, { slots = slots, usedSlotCount = 1, slotCount = 28 })
    local nodeId = self:addWired()
    self:pushUpdated(INV)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "snapshot").slots[1].name, "Shark")
end

function TestInventory:testMissingInvUsesEventSizeForOccupancy()
    self.invs[INV] = nil
    local nodeId = self:addWired()
    self:pushUpdated(INV, 28)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "usedSlots"), 0)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "isEmpty"), true)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "isFull"), false)
end

function TestInventory:testOccupancyOutsUseContainerSlotCount()
    self:setInv(BANK, {
        slots = {
            slot("Coins", "COINS", 100),
        },
        usedSlotCount = 10,
        slotCount = 10,
    })
    local nodeId = self:addWired({ container = BANK })
    self:pushUpdated(BANK, 10)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "prevUsedSlots"), 0)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "usedSlots"), 10)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "isFull"), true)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "isEmpty"), false)
end

function TestInventory:testIsEmptyWhenNoUsedSlots()
    self:setInv(INV, { slots = {}, usedSlotCount = 0, slotCount = 28 })
    local nodeId = self:addWired()
    self:pushUpdated(INV)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "usedSlots"), 0)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "isEmpty"), true)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "isFull"), false)
end

function TestInventory:testIsFullIsNotHardcodedTwentyEight()
    self:setInv(INV, { usedSlotCount = 10, slotCount = 28, slots = {} })
    local nodeId = self:addWired()
    self:pushUpdated(INV)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "isFull"), false)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "usedSlots"), 10)
end

function TestInventory:testFrozenPrevAcrossTwoUpdates()
    local live = slot("Shark", "SHARK", 1)
    self:setInv(INV, { slots = { live }, usedSlotCount = 1, slotCount = 28 })
    local nodeId = self:addWired()
    self:pushUpdated(INV)

    live.count = 5
    live.obj.name = "mutated"
    self:setInv(INV, { slots = { live }, usedSlotCount = 1, slotCount = 28 })
    self:pushUpdated(INV)

    local prev = self.graph:GetLastValue(nodeId, "prevSnapshot")
    local current = self.graph:GetLastValue(nodeId, "snapshot")
    luaunit.assertEquals(prev.slots[1].name, "Shark")
    luaunit.assertEquals(prev.slots[1].count, 1)
    luaunit.assertEquals(current.slots[1].count, 5)

    live.count = 99
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "prevSnapshot").slots[1].count, 1)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "snapshot").slots[1].count, 5)
end

function TestInventory:testSnapshotHasNoLiveInvHandle()
    self:setInv(INV, { slots = { slot("Shark", "SHARK", 1) } })
    local nodeId = self:addWired()
    self:pushUpdated(INV)
    local snap = self.graph:GetLastValue(nodeId, "snapshot")
    luaunit.assertNil(snap.inv)
    luaunit.assertNil(snap.GetSlots)
    luaunit.assertEquals(snap.slots[1].name, "Shark")
    luaunit.assertEquals(snap.slots[1].configName, "SHARK")
    luaunit.assertEquals(snap.slots[1].count, 1)
end

function TestInventory:testInvContainerCodecPersistsIdNotProxy()
    local nodeId = self:addWired({ container = BANK })
    local data = Serialize.Serialize(self.graph)
    luaunit.assertEquals(data.nodes[1].controls.container, BANK.id)
    luaunit.assertEquals(type(data.nodes[1].controls.container), "number")
    luaunit.assertNotNil(Json.Default.encode(data))

    local rebuilt = Serialize.Deserialize(data, self.registry)
    luaunit.assertTrue(rebuilt:GetControl(nodeId, "container") == BANK)
end

function TestInventory:testInvContainerCodecUnknownIdFallsBackToInventory()
    local nodeId = self:addWired()
    local data = Serialize.Serialize(self.graph)
    data.nodes[1].controls.container = 0
    local rebuilt = Serialize.Deserialize(data, self.registry)
    luaunit.assertTrue(rebuilt:GetControl(nodeId, "container") == INV)
end

function TestInventory:testAddedSeedsPrevForNextUpdated()
    self:setInv(INV, { slots = { slot("Shark", "SHARK", 1) }, usedSlotCount = 1 })
    local nodeId = self:addWired()
    self:pushAdded(INV)
    luaunit.assertEquals(self.fires, 0)

    self:setInv(INV, {
        slots = { slot("Shark", "SHARK", 1), slot("Lobster", "LOBSTER", 1) },
        usedSlotCount = 2,
    })
    self:pushUpdated(INV)
    luaunit.assertEquals(self.fires, 1)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "prevUsedSlots"), 1)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "usedSlots"), 2)
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "prevSnapshot").slots[1].name, "Shark")
end

return TestInventory
