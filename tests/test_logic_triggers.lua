-- Clock triggers (#52) through Registry + Graph + Runtime.new(fakeEventSource). Nothing
-- hand-builds a ctx - interval-gating in `run` and ctx.state are observed through the engine.

local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local Runtime = require("src/runtime")
local newFakeEventSource = require("fake_event_source")
local Logic = require("src/nodes/triggers/logic")

TestLogicTriggers = {}

function TestLogicTriggers:setUp()
    self.registry = Registry.new()
    self.source = newFakeEventSource()
    self.runtime = Runtime.new(self.source.source)
    self.graph = Graph.new(self.registry)
    self.runtime:SetGraph(self.graph)

    Logic.Register(self.registry, self.runtime)

    self.log = {}
    self.registry:RegisterNodeType("fixture.mark", {
        category = "action",
        pins = { { name = "in", kind = "exec", direction = "in", terminates = true } },
        run = function() table.insert(self.log, #self.log + 1) end,
    })
end

function TestLogicTriggers:markInto(nodeId)
    local markId = self.graph:AddNode("fixture.mark")
    self.graph:Connect(nodeId, "out", markId, "in")
    return markId
end

-- Pushes N Logic events, each carrying an incrementing logicTick count starting at 1.
function TestLogicTriggers:pushLogic(n)
    for i = 1, n do
        self.source:Push("Logic", { logicTick = i })
    end
end

function TestLogicTriggers:testClientTickIntervalOneFiresEveryPush()
    local id = self.graph:AddNode("trigger.logic", { interval = 1 })
    self:markInto(id)

    self:pushLogic(5)

    luaunit.assertEquals(#self.log, 5)
end

function TestLogicTriggers:testClientTickIntervalKFiresFloorNOverK()
    local id = self.graph:AddNode("trigger.logic", { interval = 3 })
    self:markInto(id)

    self:pushLogic(10)   -- fires on tick 3, 6, 9 -> floor(10/3) == 3

    luaunit.assertEquals(#self.log, 3)
end

function TestLogicTriggers:testClientTickZeroIntervalFiresEveryTick()
    local id = self.graph:AddNode("trigger.logic", { interval = 0 })
    self:markInto(id)

    self:pushLogic(4)

    luaunit.assertEquals(#self.log, 4)
end

function TestLogicTriggers:testClientTickNegativeIntervalFiresEveryTick()
    local id = self.graph:AddNode("trigger.logic", { interval = -5 })
    self:markInto(id)

    self:pushLogic(4)

    luaunit.assertEquals(#self.log, 4)
end

function TestLogicTriggers:testClientTickFractionalIntervalFiresEveryTick()
    -- floor(0.5) == 0, clamped up to 1 -> every tick.
    local id = self.graph:AddNode("trigger.logic", { interval = 0.5 })
    self:markInto(id)

    self:pushLogic(4)

    luaunit.assertEquals(#self.log, 4)
end

function TestLogicTriggers:testClientTickEmitsLogicTickFromPayload()
    local id = self.graph:AddNode("trigger.logic", { interval = 1 })
    self:markInto(id)

    self.source:Push("Logic", { logicTick = 42 })

    luaunit.assertEquals(self.graph:GetLastValue(id, "logicTick"), 42)
end

function TestLogicTriggers:testClientTickLogicTickReflectsFiringTickNotSkipped()
    local id = self.graph:AddNode("trigger.logic", { interval = 2 })
    self:markInto(id)

    -- Pushes at tick counts 100 (skipped) then 200 (fires): the output holds the firing
    -- push's count, unaffected by the interval throttle.
    self.source:Push("Logic", { logicTick = 100 })
    luaunit.assertNil(self.graph:GetLastValue(id, "logicTick"))
    self.source:Push("Logic", { logicTick = 200 })
    luaunit.assertEquals(self.graph:GetLastValue(id, "logicTick"), 200)
end

function TestLogicTriggers:testServerTickFiresWithNoPayloadAndHonoursInterval()
    local id = self.graph:AddNode("trigger.server_logic", { interval = 2 })
    self:markInto(id)

    for _ = 1, 6 do
        self.source:Push("ServerLogic")   -- ServerLogic carries no payload
    end

    luaunit.assertEquals(#self.log, 3)
end

function TestLogicTriggers:testServerTickExposesNoLogicTick()
    local id = self.graph:AddNode("trigger.server_logic", { interval = 1 })
    self:markInto(id)

    self.source:Push("ServerLogic")

    luaunit.assertNil(self.graph:GetLastValue(id, "logicTick"))
end

function TestLogicTriggers:testTwoClientTicksKeepIndependentCadence()
    local fastId = self.graph:AddNode("trigger.logic", { interval = 1 })
    local slowId = self.graph:AddNode("trigger.logic", { interval = 5 })
    local fastLog, slowLog = {}, {}
    self.registry:RegisterNodeType("fixture.markFast", {
        category = "action",
        pins = { { name = "in", kind = "exec", direction = "in", terminates = true } },
        run = function() table.insert(fastLog, 1) end,
    })
    self.registry:RegisterNodeType("fixture.markSlow", {
        category = "action",
        pins = { { name = "in", kind = "exec", direction = "in", terminates = true } },
        run = function() table.insert(slowLog, 1) end,
    })
    local fastMark = self.graph:AddNode("fixture.markFast")
    local slowMark = self.graph:AddNode("fixture.markSlow")
    self.graph:Connect(fastId, "out", fastMark, "in")
    self.graph:Connect(slowId, "out", slowMark, "in")

    self:pushLogic(10)

    luaunit.assertEquals(#fastLog, 10)
    luaunit.assertEquals(#slowLog, 2)
end

function TestLogicTriggers:testNTickNodesCostExactlyOneSubscriptionPerChannel()
    self.graph:AddNode("trigger.logic", { interval = 1 })
    self.graph:AddNode("trigger.logic", { interval = 7 })
    self.graph:AddNode("trigger.server_logic", { interval = 1 })
    self.graph:AddNode("trigger.server_logic", { interval = 3 })

    self.source:Push("Logic", { logicTick = 1 })
    self.source:Push("ServerLogic")

    luaunit.assertEquals(self.source:SubscribeCount("Logic"), 1)
    luaunit.assertEquals(self.source:SubscribeCount("ServerLogic"), 1)
end

return TestLogicTriggers
