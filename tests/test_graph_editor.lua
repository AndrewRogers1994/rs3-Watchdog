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

--- Unbound construction + BindEntry (#80) -------------------------------------------------
-- Editor.new(registry, runtime) constructs the surface with NO graph; the Manager binds one on
-- open. These drive the real (unmounted) Editor — construction touches no ui.* — so BindEntry's
-- reset behavior is assertable headless.

function TestGraphEditor:testConstructedUnbound()
    local editor = Editor.new(self.registry, nil)
    luaunit.assertNil(editor.graph)
    luaunit.assertNil(editor.boundId)
end

function TestGraphEditor:testBindEntryBindsGraphAndResetsView()
    local editor = Editor.new(self.registry, nil)
    -- Dirty the transient view/selection state a previous binding would have left behind.
    editor.view.panX, editor.view.panY, editor.view.zoom = 123, 45, 2.5
    editor.selected = 999
    editor.nodeOrder = { 1, 2, 3 }

    local layout = { [1] = { x = 5, y = 6 } }
    editor:BindEntry(7, self.graph, layout)

    luaunit.assertEquals(editor.boundId, 7)                 -- keyed on id, never name (#75)
    luaunit.assertIs(editor.graph, self.graph)              -- the live instance, unchanged
    luaunit.assertIs(editor:GetLayout(), layout)
    luaunit.assertEquals(editor.view.panX, 0)              -- pan/zoom reset to the default framing
    luaunit.assertEquals(editor.view.panY, 0)
    luaunit.assertEquals(editor.view.zoom, 1.0)
    luaunit.assertNil(editor.selected)                     -- selection cleared
    luaunit.assertEquals(editor.nodeOrder, {})             -- z-order rebuilt from the new graph
end

function TestGraphEditor:testBindEntryDefaultsLayoutToEmpty()
    local editor = Editor.new(self.registry, nil)
    editor:BindEntry(3, self.graph, nil)
    luaunit.assertEquals(editor:GetLayout(), {})
end

function TestGraphEditor:testUnbindClearsBinding()
    local editor = Editor.new(self.registry, nil)
    editor:BindEntry(7, self.graph, { [1] = { x = 1, y = 2 } })
    editor:Unbind()
    luaunit.assertNil(editor.boundId)
    luaunit.assertNil(editor.graph)
    luaunit.assertEquals(editor:GetLayout(), {})
end

-- goBack routes through the host's onBack (the nav owner) when wired.
function TestGraphEditor:testGoBackInvokesOnBack()
    local editor = Editor.new(self.registry, nil)
    local calls = 0
    editor.onBack = function() calls = calls + 1 end
    editor:goBack()
    luaunit.assertEquals(calls, 1)
end

-- The Esc cascade's final rung is nav-up: with no popup/capture active, Escape calls goBack.
function TestGraphEditor:testEscapeNavigatesUpWhenNothingElseActive()
    local editor = Editor.new(self.registry, nil)
    local back = 0
    editor.onBack = function() back = back + 1 end
    editor:onEscape()
    luaunit.assertEquals(back, 1)
end

--- #96: + button palette places the new Node at the Viewport center -------------------------
-- viewCenterGraph is the seam: Graph-space point under the Viewport's content-local center.
-- The + path stores that as palette.anchorGX/GY with centerOnAnchor, so placeFromPalette
-- offsets by half the Node Body and the Body's center lands on the Viewport center
-- (double-click / wire-drop keep origin-at-click anchors).

function TestGraphEditor:testViewCenterGraphAtDefaultFraming()
    local editor = Editor.new(self.registry, nil)
    editor.window.w, editor.window.h = 400, 300
    -- Default View (pan 0, zoom 1): content-local center == Graph-space center.
    local gx, gy = editor:viewCenterGraph()
    luaunit.assertEquals(gx, 200)
    luaunit.assertEquals(gy, 150)
end

function TestGraphEditor:testViewCenterGraphAccountsForPanAndZoom()
    local editor = Editor.new(self.registry, nil)
    editor.window.w, editor.window.h = 400, 300
    editor.view.panX, editor.view.panY, editor.view.zoom = 40, -20, 2.0
    -- ToGraph((400/2), (300/2)) = (200-40)/2, (150-(-20))/2 = 80, 85
    local gx, gy = editor:viewCenterGraph()
    luaunit.assertEquals(gx, 80)
    luaunit.assertEquals(gy, 85)
end

function TestGraphEditor:testOpenPaletteFromPlusAnchorsAtViewCenter()
    local editor = Editor.new(self.registry, nil)
    editor.window.w, editor.window.h = 400, 300
    editor.view.panX, editor.view.panY, editor.view.zoom = 40, -20, 2.0
    -- expandCapture touches capture/ui.*; stub so the open path stays headless.
    editor.expandCapture = function() end
    editor.closeColorPopup = function() end

    editor:openPaletteFromPlus()

    luaunit.assertTrue(editor.palette.open)
    luaunit.assertEquals(editor.palette.anchorGX, 80)
    luaunit.assertEquals(editor.palette.anchorGY, 85)
    luaunit.assertTrue(editor.palette.centerOnAnchor)
end

-- After picking a type from the + Palette, the Node Body's center (not its origin) sits on
-- the Viewport center.
function TestGraphEditor:testPlaceFromPlusCentersNodeBodyOnViewCenter()
    local Theme = require("ui/theme")
    local Node = require("ui/node")
    local editor = Editor.new(self.registry, nil)
    editor:BindEntry(1, self.graph, {})
    editor.window.w, editor.window.h = 400, 300
    editor.expandCapture = function() end
    editor.closeColorPopup = function() end
    editor.positionCapture = function() end

    editor:openPaletteFromPlus()
    local row
    for _, r in ipairs(editor.palette.rows) do
        if not r.header and r.typeKey == "fixture.trigger" then
            row = r
            break
        end
    end
    luaunit.assertNotNil(row)

    editor:placeFromPalette(row)

    local id = editor.selected
    luaunit.assertNotNil(id)
    local pos = editor.layout[id]
    local geom = Node.BuildGeometry(self.graph:GetPins(id), 0, 0, Theme.NODE_WIDTH)
    luaunit.assertEquals(pos.x + geom.w * 0.5, 200)
    luaunit.assertEquals(pos.y + geom.h * 0.5, 150)
end

local function registerModeFixture(registry)
    registry:RegisterNodeType("fixture.modes", {
        category = "action",
        defaultMode = "full",
        modes = {
            {
                key = "full",
                label = "Full",
                pins = {
                    { name = "in", kind = "exec", direction = "in", terminates = true },
                    { name = "item", kind = "data", direction = "in", dataType = "string", default = "" },
                },
            },
            {
                key = "count",
                label = "Count",
                pins = {
                    { name = "in", kind = "exec", direction = "in", terminates = true },
                    { name = "n", kind = "data", direction = "in", dataType = "number", default = 0 },
                },
            },
        },
        run = function() end,
    })
end

function TestGraphEditor:testFirstCompatiblePinFindsNonDefaultMode()
    registerModeFixture(self.registry)
    local def = self.registry:GetNodeType("fixture.modes")
    local pin, mode = Editor.FirstCompatiblePin(def, {
        kind = "data", direction = "out", dataType = "number",
    })
    luaunit.assertEquals(pin, "n")
    luaunit.assertEquals(mode, "count")
end

function TestGraphEditor:testPlaceFromPaletteCreatesInTargetMode()
    registerModeFixture(self.registry)
    local editor = Editor.new(self.registry, nil)
    editor:BindEntry(1, self.graph, {})
    editor.expandCapture = function() end
    editor.positionCapture = function() end

    editor:placeFromPalette({ typeKey = "fixture.modes", targetPin = "n", targetMode = "count" })

    local id = editor.selected
    luaunit.assertEquals(self.graph:GetMode(id), "count")
    local names = {}
    for _, p in ipairs(self.graph:GetPins(id)) do names[p.name] = true end
    luaunit.assertTrue(names.n)
    luaunit.assertNil(names.item)
end

function TestGraphEditor:testApplyNodeModeRebuildsPinsAndDropsVanishedEditor()
    registerModeFixture(self.registry)
    local id = self.graph:AddNode("fixture.modes")
    luaunit.assertEquals(self.graph:GetMode(id), "full")

    local closed = false
    local editor = setmetatable({
        graph = self.graph,
        editing = { nodeId = id, pinName = "item", kind = "field" },
        closeControlEditor = function(self)
            closed = true
            self.editing = nil
        end,
    }, { __index = Editor })

    luaunit.assertTrue(editor:applyNodeMode(id, "count"))
    luaunit.assertTrue(closed)
    luaunit.assertEquals(self.graph:GetMode(id), "count")
    local names = {}
    for _, p in ipairs(self.graph:GetPins(id)) do names[p.name] = true end
    luaunit.assertTrue(names.n)
    luaunit.assertNil(names.item)
end
