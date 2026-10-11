-- action.infobox (#41) through a fake registry + real ui/infobox.lua InfoBox Area.

_G.Vector4 = _G.Vector4 or { new = function(r, g, b, a) return { r, g, b, a } end }

local luaunit = require("luaunit")
local InfoBoxNode = require("src/nodes/actions/infobox")
local InfoBox = require("src/ui/infobox")
-- Real engine (LibNodeGraph, on package.path - see tests/run.lua), so run() is exercised
-- through a genuine ctx rather than a fabricated one.
local Registry = require("registry")
local Graph = require("graph")
local Serialize = require("serialize")

local function makeFakeRegistry()
    return {
        types = {},
        RegisterNodeType = function(self, key, desc) self.types[key] = desc end,
    }
end

TestInfoBoxNodeRegistration = {}

function TestInfoBoxNodeRegistration:setUp()
    self.reg = makeFakeRegistry()
    self.area = InfoBox.new()
    InfoBoxNode.Register(self.reg, { infobox = self.area })
    self.desc = self.reg.types["action.infobox"]
end

function TestInfoBoxNodeRegistration:testRegistersActionInfoboxWithUpdateAndDismissExecIns()
    luaunit.assertNotNil(self.desc)
    luaunit.assertEquals(self.desc.category, "action")

    local byName, execOutCount = {}, 0
    for _, pin in ipairs(self.desc.pins) do
        byName[pin.name] = pin
        if pin.kind == "exec" and pin.direction == "out" then execOutCount = execOutCount + 1 end
    end
    luaunit.assertEquals(byName.update.kind, "exec")
    luaunit.assertEquals(byName.update.direction, "in")
    luaunit.assertEquals(byName.dismiss.kind, "exec")
    luaunit.assertEquals(byName.dismiss.direction, "in")
    luaunit.assertEquals(execOutCount, 0)
    luaunit.assertEquals(byName.value.dataType, "any")
    luaunit.assertEquals(byName.color.dataType, "color")
    luaunit.assertEquals(byName.icon.dataType, "infobox.icon")
    luaunit.assertEquals(byName.title.dataType, "string")
    luaunit.assertEquals(byName.dismissWhenEmpty.dataType, "bool")
    luaunit.assertFalse(byName.dismissWhenEmpty.default)
end

function TestInfoBoxNodeRegistration:testIconChoicesIncludeNoneAndAreCurated()
    local choices = InfoBoxNode.IconChoices()
    luaunit.assertEquals(choices[1].value, nil)
    luaunit.assertEquals(choices[1].label, "None")
    luaunit.assertTrue(#choices > 1)
end

-- Run tests fire through a REAL LibNodeGraph, so ctx is the engine's genuine run context (a
-- fabricated ctx can only agree with the code's own assumptions - how the ctx.pin/ctx.exec
-- divergence slipped through). Tile owner is graph.nodes[id].state, not ctx.nodeId.
TestInfoBoxNodeRun = {}

function TestInfoBoxNodeRun:setUp()
    self.registry = Registry.new()
    self.area = InfoBox.new()
    InfoBoxNode.Register(self.registry, { infobox = self.area })
    self.graph = Graph.new(self.registry)
end

function TestInfoBoxNodeRun:add(controls)
    return self.graph:AddNode("action.infobox", controls)
end

local function ownerOf(graph, id)
    return graph.nodes[id].state
end

function TestInfoBoxNodeRun:testUpdateLazyCreatesTheTile()
    local id = self:add({ value = 5, title = "HP" })
    self.graph:FireInput(id, "update")
    luaunit.assertTrue(self.area:Has(ownerOf(self.graph, id)))
    luaunit.assertEquals(self.area:Get(ownerOf(self.graph, id)).text, "5")
    luaunit.assertEquals(self.area:Get(ownerOf(self.graph, id)).title, "HP")
end

function TestInfoBoxNodeRun:testUpdateRewritesInPlaceNotANewTile()
    local id = self:add({ value = 1 })
    self.graph:FireInput(id, "update")
    self.graph:SetControl(id, "value", 2)
    self.graph:FireInput(id, "update")
    luaunit.assertEquals(self.area:Count(), 1)
    luaunit.assertEquals(self.area:Get(ownerOf(self.graph, id)).text, "2")
end

function TestInfoBoxNodeRun:testExternalFireWithNoExecPinFallsBackToUpdate()
    -- Entered with no exec pin (ctx.exec nil, as an external Graph:Fire does) still lazy-
    -- creates/refreshes the tile rather than dismissing it.
    local id = self:add({ value = "x" })
    self.graph:Fire(id)
    luaunit.assertTrue(self.area:Has(ownerOf(self.graph, id)))
end

function TestInfoBoxNodeRun:testDismissRemovesTheTile()
    local id = self:add({ value = 1 })
    self.graph:FireInput(id, "update")
    self.graph:FireInput(id, "dismiss")
    luaunit.assertFalse(self.area:Has(ownerOf(self.graph, id)))
end

function TestInfoBoxNodeRun:testDismissOnUnknownOwnerIsANoop()
    local id = self:add({})
    local ok = pcall(function() self.graph:FireInput(id, "dismiss") end)
    luaunit.assertTrue(ok)
    luaunit.assertFalse(self.area:Has(ownerOf(self.graph, id)))
end

function TestInfoBoxNodeRun:testDismissWhenEmptyRemovesOnEmptyUpdate()
    local id = self:add({ value = 1 })
    self.graph:FireInput(id, "update")
    self.graph:SetControl(id, "value", 0)
    self.graph:SetControl(id, "dismissWhenEmpty", true)
    self.graph:FireInput(id, "update")
    luaunit.assertFalse(self.area:Has(ownerOf(self.graph, id)))
end

function TestInfoBoxNodeRun:testDismissWhenEmptyOffKeepsTheTileOnEmptyUpdate()
    local id = self:add({ value = 1 })
    self.graph:FireInput(id, "update")
    self.graph:SetControl(id, "value", 0)
    self.graph:SetControl(id, "dismissWhenEmpty", false)
    self.graph:FireInput(id, "update")
    luaunit.assertTrue(self.area:Has(ownerOf(self.graph, id)))
    luaunit.assertEquals(self.area:Get(ownerOf(self.graph, id)).text, "0")
end

function TestInfoBoxNodeRun:testFirstUpdateEmptyWithDismissWhenEmptyNeverAppears()
    local id = self:add({ value = nil, dismissWhenEmpty = true })
    self.graph:FireInput(id, "update")
    luaunit.assertFalse(self.area:Has(ownerOf(self.graph, id)))
end

function TestInfoBoxNodeRun:testDifferentNodesGetDifferentTiles()
    local a = self:add({ value = 1 })
    local b = self:add({ value = 2 })
    self.graph:FireInput(a, "update")
    self.graph:FireInput(b, "update")
    luaunit.assertEquals(self.area:Count(), 2)
end

function TestInfoBoxNodeRun:testDeserializedCloneWithSameNodeIdGetsItsOwnTile()
    local id = self:add({ value = 1, title = "original" })
    self.graph:FireInput(id, "update")
    local clone = Serialize.Deserialize(Serialize.Serialize(self.graph), self.registry)
    luaunit.assertEquals(id, clone.nodes[id].id)
    clone:SetControl(id, "value", 2)
    clone:SetControl(id, "title", "imported")
    clone:FireInput(id, "update")
    luaunit.assertEquals(self.area:Count(), 2)
end

function TestInfoBoxNodeRun:testNilRuntimeInfoboxIsASilentNoop()
    local registry = Registry.new()
    InfoBoxNode.Register(registry, {})
    local graph = Graph.new(registry)
    local id = graph:AddNode("action.infobox", { value = 1 })
    local ok = pcall(function() graph:FireInput(id, "update") end)
    luaunit.assertTrue(ok)
end

function TestInfoBoxNodeRun:testColorPassesThroughUnmodified()
    local color = { r = 10, g = 20, b = 30, a = 255 }
    local id = self:add({ value = 1, color = color })
    self.graph:FireInput(id, "update")
    luaunit.assertEquals(self.area:Get(ownerOf(self.graph, id)).color, color)
end
