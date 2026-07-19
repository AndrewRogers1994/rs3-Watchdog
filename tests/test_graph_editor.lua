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

--- Object Marker mode multi-select toggle (#40) -------------------------------------------
-- toggleMode only reads self.graph + the clicked control entry (ctrl.value/ctrl.spec), so it
-- drives against the same metatable-backed fake `self` as linkPins above — no Canvas needed.

local ObjectMarker = require("nodes/actions/object_marker")
local EffectRegistry = require("effects")

TestObjectMarkerModeToggle = {}

function TestObjectMarkerModeToggle:setUp()
    self.registry = Registry.new()
    ObjectMarker.Register(self.registry, { effects = EffectRegistry.new() })
    self.graph = Graph.new(self.registry)
    self.editor = setmetatable({ graph = self.graph }, { __index = Editor })
end

-- The clicked mode checkbox row, as ui/node.lua would hand it to the dispatcher: the real mode
-- spec (so modeDescriptor resolves enabled/reason) plus the default-resolved current value.
function TestObjectMarkerModeToggle:ctrl(axis, value)
    return { pinName = "mode", axis = axis, spec = { modes = ObjectMarker.MODES }, value = value }
end

function TestObjectMarkerModeToggle:testTogglingTileClearsItFromDefaultChecked()
    local id = self.graph:AddNode("action.object_marker")
    -- Reads as ticked only via the pin default; the first click must clear it, not re-tick.
    self.editor:toggleMode(id, self:ctrl("tile", { tile = true }))
    luaunit.assertEquals(self.graph:GetControl(id, "mode").tile, false)
end

function TestObjectMarkerModeToggle:testTogglingTileBackOn()
    local id = self.graph:AddNode("action.object_marker")
    self.editor:toggleMode(id, self:ctrl("tile", { tile = false }))
    luaunit.assertEquals(self.graph:GetControl(id, "mode").tile, true)
end

function TestObjectMarkerModeToggle:testDisabledModeRowIsInert()
    local id = self.graph:AddNode("action.object_marker")
    self.editor:toggleMode(id, self:ctrl("hull", { tile = true }))
    -- A disabled row writes nothing: the mode value is untouched (no `hull` key appears).
    luaunit.assertNil(self.graph:GetControl(id, "mode").hull)
    luaunit.assertEquals(self.graph:GetControl(id, "mode").tile, true)
end

--- Matcher Control Band commit (#56) ------------------------------------------------------
-- toggleMatcherMode / commitNeedleField only touch self.graph (via setControl, which no-ops its
-- preload leg when self.runtime is nil) and the clicked control entry / self.editing, so they
-- drive against the same metatable-backed fake `self` — no Canvas mount needed. This is the
-- persist-through-the-control-store leg of the acceptance criteria (the node tests seed controls
-- directly; these assert the Editor's own read-modify-write actually lands in the store).

local GameMessage = require("nodes/triggers/game_message")

TestMatcherControlCommit = {}

function TestMatcherControlCommit:setUp()
    self.registry = Registry.new()
    -- Registers trigger.game_message and its matcher-typed `contains` pin (default substring).
    GameMessage.Register(self.registry, { BindTrigger = function() end })
    self.graph = Graph.new(self.registry)
    self.editor = setmetatable({ graph = self.graph }, { __index = Editor })
end

-- The clicked control entry as ui/node.lua hands it to the dispatcher: pinName + default-resolved
-- current value + the pin default (matcherRMW falls back to it when the stored control is nil).
function TestMatcherControlCommit:ctrl(value)
    return { pinName = "contains", value = value, default = { needle = "", mode = "substring" } }
end

function TestMatcherControlCommit:testToggleFlipsModePreservingNeedle()
    local id = self.graph:AddNode("trigger.game_message", { contains = { needle = "zulrah", mode = "substring" } })
    self.editor:toggleMatcherMode(id, self:ctrl({ needle = "zulrah", mode = "substring" }))
    local stored = self.graph:GetControl(id, "contains")
    luaunit.assertEquals(stored.mode, "pattern")   -- flipped
    luaunit.assertEquals(stored.needle, "zulrah")  -- preserved
end

function TestMatcherControlCommit:testTogglePatternBackToSubstring()
    local id = self.graph:AddNode("trigger.game_message", { contains = { needle = "x", mode = "pattern" } })
    self.editor:toggleMatcherMode(id, self:ctrl({ needle = "x", mode = "pattern" }))
    luaunit.assertEquals(self.graph:GetControl(id, "contains").mode, "substring")
end

function TestMatcherControlCommit:testToggleFromDefaultOnlyMatcher()
    -- No stored control: the flip bases off the pin default (substring) shown in the geometry.
    local id = self.graph:AddNode("trigger.game_message")
    self.editor:toggleMatcherMode(id, self:ctrl(nil))
    luaunit.assertEquals(self.graph:GetControl(id, "contains").mode, "pattern")
end

function TestMatcherControlCommit:testCommitNeedleWritesTextPreservingMode()
    local id = self.graph:AddNode("trigger.game_message", { contains = { needle = "", mode = "pattern" } })
    self.editor.editing = { nodeId = id, pinName = "contains", kind = "needle",
        field = { content = "%d+ gp" }, default = { needle = "", mode = "substring" } }
    self.editor:commitNeedleField()
    local stored = self.graph:GetControl(id, "contains")
    luaunit.assertEquals(stored.needle, "%d+ gp")
    luaunit.assertEquals(stored.mode, "pattern")  -- mode survives a needle edit
end

function TestMatcherControlCommit:testCommitEmptyNeedleIsAValidValue()
    -- Unlike a coordgrid axis (empty = leave alone), an empty needle is committed verbatim
    -- (it means "match everything"). Clearing "zulrah" to "" must actually store "".
    local id = self.graph:AddNode("trigger.game_message", { contains = { needle = "zulrah", mode = "substring" } })
    self.editor.editing = { nodeId = id, pinName = "contains", kind = "needle",
        field = { content = "" }, default = { needle = "", mode = "substring" } }
    self.editor:commitNeedleField()
    luaunit.assertEquals(self.graph:GetControl(id, "contains").needle, "")
end
