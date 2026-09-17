-- Exercises the action.screen_marker node (nodes/actions/screen_marker.lua, #39/#71) through its
-- pure seams: the Toast-parity hold/sticky effect handle it builds, and `run` pushing/
-- dismissing that handle on a real EffectRegistry -- no LibNodeGraph required, matching
-- test_popup's/test_infobox_node's convention (a fake registry + fake ctx driving a real
-- EffectRegistry). The Canvas draw is a client primitive, asserted only for not-erroring
-- against a fake canvas recording call counts, same as test_popup's own draw check.

_G.Vector4 = _G.Vector4 or { new = function(r, g, b, a) return { r, g, b, a } end }

local luaunit = require("luaunit")
local ScreenMarker = require("nodes/actions/screen_marker")
local EffectRegistry = require("effects")
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

TestScreenMarkerRegistration = {}

function TestScreenMarkerRegistration:setUp()
    self.reg = makeFakeRegistry()
    ScreenMarker.Register(self.reg, { effects = EffectRegistry.new() })
    self.desc = self.reg.types["action.screen_marker"]
end

function TestScreenMarkerRegistration:testRegistersActionScreenMarkerWithShowAndDismissExecIns()
    luaunit.assertNotNil(self.desc)
    luaunit.assertEquals(self.desc.category, "action")

    local byName, execOutCount = {}, 0
    for _, pin in ipairs(self.desc.pins) do
        byName[pin.name] = pin
        if pin.kind == "exec" and pin.direction == "out" then execOutCount = execOutCount + 1 end
    end
    luaunit.assertEquals(byName.show.kind, "exec")
    luaunit.assertEquals(byName.show.direction, "in")
    luaunit.assertEquals(byName.dismiss.kind, "exec")
    luaunit.assertEquals(byName.dismiss.direction, "in")
    luaunit.assertEquals(execOutCount, 0) -- no exec-out (AC)

    luaunit.assertEquals(byName.rect.dataType, "screen_marker.rect")
    luaunit.assertNil(byName.rect.default)
    luaunit.assertEquals(byName.thickness.dataType, "number")
    luaunit.assertEquals(byName.color.dataType, "color")
    -- #71 Toast-parity lifetime pins (defaults match Toast: sticky=false, hold=5).
    luaunit.assertEquals(byName.sticky.dataType, "bool")
    luaunit.assertEquals(byName.sticky.default, false)
    luaunit.assertEquals(byName.hold.dataType, "number")
    luaunit.assertEquals(byName.hold.default, ScreenMarker.DEFAULT_TTL_SECONDS)
    luaunit.assertEquals(byName.hold.default, 5.0)
end

--- run(): fired through a REAL LibNodeGraph, so ctx is the engine's genuine run context rather
--- than a hand-built stand-in. A fabricated ctx can only ever agree with the code's own
--- assumptions - that is exactly how the original ctx.pin/ctx.exec divergence slipped through.
--- (See CONTEXT.md: node behavior is verified against a real Graph.) ------------------------

TestScreenMarkerRun = {}

function TestScreenMarkerRun:setUp()
    self.registry = Registry.new()
    self.effects = EffectRegistry.new()
    ScreenMarker.Register(self.registry, { effects = self.effects })
    self.graph = Graph.new(self.registry)
end

-- The node keys its effect stack by its own ctx.state table, which StackCount also takes.
-- Reaching graph.nodes[id].state is white-box, but it is the node's real per-instance state.
local function stateOf(graph, id) return graph.nodes[id].state end

function TestScreenMarkerRun:testShowWithARectPushesOneEffect()
    local id = self.graph:AddNode("action.screen_marker", { rect = { x = 1, y = 2, w = 3, h = 4 } })
    self.graph:FireInput(id, "show")
    luaunit.assertEquals(self.effects:StackCount(stateOf(self.graph, id)), 1)
end

function TestScreenMarkerRun:testShowWithNilRectNeverFires()
    local id = self.graph:AddNode("action.screen_marker")
    self.graph:FireInput(id, "show")
    luaunit.assertEquals(self.effects:StackCount(stateOf(self.graph, id)), 0)
end

function TestScreenMarkerRun:testDismissRemovesTheEffect()
    local id = self.graph:AddNode("action.screen_marker", { rect = { x = 1, y = 2, w = 3, h = 4 } })
    self.graph:FireInput(id, "show")
    self.graph:FireInput(id, "dismiss")
    luaunit.assertEquals(self.effects:StackCount(stateOf(self.graph, id)), 0)
end

function TestScreenMarkerRun:testDismissOnUnshownNodeIsANoop()
    local id = self.graph:AddNode("action.screen_marker")
    local ok = pcall(function() self.graph:FireInput(id, "dismiss") end)
    luaunit.assertTrue(ok)
end

function TestScreenMarkerRun:testReShowReplacesRatherThanStacking()
    local id = self.graph:AddNode("action.screen_marker", { rect = { x = 1, y = 2, w = 3, h = 4 } })
    self.graph:FireInput(id, "show")
    self.graph:FireInput(id, "show")
    luaunit.assertEquals(self.effects:StackCount(stateOf(self.graph, id)), 1)
end

function TestScreenMarkerRun:testDifferentNodesStackIndependently()
    local rect = { x = 1, y = 2, w = 3, h = 4 }
    local a = self.graph:AddNode("action.screen_marker", { rect = rect })
    local b = self.graph:AddNode("action.screen_marker", { rect = rect })
    self.graph:FireInput(a, "show")
    self.graph:FireInput(b, "show")
    luaunit.assertEquals(self.effects:StackCount(stateOf(self.graph, a)), 1)
    luaunit.assertEquals(self.effects:StackCount(stateOf(self.graph, b)), 1)
end

function TestScreenMarkerRun:testDeserializedCloneWithSameNodeIdStacksSeparately()
    local rect = { x = 1, y = 2, w = 3, h = 4 }
    local id = self.graph:AddNode("action.screen_marker", { rect = rect })
    self.graph:FireInput(id, "show")
    local clone = Serialize.Deserialize(Serialize.Serialize(self.graph), self.registry)
    clone:FireInput(id, "show")
    luaunit.assertEquals(self.effects:StackCount(stateOf(self.graph, id)), 1)
    luaunit.assertEquals(self.effects:StackCount(stateOf(clone, id)), 1)
    luaunit.assertNotEquals(stateOf(self.graph, id), stateOf(clone, id))
end

function TestScreenMarkerRun:testExternalFireWithNoExecPinFallsBackToShowBehavior()
    -- Entered with no exec pin (ctx.exec nil, as an external Graph:Fire does) still treats a
    -- rect'd firing as Show rather than Dismiss.
    local id = self.graph:AddNode("action.screen_marker", { rect = { x = 0, y = 0, w = 5, h = 5 } })
    self.graph:Fire(id)
    luaunit.assertEquals(self.effects:StackCount(stateOf(self.graph, id)), 1)
end

--- BuildHandle: Toast-parity hold + sticky (#71) -------------------------------------------

function TestScreenMarkerRun:testBuildHandleIsAWellFormedEffectHandle()
    local h = ScreenMarker.BuildHandle({ x = 0, y = 0, w = 10, h = 10 })
    luaunit.assertEquals(h.kind, "screen_marker")
    luaunit.assertEquals(type(h.update), "function")
    luaunit.assertEquals(type(h.draw), "function")
end

function TestScreenMarkerRun:testHandleExpiresAfterTheDefaultHold()
    local h = ScreenMarker.BuildHandle({ x = 0, y = 0, w = 10, h = 10 })
    luaunit.assertTrue(h.update(4.9))
    luaunit.assertFalse(h.update(0.2)) -- 5.1s total -> expired
end

function TestScreenMarkerRun:testStickyHandleNeverExpires()
    local h = ScreenMarker.BuildHandle({ x = 0, y = 0, w = 10, h = 10 }, nil, nil, { sticky = true })
    for _ = 1, 1000 do
        luaunit.assertTrue(h.update(1.0))
    end
end

function TestScreenMarkerRun:testCustomHoldExpiresSooner()
    local h = ScreenMarker.BuildHandle({ x = 0, y = 0, w = 10, h = 10 }, nil, nil, { ttl = 1.0 })
    luaunit.assertTrue(h.update(0.9))
    luaunit.assertFalse(h.update(0.2))
end

function TestScreenMarkerRun:testShowExpiresOnItsOwnAfterHold()
    local id = self.graph:AddNode("action.screen_marker", {
        rect = { x = 1, y = 2, w = 3, h = 4 },
    })
    self.graph:FireInput(id, "show")
    for _ = 1, 6 do self.effects:Update(1.0) end -- 6s > 5s hold
    luaunit.assertEquals(self.effects:StackCount(stateOf(self.graph, id)), 0)
end

function TestScreenMarkerRun:testShowRespectsStickyThroughTheEffectRegistry()
    local id = self.graph:AddNode("action.screen_marker", {
        rect = { x = 1, y = 2, w = 3, h = 4 },
        sticky = true,
    })
    self.graph:FireInput(id, "show")
    for _ = 1, 500 do self.effects:Update(1.0) end
    luaunit.assertEquals(self.effects:StackCount(stateOf(self.graph, id)), 1)
end

function TestScreenMarkerRun:testShowRespectsCustomHoldPin()
    local id = self.graph:AddNode("action.screen_marker", {
        rect = { x = 1, y = 2, w = 3, h = 4 },
        hold = 1.0,
    })
    self.graph:FireInput(id, "show")
    self.effects:Update(0.5)
    luaunit.assertEquals(self.effects:StackCount(stateOf(self.graph, id)), 1)
    self.effects:Update(0.6)
    luaunit.assertEquals(self.effects:StackCount(stateOf(self.graph, id)), 0)
end

function TestScreenMarkerRun:testZeroHoldExpiresImmediately()
    local h = ScreenMarker.BuildHandle({ x = 0, y = 0, w = 1, h = 1 }, nil, nil, { ttl = 0 })
    luaunit.assertFalse(h.update(0))
end

-- A fake overlay Canvas recording the outline draw call's arguments.
local function makeFakeCanvas()
    local calls = {}
    return calls, {
        AddOutline = function(_self, x, y, w, h, thickness, color)
            calls[#calls + 1] = { x = x, y = y, w = w, h = h, thickness = thickness, color = color }
        end,
    }
end

function TestScreenMarkerRun:testHandleDrawsOutlineAtTheCapturedRectWithThicknessAndColor()
    local rect = { x = 12, y = 34, w = 56, h = 78 }
    local color = { r = 10, g = 20, b = 30, a = 255 }
    local h = ScreenMarker.BuildHandle(rect, 5, color)
    local calls, canvas = makeFakeCanvas()
    h.draw(canvas)
    luaunit.assertEquals(#calls, 1)
    luaunit.assertEquals(calls[1].x, rect.x)
    luaunit.assertEquals(calls[1].y, rect.y)
    luaunit.assertEquals(calls[1].w, rect.w)
    luaunit.assertEquals(calls[1].h, rect.h)
    luaunit.assertEquals(calls[1].thickness, 5)
end

function TestScreenMarkerRun:testHandleDrawFallsBackToDefaultThicknessAndColorWhenUnset()
    local rect = { x = 0, y = 0, w = 1, h = 1 }
    local h = ScreenMarker.BuildHandle(rect)
    local calls, canvas = makeFakeCanvas()
    local ok = pcall(function() h.draw(canvas) end)
    luaunit.assertTrue(ok)
    luaunit.assertEquals(#calls, 1)
    luaunit.assertEquals(calls[1].thickness, 2)
end

return TestScreenMarkerRegistration
