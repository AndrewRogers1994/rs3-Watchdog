-- Exercises the poll-binding path in runtime.lua: a `{ kind = "poll", event = "Logic" }`
-- binding riding the same `transform -> filter` dispatch pipeline plus an edge-detection gate
-- (#28). Per tick, `transform` samples shared world state once, `filter(payload, node)` is the
-- per-node predicate, and the gate fires the node's `Enter`/`Leave` exec pin only on the
-- transition of that predicate. Edge state lives in the runtime (`pollEdgeState`), is never
-- serialized, and starts false. A nil sample skips the tick and freezes edge state.
--
-- Everything is driven through the same injected fake event source (fake_event_source.lua) the
-- event-driven runtime tests use, feeding raw `Logic` events synchronously.

local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local Runtime = require("runtime")
local newFakeEventSource = require("fake_event_source")

TestPoll = {}

function TestPoll:setUp()
    self.registry = Registry.new()
    self.source = newFakeEventSource()
    self.runtime = Runtime.new(self.source.source)
    self.graph = Graph.new(self.registry)
    self.runtime:SetGraph(self.graph)
end

-- A fixture poll node standing in for the real Location node (which lands separately). Its
-- run only fires the resolved edge pin the dispatcher handed it (ctx.payload.edge) and records
-- `{ edge, sample }` into `log` so a test can read the exact sequence of edges the gate decided.
-- It declares both `Enter` and `Leave` exec outputs; the `target` control lets the binding's
-- filter source-match per node.
local function registerPollFixture(registry, log)
    registry:RegisterNodeType("fixture.poll", {
        category = "trigger",
        pins = {
            { name = "target", kind = "data", direction = "in", dataType = "number", default = 0 },
            { name = "Enter", kind = "exec", direction = "out" },
            { name = "Leave", kind = "exec", direction = "out" },
        },
        run = function(ctx)
            log[#log + 1] = { edge = ctx.payload.edge, sample = ctx.payload.sample }
            ctx:Fire(ctx.payload.edge)
        end,
    })
end

-- A downstream action that counts how many times it ran, keyed by the exec input it entered
-- through — lets a test prove an edge pin actually propagates to wired targets (and that an
-- unwired pin is a no-op).
local function registerCounter(registry, counts)
    registry:RegisterNodeType("fixture.counter", {
        category = "action",
        pins = { { name = "in", kind = "exec", direction = "in" } },
        run = function(ctx) counts.n = (counts.n or 0) + 1 end,
    })
end

-- Binds the poll fixture to the Logic channel: transform samples `raw.sample` (nil when the raw
-- event carries none — the "logged out / source unreadable" case), filter is the per-node
-- predicate `sample >= target`.
local function bindPoll(runtime)
    runtime:BindTrigger("fixture.poll", {
        {
            kind = "poll",
            event = "Logic",
            transform = function(raw)
                return raw ~= nil and raw.sample or nil
            end,
            filter = function(sample, node)
                return sample >= node.GetControl("target")
            end,
        },
    })
end

-- Pushes one Logic tick carrying `sample` (nil ⇒ unreadable source).
function TestPoll:tick(sample)
    self.source:Push("Logic", { sample = sample })
end

--- Enter / Leave edge semantics ----------------------------------------------------------

function TestPoll:testEnterFiresOnceOnFalseToTrue()
    local log = {}
    registerPollFixture(self.registry, log)
    bindPoll(self.runtime)
    self.graph:AddNode("fixture.poll", { target = 5 })

    self:tick(1) -- below: predicate false, no edge
    luaunit.assertEquals(#log, 0)

    self:tick(7) -- false -> true: Enter
    luaunit.assertEquals(#log, 1)
    luaunit.assertEquals(log[1].edge, "Enter")
    luaunit.assertEquals(log[1].sample, 7)
end

function TestPoll:testNoReEnterWhilePredicateStaysTrue()
    local log = {}
    registerPollFixture(self.registry, log)
    bindPoll(self.runtime)
    self.graph:AddNode("fixture.poll", { target = 5 })

    self:tick(7) -- Enter
    self:tick(8) -- still true: no edge
    self:tick(9) -- still true: no edge

    luaunit.assertEquals(#log, 1)
    luaunit.assertEquals(log[1].edge, "Enter")
end

function TestPoll:testLeaveFiresOnTrueToFalse()
    local log = {}
    registerPollFixture(self.registry, log)
    bindPoll(self.runtime)
    self.graph:AddNode("fixture.poll", { target = 5 })

    self:tick(7) -- Enter
    self:tick(2) -- true -> false: Leave

    luaunit.assertEquals(#log, 2)
    luaunit.assertEquals(log[1].edge, "Enter")
    luaunit.assertEquals(log[2].edge, "Leave")
    luaunit.assertEquals(log[2].sample, 2)
end

function TestPoll:testEnterLeaveEnterCycles()
    local log = {}
    registerPollFixture(self.registry, log)
    bindPoll(self.runtime)
    self.graph:AddNode("fixture.poll", { target = 5 })

    self:tick(7) -- Enter
    self:tick(1) -- Leave
    self:tick(9) -- Enter again

    luaunit.assertEquals(#log, 3)
    luaunit.assertEquals(log[1].edge, "Enter")
    luaunit.assertEquals(log[2].edge, "Leave")
    luaunit.assertEquals(log[3].edge, "Enter")
end

function TestPoll:testInitialStateFalseSoAlreadyTrueAtLoadFiresEnter()
    -- No priming tick: the very first sample is already above target. Initial edge state is
    -- false, so this first-ever poll is a false->true transition and fires Enter.
    local log = {}
    registerPollFixture(self.registry, log)
    bindPoll(self.runtime)
    self.graph:AddNode("fixture.poll", { target = 5 })

    self:tick(10)

    luaunit.assertEquals(#log, 1)
    luaunit.assertEquals(log[1].edge, "Enter")
end

--- nil sample: skip the tick and freeze edge state ---------------------------------------

function TestPoll:testNilSampleSkipsTickEntirely()
    local log = {}
    registerPollFixture(self.registry, log)
    bindPoll(self.runtime)
    self.graph:AddNode("fixture.poll", { target = 5 })

    self:tick(nil) -- source unreadable: no filter, no edge
    luaunit.assertEquals(#log, 0)
end

function TestPoll:testNilSampleFreezesStateNoSpuriousLeave()
    -- In-area (true), then the source goes unreadable (logged out): the nil tick must NOT
    -- produce a Leave, and coming back with the same in-area state must NOT re-fire Enter.
    local log = {}
    registerPollFixture(self.registry, log)
    bindPoll(self.runtime)
    self.graph:AddNode("fixture.poll", { target = 5 })

    self:tick(7)   -- Enter
    self:tick(nil) -- logged out: skip + freeze (no Leave)
    self:tick(nil)
    self:tick(8)   -- relog, still in-area: no re-Enter (frozen state was already true)

    luaunit.assertEquals(#log, 1)
    luaunit.assertEquals(log[1].edge, "Enter")
end

function TestPoll:testRealTransitionAfterNilStillFires()
    -- Freezing during nil must not suppress a genuine transition once the source returns:
    -- in-area -> unreadable -> out-of-area fires Leave (a real true->false change).
    local log = {}
    registerPollFixture(self.registry, log)
    bindPoll(self.runtime)
    self.graph:AddNode("fixture.poll", { target = 5 })

    self:tick(7)   -- Enter
    self:tick(nil) -- freeze at true
    self:tick(1)   -- now genuinely out-of-area: Leave

    luaunit.assertEquals(#log, 2)
    luaunit.assertEquals(log[2].edge, "Leave")
end

function TestPoll:testFilterErrorFreezesThatNodesEdge()
    -- A per-node filter that *errors* (a broken predicate, distinct from a nil sample) must
    -- freeze that node's edge like a nil tick would — no spurious Leave, no re-Enter — so a bug
    -- in one node's predicate can't manufacture phantom transitions.
    local log = {}
    registerPollFixture(self.registry, log)
    self.runtime:BindTrigger("fixture.poll", {
        {
            kind = "poll",
            event = "Logic",
            transform = function(raw) return raw.sample end,
            filter = function(sample)
                if sample == 0 then error("broken read") end
                return sample >= 5
            end,
        },
    })
    self.graph:AddNode("fixture.poll", { target = 5 })

    self:tick(7) -- Enter
    self:tick(0) -- filter errors: freeze at true, no Leave
    luaunit.assertEquals(#log, 1)

    self:tick(8) -- still in-area: no re-Enter (state frozen at true)
    luaunit.assertEquals(#log, 1)

    self:tick(1) -- genuine exit once the filter works again: Leave
    luaunit.assertEquals(#log, 2)
    luaunit.assertEquals(log[2].edge, "Leave")
end

--- Batching: transform once per tick, filter per node ------------------------------------

function TestPoll:testTransformRunsOncePerTickRegardlessOfNodeCount()
    local log = {}
    registerPollFixture(self.registry, log)
    local transformCalls, filterCalls = 0, 0
    self.runtime:BindTrigger("fixture.poll", {
        {
            kind = "poll",
            event = "Logic",
            transform = function(raw)
                transformCalls = transformCalls + 1
                return raw.sample
            end,
            filter = function(sample, node)
                filterCalls = filterCalls + 1
                return sample >= node.GetControl("target")
            end,
        },
    })

    self.graph:AddNode("fixture.poll", { target = 5 })
    self.graph:AddNode("fixture.poll", { target = 5 })
    self.graph:AddNode("fixture.poll", { target = 5 })

    self:tick(7)

    luaunit.assertEquals(transformCalls, 1) -- sampled once for the whole tick
    luaunit.assertEquals(filterCalls, 3)    -- predicate evaluated per node
end

function TestPoll:testEachNodeKeepsItsOwnEdgeState()
    local log = {}
    registerPollFixture(self.registry, log)
    bindPoll(self.runtime)
    self.graph:AddNode("fixture.poll", { target = 3 })
    self.graph:AddNode("fixture.poll", { target = 8 })

    -- sample 5: crosses node A's target (3) but not node B's (8) -> only A Enters.
    self:tick(5)

    luaunit.assertEquals(#log, 1)
    luaunit.assertEquals(log[1].edge, "Enter")

    -- sample 9: now crosses B too -> B Enters (A already true, no re-fire).
    self:tick(9)
    luaunit.assertEquals(#log, 2)
    luaunit.assertEquals(log[2].edge, "Enter")
end

function TestPoll:testEdgeStateIsolatedAcrossAlertsWithSameNodeId()
    -- Node ids are only unique within a graph, so two alerts each hold a poll node with the
    -- same id. Their edge state must not collide: disabling A's fire must not leak into B.
    local log = {}
    registerPollFixture(self.registry, log)
    bindPoll(self.runtime)

    local graphA = Graph.new(self.registry)
    local graphB = Graph.new(self.registry)
    self.runtime:SetGraph(nil)
    self.runtime:AddAlert("A", graphA, true)
    self.runtime:AddAlert("B", graphB, true)
    local aId = graphA:AddNode("fixture.poll", { target = 5 })
    local bId = graphB:AddNode("fixture.poll", { target = 5 })
    luaunit.assertEquals(aId, bId) -- same id across the two graphs

    self:tick(7) -- both cross: both Enter, independently

    luaunit.assertEquals(#log, 2)
    luaunit.assertEquals(log[1].edge, "Enter")
    luaunit.assertEquals(log[2].edge, "Enter")

    -- Second tick, still true for both: neither re-fires (each graph's state tracked apart).
    self:tick(8)
    luaunit.assertEquals(#log, 2)
end

--- Edge pins propagate downstream (and unwired pins are no-ops) --------------------------

function TestPoll:testEnterPinPropagatesToWiredTargetLeaveDoesNotWhenUnwired()
    local log = {}
    registerPollFixture(self.registry, log)
    local counts = {}
    registerCounter(self.registry, counts)
    bindPoll(self.runtime)

    local pollId = self.graph:AddNode("fixture.poll", { target = 5 })
    local counterId = self.graph:AddNode("fixture.counter")
    -- Wire only Enter -> counter; Leave stays unwired.
    self.graph:Connect(pollId, "Enter", counterId, "in")

    self:tick(7) -- Enter: counter runs
    luaunit.assertEquals(counts.n, 1)

    self:tick(1) -- Leave: dispatcher fires Leave but it's unwired -> counter unchanged
    luaunit.assertEquals(counts.n, 1)
    luaunit.assertEquals(log[2].edge, "Leave") -- the gate still decided Leave
end

function TestPoll:testLeavePinPropagatesToWiredTarget()
    local log = {}
    registerPollFixture(self.registry, log)
    local counts = {}
    registerCounter(self.registry, counts)
    bindPoll(self.runtime)

    local pollId = self.graph:AddNode("fixture.poll", { target = 5 })
    local counterId = self.graph:AddNode("fixture.counter")
    self.graph:Connect(pollId, "Leave", counterId, "in")

    self:tick(7) -- Enter (unwired here): counter not run
    luaunit.assertNil(counts.n)

    self:tick(1) -- Leave -> counter runs
    luaunit.assertEquals(counts.n, 1)
end

--- Event-driven bindings are unaffected (no edge state) ----------------------------------

function TestPoll:testEventBindingFiresEveryPassWithNoEdgeGate()
    -- A plain (non-poll) binding on the same dispatcher fires on *every* filter pass, with no
    -- edge state — proving edge detection is poll-only.
    local runs = {}
    self.registry:RegisterNodeType("fixture.event", {
        category = "trigger",
        pins = { { name = "out", kind = "exec", direction = "out" } },
        run = function(ctx)
            runs[#runs + 1] = ctx.payload
            ctx:Fire("out")
        end,
    })
    self.runtime:BindTrigger("fixture.event", {
        { event = "Custom", filter = function(payload) return payload > 0 end },
    })
    self.graph:AddNode("fixture.event")

    self.source:Push("Custom", 5)
    self.source:Push("Custom", 6) -- same truthy predicate, still fires (no edge suppression)
    self.source:Push("Custom", 7)

    luaunit.assertEquals(runs, { 5, 6, 7 })
end

return TestPoll
