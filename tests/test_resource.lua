-- Resource Changed (#158) through the real event dispatcher. A fake reader stands in for
-- the client pools. Tests assert whether `out` fires and what current, max, and previous are.

local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local Runtime = require("src/runtime")
local newFakeEventSource = require("fake_event_source")
id = id or {}
id.VarPlayer = id.VarPlayer or {
    LIFEPOINTS = -1669,
    MAXLIFEPOINTS = -24596,
    PRAYER_POINTS = -16737,
    PRAYER_POINTS_VAR = 3274,
    LORE_POINTS = -41525,
    LORE_POINTS_VAR = 8040,
    SA_ENERGY = 679,
    ARCH_RELIC_HEIGHTENED_SENSES_BOOST = -46760,
    COMBAT_SET_EGWD_ZAM_MELEE = -51565,
}
local Resource = require("src/nodes/triggers/resource")

TestResource = {}

function TestResource:setUp()
    self.registry = Registry.new()
    self.source = newFakeEventSource()
    self.runtime = Runtime.new(self.source.source)
    self.graph = Graph.new(self.registry)
    self.runtime:SetGraph(self.graph)

    Resource.Register(self.registry, self.runtime)

    self.fires = 0
    local fires = self
    self.registry:RegisterNodeType("fixture.resource_out", {
        category = "action",
        pins = { { name = "in", kind = "exec", direction = "in" } },
        run = function() fires.fires = fires.fires + 1 end,
    })

    self.pool = { current = 1000, max = 9900 }
    Resource.SetReader(function()
        if self.pool.fail then return nil end
        return self.pool.current, self.pool.max
    end)
end

function TestResource:tearDown()
    Resource.SetReader(nil)
    if self.restoreVar then
        var = self.savedVar
        self.restoreVar = nil
    end
    if self.restorePlayer then
        Player = self.savedPlayer
        self.restorePlayer = nil
    end
end

function TestResource:addNode(resource)
    local id = self.graph:AddNode("trigger.resource_changed", { resource = resource })
    self.graph:Connect(id, "out", self.graph:AddNode("fixture.resource_out"), "in")
    return id
end

-- Life points wake on LIFEPOINTS (-1669) and MAXLIFEPOINTS (-24596). The event's old/new values are not the pool.
function TestResource:transmitBase(id)
    self:transmitVar(id, nil)
end

function TestResource:transmitVar(id, baseId)
    local var = { id = id, oldValue = -1, newValue = -2 }
    if baseId ~= nil then
        var.baseVar = { id = baseId }
    end
    self.source:Push("VarTransmit", { var = var })
end

function TestResource:transmitRun()
    self.source:Push("RunEnergyTransmit", { oldRunEnergy = 1, newRunEnergy = 99 })
end

function TestResource:testFirstReadIsSilentAndLaterChangeReportsPrevious()
    local id = self:addNode("life")

    self:transmitBase(-1669)
    luaunit.assertEquals(self.fires, 0)
    luaunit.assertNil(self.graph:GetLastValue(id, "current"))

    self.pool.current = 900
    self.pool.max = 9800
    self:transmitBase(-1669)
    luaunit.assertEquals(self.fires, 1)
    luaunit.assertEquals(self.graph:GetLastValue(id, "current"), 900)
    luaunit.assertEquals(self.graph:GetLastValue(id, "max"), 9800)
    luaunit.assertEquals(self.graph:GetLastValue(id, "previous"), 1000)
end

function TestResource:testNewGraphStartsSilent()
    self:addNode("life")
    self:transmitBase(-1669)

    local other = Graph.new(self.registry)
    self.runtime:SetGraph(other)
    local id = other:AddNode("trigger.resource_changed", { resource = "life" })
    other:Connect(id, "out", other:AddNode("fixture.resource_out"), "in")

    self.pool.current = 900
    self:transmitBase(-1669)
    luaunit.assertEquals(self.fires, 0)
    luaunit.assertNil(other:GetLastValue(id, "current"))
end

function TestResource:testDropdownChangeKeepsTheNextPoolSilent()
    local id = self:addNode("life")
    self:transmitBase(-1669)
    self.pool.current = 900
    self:transmitBase(-1669)
    luaunit.assertEquals(self.fires, 1)

    self.graph:SetControl(id, "resource", "prayer")
    self.pool.current = 500
    self.pool.max = 5000
    self:transmitBase(3274)
    luaunit.assertEquals(self.fires, 1)

    self.pool.current = 400
    self:transmitBase(3274)
    luaunit.assertEquals(self.fires, 2)
    luaunit.assertEquals(self.graph:GetLastValue(id, "current"), 400)
    luaunit.assertEquals(self.graph:GetLastValue(id, "max"), 5000)
    luaunit.assertEquals(self.graph:GetLastValue(id, "previous"), 500)
end

function TestResource:testRunEnergyFollowsRunEnergyTransmitOnly()
    local id = self:addNode("run-energy")
    self.pool.current = 40
    self.pool.max = 100

    self:transmitBase(679)
    self:transmitBase(463)
    self:transmitBase(-20896)
    self:transmitRun()
    luaunit.assertEquals(self.fires, 0)

    self.pool.current = 120
    self:transmitBase(679)
    luaunit.assertEquals(self.fires, 0)

    self:transmitRun()
    luaunit.assertEquals(self.fires, 1)
    luaunit.assertEquals(self.graph:GetLastValue(id, "current"), 120)
    luaunit.assertEquals(self.graph:GetLastValue(id, "max"), 100)
    luaunit.assertEquals(self.graph:GetLastValue(id, "previous"), 40)
end

function TestResource:testSummoningWakesOnLorePointsVar()
    local id = self:addNode("summoning")

    self.pool.current = 30
    self.pool.max = 600
    self:transmitBase(-41525)
    self:transmitBase(4242)
    luaunit.assertEquals(self.fires, 0)

    self:transmitBase(8040)
    luaunit.assertEquals(self.fires, 0)
    self.pool.current = 20
    self:transmitBase(8040)
    luaunit.assertEquals(self.fires, 1)
    luaunit.assertEquals(self.graph:GetLastValue(id, "previous"), 30)
    luaunit.assertEquals(self.graph:GetLastValue(id, "current"), 20)
    luaunit.assertEquals(self.graph:GetLastValue(id, "max"), 600)
end

function TestResource:testAdrenalineWakesOnItsVarpOnly()
    local id = self:addNode("adrenaline")
    self.pool.current = 50
    self.pool.max = 100

    self:transmitBase(659)
    self:transmitBase(679)
    luaunit.assertEquals(self.fires, 0)

    self.pool.current = 150
    self:transmitBase(659)
    luaunit.assertEquals(self.fires, 0)

    self:transmitBase(679)
    luaunit.assertEquals(self.fires, 1)
    luaunit.assertEquals(self.graph:GetLastValue(id, "current"), 150)
    luaunit.assertEquals(self.graph:GetLastValue(id, "max"), 100)
    luaunit.assertEquals(self.graph:GetLastValue(id, "previous"), 50)
end

function TestResource:testMaxChangeAloneDoesNotFire()
    local id = self:addNode("life")
    self:transmitBase(-1669)

    self.pool.max = 1000
    self:transmitBase(-24596)
    luaunit.assertEquals(self.fires, 0)
    luaunit.assertNil(self.graph:GetLastValue(id, "current"))

    self.pool.current = 800
    self:transmitBase(-1669)
    luaunit.assertEquals(self.fires, 1)
    luaunit.assertEquals(self.graph:GetLastValue(id, "current"), 800)
    luaunit.assertEquals(self.graph:GetLastValue(id, "max"), 1000)
    luaunit.assertEquals(self.graph:GetLastValue(id, "previous"), 1000)
end

function TestResource:testFailedReadDoesNotReplaceASuccessfulSample()
    local id = self:addNode("life")
    self:transmitBase(-1669)

    self.pool.fail = true
    self.pool.current = 1
    self:transmitBase(-1669)
    luaunit.assertEquals(self.fires, 0)

    self.pool.fail = nil
    self.pool.current = 800
    self.pool.max = 9700
    self:transmitBase(-1669)
    luaunit.assertEquals(self.fires, 1)
    luaunit.assertEquals(self.graph:GetLastValue(id, "current"), 800)
    luaunit.assertEquals(self.graph:GetLastValue(id, "max"), 9700)
    luaunit.assertEquals(self.graph:GetLastValue(id, "previous"), 1000)
end

function TestResource:testLifeIgnoresRunEnergyAndUnrelatedVars()
    local id = self:addNode("life")
    self:transmitBase(-1669)

    self.pool.current = 1
    self:transmitRun()
    self:transmitBase(463)
    self:transmitBase(-20896)
    self:transmitBase(659)
    luaunit.assertEquals(self.fires, 0)

    self.pool.current = 900
    self:transmitBase(-1669)
    luaunit.assertEquals(self.fires, 1)
    luaunit.assertEquals(self.graph:GetLastValue(id, "previous"), 1000)
    luaunit.assertEquals(self.graph:GetLastValue(id, "current"), 900)
end

function TestResource:testLifeWakesOnLifepointsAndMaxLifepoints()
    local id = self:addNode("life")
    self.pool.current = 1000
    self:transmitBase(-24596)
    luaunit.assertEquals(self.fires, 0)

    self.pool.current = 700
    self:transmitBase(659)
    luaunit.assertEquals(self.fires, 0)

    self:transmitBase(-1669)
    luaunit.assertEquals(self.fires, 1)
    luaunit.assertEquals(self.graph:GetLastValue(id, "current"), 700)
    luaunit.assertEquals(self.graph:GetLastValue(id, "max"), 9900)
    luaunit.assertEquals(self.graph:GetLastValue(id, "previous"), 1000)
end

function TestResource:testDropdownChangeKeepsOutputWires()
    local id = self:addNode("life")
    self.registry:RegisterNodeType("fixture.resource_numbers", {
        category = "action",
        pins = {
            { name = "current", kind = "data", direction = "in", dataType = "number" },
            { name = "max", kind = "data", direction = "in", dataType = "number" },
            { name = "previous", kind = "data", direction = "in", dataType = "number" },
        },
        run = function() end,
    })
    local sink = self.graph:AddNode("fixture.resource_numbers")
    self.graph:Connect(id, "current", sink, "current")
    self.graph:Connect(id, "max", sink, "max")
    self.graph:Connect(id, "previous", sink, "previous")

    self.graph:SetControl(id, "resource", "summoning")

    local found = { current = false, max = false, previous = false, out = false }
    for _, conn in ipairs(self.graph:GetConnections()) do
        if conn.fromNode == id and found[conn.fromPin] ~= nil then
            found[conn.fromPin] = true
        end
    end
    luaunit.assertTrue(found.current)
    luaunit.assertTrue(found.max)
    luaunit.assertTrue(found.previous)
    luaunit.assertTrue(found.out)
end

function TestResource:testEachNodeSamplesOnItsOwn()
    local first = self:addNode("life")
    local second = self:addNode("prayer")
    self:transmitBase(-1669)
    self:transmitBase(3274)

    self.pool.current = 800
    self:transmitBase(3274)
    luaunit.assertEquals(self.fires, 1)
    luaunit.assertEquals(self.graph:GetLastValue(second, "previous"), 1000)
    luaunit.assertNil(self.graph:GetLastValue(first, "current"))

    self.pool.current = 700
    self:transmitBase(-1669)
    luaunit.assertEquals(self.fires, 2)
    luaunit.assertEquals(self.graph:GetLastValue(first, "current"), 700)
    luaunit.assertEquals(self.graph:GetLastValue(first, "previous"), 1000)
end

-- Stubs the client and leaves the production reader in place, so a wrong var id
-- or scale shows up as the wrong current/max rather than as a call count.
function TestResource:testProductionPoolsMatchTheSpecifiedSources()
    Resource.SetReader(nil)
    self.savedVar = var
    self.restoreVar = true
    self.savedPlayer = Player
    self.restorePlayer = true

    local values = {
        [-1669] = 8500,
        [-24596] = 9900,
        -- Prayer stores tenths. 6400 on the var is 640 points on the bar.
        [-16737] = 6400,
        -- Summoning stores tenths. 2500 on the var is 250 points on the bar.
        [-41525] = 2500,
        [679] = 1500,
    }
    local levels = { [5] = 70, [23] = 40 }
    if type(SkillType) == "table" then
        if type(SkillType.PRAYER) == "number" then levels[SkillType.PRAYER] = 70 end
        if type(SkillType.SUMMONING) == "number" then levels[SkillType.SUMMONING] = 40 end
    end
    Player = {
        GetLevelGameplay = function(skill) return levels[skill] end,
        GetRunEnergy = function() return 137 end,
    }
    var = {
        VarPlayer = {
            FromID = function(id)
                local value = values[id]
                if value == nil then return nil end
                return { id = id, value = value }
            end,
        },
    }

    local life = self:addNode("life")
    self:transmitBase(-1669)
    values[-1669] = 8400
    self:transmitBase(-1669)
    luaunit.assertEquals(self.graph:GetLastValue(life, "current"), 8400)
    luaunit.assertEquals(self.graph:GetLastValue(life, "max"), 9900)
    luaunit.assertEquals(self.graph:GetLastValue(life, "previous"), 8500)

    local prayer = self:addNode("prayer")
    self:transmitBase(3274)
    values[-16737] = 6000
    self:transmitBase(3274)
    luaunit.assertEquals(self.graph:GetLastValue(prayer, "current"), 600)
    luaunit.assertEquals(self.graph:GetLastValue(prayer, "max"), 700)
    luaunit.assertEquals(self.graph:GetLastValue(prayer, "previous"), 640)

    local summoning = self:addNode("summoning")
    self:transmitBase(8040)
    values[-41525] = 2000
    self:transmitBase(8040)
    luaunit.assertEquals(self.graph:GetLastValue(summoning, "current"), 200)
    luaunit.assertEquals(self.graph:GetLastValue(summoning, "max"), 400)
    luaunit.assertEquals(self.graph:GetLastValue(summoning, "previous"), 250)

    local adrenaline = self:addNode("adrenaline")
    self:transmitBase(679)
    values[679] = 800
    self:transmitBase(679)
    luaunit.assertEquals(self.graph:GetLastValue(adrenaline, "current"), 80)
    luaunit.assertEquals(self.graph:GetLastValue(adrenaline, "max"), 100)
    luaunit.assertEquals(self.graph:GetLastValue(adrenaline, "previous"), 150)

    values[-46760] = 100
    values[-51565] = 3
    values[679] = 900
    self:transmitBase(679)
    luaunit.assertEquals(self.graph:GetLastValue(adrenaline, "current"), 90)
    luaunit.assertEquals(self.graph:GetLastValue(adrenaline, "max"), 110)

    values[-51565] = 4
    values[679] = 1000
    self:transmitBase(679)
    luaunit.assertEquals(self.graph:GetLastValue(adrenaline, "current"), 100)
    luaunit.assertEquals(self.graph:GetLastValue(adrenaline, "max"), 130)
    luaunit.assertEquals(self.graph:GetLastValue(adrenaline, "previous"), 90)

    local run = self:addNode("run-energy")
    self:transmitRun()
    Player.GetRunEnergy = function() return 90 end
    self:transmitRun()
    luaunit.assertEquals(self.graph:GetLastValue(run, "current"), 90)
    luaunit.assertEquals(self.graph:GetLastValue(run, "max"), 100)
    luaunit.assertEquals(self.graph:GetLastValue(run, "previous"), 137)
end

-- A later VarTransmit binding receives the same event table. Resource Changed
-- reports current, max, and previous on its own node and leaves that table alone.
function TestResource:testLaterVarTransmitListenerDoesNotSeeResourceFields()
    local id = self:addNode("life")
    self.registry:RegisterNodeType("fixture.var_listener", {
        category = "trigger",
        pins = {
            { name = "out", kind = "exec", direction = "out" },
            { name = "event", kind = "data", direction = "out", dataType = "any" },
        },
        run = function(ctx)
            ctx:Out("event", ctx.payload)
            ctx:Fire("out")
        end,
    })
    self.runtime:BindTrigger("fixture.var_listener", { { event = "VarTransmit" } })
    local listener = self.graph:AddNode("fixture.var_listener")

    self:transmitBase(-1669)
    self.pool.current = 900
    self.pool.max = 9800
    self:transmitBase(-1669)

    luaunit.assertEquals(self.graph:GetLastValue(id, "current"), 900)
    luaunit.assertEquals(self.graph:GetLastValue(id, "max"), 9800)
    luaunit.assertEquals(self.graph:GetLastValue(id, "previous"), 1000)
    local event = self.graph:GetLastValue(listener, "event")
    luaunit.assertEquals(event.var.id, -1669)
    luaunit.assertNil(event.current)
    luaunit.assertNil(event.max)
    luaunit.assertNil(event.previous)
end

function TestResource:testNewNodeDefaultsToLifePoints()
    local id = self.graph:AddNode("trigger.resource_changed")
    luaunit.assertEquals(self.graph:GetControl(id, "resource"), "life")
    local nodeType = self.registry:GetNodeType("trigger.resource_changed")
    luaunit.assertEquals(nodeType.category, "trigger")
    luaunit.assertEquals(nodeType.displayName, "Resource Changed")
    luaunit.assertEquals(nodeType.key, "trigger.resource_changed")
end

return TestResource
