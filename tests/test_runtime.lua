-- Exercises runtime.lua's dispatcher through its one seam: an injected fake event source
-- (fake_event_source.lua) standing in for the client `Event` global. Feeds raw events
-- synchronously and asserts which node fires, with what payload, and in what order the
-- transform -> filter -> run pipeline runs (#24 acceptance criteria).

local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local Runtime = require("runtime")
local newFakeEventSource = require("fake_event_source")

TestRuntime = {}

function TestRuntime:setUp()
    self.registry = Registry.new()
    self.source = newFakeEventSource()
    self.runtime = Runtime.new(self.source.source)
    self.graph = Graph.new(self.registry)
    self.runtime:SetGraph(self.graph)
end

-- A trigger fixture that republishes ctx.payload on a data pin so tests can read what a
-- Fire actually carried via graph:GetLastValue, since downstream nodes never see the payload.
local function registerEchoTrigger(registry, typeKey)
    registry:RegisterNodeType(typeKey, {
        category = "trigger",
        pins = {
            { name = "out", kind = "exec", direction = "out" },
            { name = "payload", kind = "data", direction = "out", dataType = "any" },
        },
        run = function(ctx)
            ctx:Out("payload", ctx.payload)
            ctx:Fire("out")
        end,
    })
end

--- BindTrigger / subscription plumbing --------------------------------------------------

function TestRuntime:testBindTriggerSubscribesChannelExactlyOnce()
    registerEchoTrigger(self.registry, "fixture.echo")
    self.runtime:BindTrigger("fixture.echo", { { event = "Custom" } })

    self.graph:AddNode("fixture.echo")
    self.graph:AddNode("fixture.echo")
    self.graph:AddNode("fixture.echo")

    self.source:Push("Custom", "ping")

    luaunit.assertEquals(self.source:SubscribeCount("Custom"), 1)
end

function TestRuntime:testMultipleTypeKeysOnSameChannelShareOneSubscription()
    registerEchoTrigger(self.registry, "fixture.echoA")
    registerEchoTrigger(self.registry, "fixture.echoB")
    self.runtime:BindTrigger("fixture.echoA", { { event = "Shared" } })
    self.runtime:BindTrigger("fixture.echoB", { { event = "Shared" } })

    local aId = self.graph:AddNode("fixture.echoA")
    local bId = self.graph:AddNode("fixture.echoB")

    self.source:Push("Shared", "x")

    luaunit.assertEquals(self.source:SubscribeCount("Shared"), 1)
    luaunit.assertEquals(self.graph:GetLastValue(aId, "payload"), "x")
    luaunit.assertEquals(self.graph:GetLastValue(bId, "payload"), "x")
end

function TestRuntime:testOnlyBoundTypeKeyFires()
    registerEchoTrigger(self.registry, "fixture.echoA")
    registerEchoTrigger(self.registry, "fixture.echoB")
    self.runtime:BindTrigger("fixture.echoA", { { event = "OnlyA" } })

    local aId = self.graph:AddNode("fixture.echoA")
    local bId = self.graph:AddNode("fixture.echoB")

    self.source:Push("OnlyA", "hit")

    luaunit.assertEquals(self.graph:GetLastValue(aId, "payload"), "hit")
    luaunit.assertNil(self.graph:GetLastValue(bId, "payload"))
end

--- transform -> filter -> run order and identity default ---------------------------------

function TestRuntime:testIdentityPayloadWhenTransformOmitted()
    registerEchoTrigger(self.registry, "fixture.echo")
    self.runtime:BindTrigger("fixture.echo", { { event = "Raw" } })
    local nodeId = self.graph:AddNode("fixture.echo")

    self.source:Push("Raw", { chatMessage = "hello" })

    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "payload"), { chatMessage = "hello" })
end

-- Registers a trigger whose run() records "run" into `order` and republishes ctx.payload on
-- the `value` pin — shared by the two order/gating tests below, which each supply their own
-- `order` table and transform/filter pair to bind against it.
local function registerPipedTrigger(registry, order)
    registry:RegisterNodeType("fixture.piped", {
        category = "trigger",
        pins = {
            { name = "out", kind = "exec", direction = "out" },
            { name = "value", kind = "data", direction = "out", dataType = "any" },
        },
        run = function(ctx)
            table.insert(order, "run")
            ctx:Out("value", ctx.payload)
            ctx:Fire("out")
        end,
    })
end

function TestRuntime:testTransformFilterRunOrderAndShapedPayload()
    local order = {}
    registerPipedTrigger(self.registry, order)

    self.runtime:BindTrigger("fixture.piped", {
        {
            event = "Custom",
            transform = function(raw)
                table.insert(order, "transform")
                return raw.value * 2
            end,
            filter = function(payload)
                table.insert(order, "filter")
                return payload > 0
            end,
        },
    })

    local nodeId = self.graph:AddNode("fixture.piped")
    self.source:Push("Custom", { value = 5 })

    luaunit.assertEquals(order, { "transform", "filter", "run" })
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "value"), 10)
end

function TestRuntime:testFilterFalseBlocksRun()
    local order = {}
    registerPipedTrigger(self.registry, order)

    self.runtime:BindTrigger("fixture.piped", {
        {
            event = "Custom",
            transform = function(raw)
                table.insert(order, "transform")
                return raw.value * 2
            end,
            filter = function(payload)
                table.insert(order, "filter")
                return payload > 0
            end,
        },
    })

    local nodeId = self.graph:AddNode("fixture.piped")
    self.source:Push("Custom", { value = -1 })

    luaunit.assertEquals(order, { "transform", "filter" })
    luaunit.assertNil(self.graph:GetLastValue(nodeId, "value"))
end

function TestRuntime:testFilterCanSourceMatchByNodeControl()
    -- Simulates a multi-source node's filter reading its own control to pick which
    -- payloads it cares about (the "no universal discriminator field" case from #23).
    self.registry:RegisterNodeType("fixture.selective", {
        category = "trigger",
        pins = {
            { name = "source", kind = "data", direction = "in", dataType = "string", default = "any" },
            { name = "out", kind = "exec", direction = "out" },
            { name = "value", kind = "data", direction = "out", dataType = "any" },
        },
        run = function(ctx)
            ctx:Out("value", ctx.payload.value)
            ctx:Fire("out")
        end,
    })

    self.runtime:BindTrigger("fixture.selective", {
        {
            event = "Multi",
            filter = function(payload, node)
                local wanted = node.GetControl("source")
                return wanted == "any" or wanted == payload.source
            end,
        },
    })

    local anyId = self.graph:AddNode("fixture.selective", { source = "any" })
    local npcId = self.graph:AddNode("fixture.selective", { source = "npc" })
    local objId = self.graph:AddNode("fixture.selective", { source = "obj" })

    self.source:Push("Multi", { source = "npc", value = 42 })

    luaunit.assertEquals(self.graph:GetLastValue(anyId, "value"), 42)
    luaunit.assertEquals(self.graph:GetLastValue(npcId, "value"), 42)
    luaunit.assertNil(self.graph:GetLastValue(objId, "value"))
end

function TestRuntime:testTransformComputedOnceRegardlessOfNodeCount()
    local transformCalls = 0
    registerEchoTrigger(self.registry, "fixture.echo")
    self.runtime:BindTrigger("fixture.echo", {
        {
            event = "Custom",
            transform = function(raw)
                transformCalls = transformCalls + 1
                return raw
            end,
        },
    })

    self.graph:AddNode("fixture.echo")
    self.graph:AddNode("fixture.echo")
    self.graph:AddNode("fixture.echo")

    self.source:Push("Custom", "x")

    luaunit.assertEquals(transformCalls, 1)
end

--- Injectable event source + Stop ---------------------------------------------------------

function TestRuntime:testEventSourceIsInjectedNotGlobal()
    -- No global `Event` exists under the standalone interpreter; construction and dispatch
    -- via the injected fake must not touch it.
    luaunit.assertNil(_G.Event)
    registerEchoTrigger(self.registry, "fixture.echo")
    self.runtime:BindTrigger("fixture.echo", { { event = "Custom" } })
    local nodeId = self.graph:AddNode("fixture.echo")
    self.source:Push("Custom", "ok")
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "payload"), "ok")
end

--- Activity ticks (runtime.keyboardActivityTick / runtime.mouseActivityTick, #29) -----------

function TestRuntime:testKeyboardActivityTickStartsAtZero()
    luaunit.assertEquals(self.runtime.keyboardActivityTick, 0)
end

function TestRuntime:testKeyboardActivityTickIncrementsOnKeyDown()
    self.source:Push("KeyDown", { gameKey = "F8", isRepeat = false })
    luaunit.assertEquals(self.runtime.keyboardActivityTick, 1)

    self.source:Push("KeyDown", { gameKey = "A", isRepeat = false })
    luaunit.assertEquals(self.runtime.keyboardActivityTick, 2)
end

function TestRuntime:testKeyboardActivityTickSurvivesStop()
    self.source:Push("KeyDown", { gameKey = "F8", isRepeat = false })
    self.runtime:Stop()
    -- Stop unsubscribes the dispatcher's own channels; the tick value itself must persist
    -- (it's just a counter, not a live subscription).
    luaunit.assertEquals(self.runtime.keyboardActivityTick, 1)
end

-- A fake `Mouse` global stand-in: `pos` is mutated by the test between Update() calls to
-- simulate movement; `available` lets a test simulate Mouse.IsAvailable() == false (mobile).
local function newFakeMouse(x, y)
    local mouse = { available = true, pos = { x = x, y = y } }
    function mouse.IsAvailable() return mouse.available end
    function mouse.GetPosition() return mouse.pos end
    return mouse
end

function TestRuntime:testMouseActivityTickStartsAtZero()
    local runtime = Runtime.new(self.source.source, newFakeMouse(0, 0))
    luaunit.assertEquals(runtime.mouseActivityTick, 0)
end

function TestRuntime:testMouseActivityTickIncrementsOnPositionChange()
    local mouse = newFakeMouse(10, 10)
    local runtime = Runtime.new(self.source.source, mouse)

    runtime:Update(1) -- first poll just establishes the baseline position
    luaunit.assertEquals(runtime.mouseActivityTick, 0)

    mouse.pos = { x = 11, y = 10 }
    runtime:Update(1)
    luaunit.assertEquals(runtime.mouseActivityTick, 1)

    runtime:Update(1) -- unchanged position: no further tick
    luaunit.assertEquals(runtime.mouseActivityTick, 1)
end

function TestRuntime:testMouseActivityTickIgnoredWhenMouseUnavailable()
    local mouse = newFakeMouse(0, 0)
    mouse.available = false
    local runtime = Runtime.new(self.source.source, mouse)

    runtime:Update(1)
    mouse.pos = { x = 99, y = 99 }
    runtime:Update(1)

    luaunit.assertEquals(runtime.mouseActivityTick, 0)
end

function TestRuntime:testStopUnsubscribesAllChannels()
    registerEchoTrigger(self.registry, "fixture.echo")
    self.runtime:BindTrigger("fixture.echo", { { event = "Custom" } })
    local nodeId = self.graph:AddNode("fixture.echo")

    self.source:Push("Custom", "first")
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "payload"), "first")

    self.runtime:Stop()
    self.source:Push("Custom", "second")

    -- Unchanged since Stop — the dispatcher never saw the second push.
    luaunit.assertEquals(self.graph:GetLastValue(nodeId, "payload"), "first")
end

return TestRuntime
