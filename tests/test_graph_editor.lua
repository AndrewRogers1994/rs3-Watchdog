-- Exercises Editor:linkPins (ui/graph.lua) — the connection-commit path shared by Wire drops
-- and Palette auto-connect. Focus: #3's toggle-off-on-duplicate and its ordering against the
-- data-input single-connection replace. The full Editor is Canvas/immediate-mode and not
-- unit-testable here, but linkPins only touches self.graph and self:connectionInto, so we drive
-- it against a real engine Graph via a metatable-backed fake `self` (no Canvas mount needed).
--
-- Client/UI globals the module builds colors/fonts from at load time — stubbed minimally so
-- ui/graph (and its Theme/Palette/... requires) load under a standalone interpreter.
_G.Vector4 = { new = function(r, g, b, a) return { r, g, b, a } end }
_G.id = setmetatable({}, { __index = function() return setmetatable({}, { __index = function() return 1 end }) end })
_G.config = { Font = setmetatable({}, { __index = function()
    return { GetStringWidth = function(_, t) return #t * 7 end }
end }) }

local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local Editor = require("ui/graph")

TestGraphEditor = {}

function TestGraphEditor:setUp()
    self.registry = Registry.new()

    self.registry:RegisterNodeType("fixture.trigger", {
        category = "trigger",
        pins = { { name = "out", kind = "exec", direction = "out" } },
        run = function(ctx) ctx:Fire("out") end,
    })
    self.registry:RegisterNodeType("fixture.action", {
        category = "action",
        pins = {
            { name = "in", kind = "exec", direction = "in", terminates = true },
            { name = "value", kind = "data", direction = "in", dataType = "number", default = 0 },
        },
        run = function() end,
    })
    self.registry:RegisterNodeType("fixture.number", {
        category = "pure",
        pins = { { name = "out", kind = "data", direction = "out", dataType = "number" } },
        run = function(ctx) ctx:Out("out", 0) end,
    })

    self.graph = Graph.new(self.registry)
    -- Fake Editor: method calls (connectionInto, linkPins) resolve against Editor; the only
    -- state linkPins reads is self.graph.
    self.editor = setmetatable({ graph = self.graph }, { __index = Editor })
end

-- #3: re-committing the identical exec wire removes it (toggle off), rather than stacking a
-- duplicate the engine now refuses.
function TestGraphEditor:testDuplicateExecWireTogglesOff()
    local trig = self.graph:AddNode("fixture.trigger")
    local act = self.graph:AddNode("fixture.action")

    self.editor:linkPins(trig, "out", act, "in", false)
    luaunit.assertEquals(#self.graph:GetConnections(), 1)

    self.editor:linkPins(trig, "out", act, "in", false)  -- same wire again
    luaunit.assertEquals(#self.graph:GetConnections(), 0)
end

-- #3 applies uniformly: re-committing the identical DATA wire also toggles off (it is not the
-- old invisible replace — the wire disappears).
function TestGraphEditor:testDuplicateDataWireTogglesOff()
    local num = self.graph:AddNode("fixture.number")
    local act = self.graph:AddNode("fixture.action")

    self.editor:linkPins(num, "out", act, "value", true)
    luaunit.assertEquals(#self.graph:GetConnections(), 1)

    self.editor:linkPins(num, "out", act, "value", true)  -- same source, same input
    luaunit.assertEquals(#self.graph:GetConnections(), 0)
end

-- A DIFFERENT source into an occupied data input still replaces (single data connection),
-- distinct from the toggle above.
function TestGraphEditor:testDifferentSourceReplacesDataInput()
    local num1 = self.graph:AddNode("fixture.number")
    local num2 = self.graph:AddNode("fixture.number")
    local act = self.graph:AddNode("fixture.action")

    self.editor:linkPins(num1, "out", act, "value", true)
    self.editor:linkPins(num2, "out", act, "value", true)

    local conns = self.graph:GetConnections()
    luaunit.assertEquals(#conns, 1)
    luaunit.assertEquals(conns[1].fromNode, num2)  -- num2 replaced num1
end

-- An exec output may fan out to distinct inputs; only exact duplicates toggle.
function TestGraphEditor:testFanOutIsNotTreatedAsDuplicate()
    local trig = self.graph:AddNode("fixture.trigger")
    local act1 = self.graph:AddNode("fixture.action")
    local act2 = self.graph:AddNode("fixture.action")

    self.editor:linkPins(trig, "out", act1, "in", false)
    self.editor:linkPins(trig, "out", act2, "in", false)
    luaunit.assertEquals(#self.graph:GetConnections(), 2)
end
