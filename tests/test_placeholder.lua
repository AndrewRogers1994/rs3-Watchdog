-- Exercises ui/placeholder.lua's stub reconstruction (#53): a placeholder node has no real
-- pins, so its editor geometry is rebuilt from the wires touching it, with each stub's kind /
-- dataType inferred from the OTHER (known) end of the wire — neutral when that end is itself a
-- placeholder.
--
-- Placeholders are made the real way: deserialize a serialized graph that names an unregistered
-- type with onUnknown = "placeholder", yielding a live Graph with a `__unknown__` node and raw
-- connections (the same objects the editor sees at runtime).

local luaunit = require("luaunit")
local Serialize = require("serialize")
local Registry = require("registry")
local Placeholder = require("ui/placeholder")

local UNKNOWN = "u.mystery"  -- a type never registered below

TestPlaceholderStubs = {}

function TestPlaceholderStubs:setUp()
    self.registry = Registry.new()
    self.registry:RegisterNodeType("t.trigger", {
        category = "trigger",
        pins = { { name = "out", kind = "exec", direction = "out" } },
        run = function() end,
    })
    self.registry:RegisterNodeType("a.sink", {
        category = "action",
        pins = {
            { name = "flow", kind = "exec", direction = "in" },
            { name = "value", kind = "data", direction = "in", dataType = "number" },
        },
        run = function() end,
    })
end

-- Deserialize a serialized graph leniently, so any `UNKNOWN`-typed node lands as a placeholder.
function TestPlaceholderStubs:load(nodes, connections)
    return Serialize.Deserialize(
        { version = 1, nodes = nodes, connections = connections },
        self.registry, { onUnknown = "placeholder" })
end

-- A known trigger's exec-out feeding the placeholder gives it one exec INPUT stub.
function TestPlaceholderStubs:testInputStubInfersExecKindFromKnownSource()
    local graph = self:load(
        { { id = 1, type = "t.trigger", controls = {} },
          { id = 2, type = UNKNOWN, controls = {} } },
        { { fromNode = 1, fromPin = "out", toNode = 2, toPin = "gate" } })

    local stubs = Placeholder.Stubs(graph, 2)
    luaunit.assertEquals(#stubs, 1)
    luaunit.assertEquals(stubs[1].name, "gate")
    luaunit.assertEquals(stubs[1].direction, "in")
    luaunit.assertEquals(stubs[1].kind, "exec")
    luaunit.assertNil(stubs[1].dataType)
end

-- The placeholder feeding a known data input gives it one data OUTPUT stub, tagged with the
-- known input's Type Tag (for wire/glyph color).
function TestPlaceholderStubs:testOutputStubInfersDataTypeFromKnownTarget()
    local graph = self:load(
        { { id = 1, type = UNKNOWN, controls = {} },
          { id = 2, type = "a.sink", controls = {} } },
        { { fromNode = 1, fromPin = "result", toNode = 2, toPin = "value" } })

    local stubs = Placeholder.Stubs(graph, 1)
    luaunit.assertEquals(#stubs, 1)
    luaunit.assertEquals(stubs[1].name, "result")
    luaunit.assertEquals(stubs[1].direction, "out")
    luaunit.assertEquals(stubs[1].kind, "data")
    luaunit.assertEquals(stubs[1].dataType, "number")
end

-- Both ends unknown: nothing to infer from, so the stub is neutral (an "any" data stub).
function TestPlaceholderStubs:testBothPlaceholdersProduceNeutralStubs()
    local graph = self:load(
        { { id = 1, type = UNKNOWN, controls = {} },
          { id = 2, type = UNKNOWN, controls = {} } },
        { { fromNode = 1, fromPin = "o", toNode = 2, toPin = "i" } })

    local out = Placeholder.Stubs(graph, 1)
    luaunit.assertEquals(#out, 1)
    luaunit.assertEquals(out[1].direction, "out")
    luaunit.assertEquals(out[1].kind, "data")
    luaunit.assertEquals(out[1].dataType, "any")

    local inp = Placeholder.Stubs(graph, 2)
    luaunit.assertEquals(#inp, 1)
    luaunit.assertEquals(inp[1].direction, "in")
    luaunit.assertEquals(inp[1].kind, "data")
    luaunit.assertEquals(inp[1].dataType, "any")
end

-- One output pin feeding two known inputs collapses to a single output stub (dedupe).
function TestPlaceholderStubs:testDuplicateOutputWiresDedupeToOneStub()
    local graph = self:load(
        { { id = 1, type = UNKNOWN, controls = {} },
          { id = 2, type = "a.sink", controls = {} },
          { id = 3, type = "a.sink", controls = {} } },
        { { fromNode = 1, fromPin = "o", toNode = 2, toPin = "value" },
          { fromNode = 1, fromPin = "o", toNode = 3, toPin = "value" } })

    local stubs = Placeholder.Stubs(graph, 1)
    luaunit.assertEquals(#stubs, 1)
    luaunit.assertEquals(stubs[1].name, "o")
end

-- Inputs sort before outputs, then by name, so the pin rows don't jitter frame to frame.
function TestPlaceholderStubs:testStubsAreSortedInputsThenOutputsByName()
    local graph = self:load(
        { { id = 1, type = "t.trigger", controls = {} },
          { id = 2, type = UNKNOWN, controls = {} },
          { id = 3, type = "a.sink", controls = {} } },
        { { fromNode = 1, fromPin = "out", toNode = 2, toPin = "zeta" },
          { fromNode = 2, fromPin = "beta", toNode = 3, toPin = "value" },
          { fromNode = 2, fromPin = "alpha", toNode = 3, toPin = "flow" } })

    local stubs = Placeholder.Stubs(graph, 2)
    luaunit.assertEquals(#stubs, 3)
    -- input "zeta" first (direction "in" < "out"), then outputs "alpha", "beta" by name.
    luaunit.assertEquals(stubs[1].name, "zeta")
    luaunit.assertEquals(stubs[1].direction, "in")
    luaunit.assertEquals(stubs[2].name, "alpha")
    luaunit.assertEquals(stubs[3].name, "beta")
end

return TestPlaceholderStubs
