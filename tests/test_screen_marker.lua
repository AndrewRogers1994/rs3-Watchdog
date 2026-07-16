-- Exercises the action.screen_marker node (nodes/actions/screen_marker.lua, #39) through its
-- pure seams: the persistent (never-auto-expiring) effect handle it builds, and `run` pushing/
-- dismissing that handle on a real EffectRegistry -- no LibNodeGraph required, matching
-- test_popup's/test_infobox_node's convention (a fake registry + fake ctx driving a real
-- EffectRegistry). The Canvas draw is a client primitive, asserted only for not-erroring
-- against a fake canvas recording call counts, same as test_popup's own draw check.

_G.Vector4 = _G.Vector4 or { new = function(r, g, b, a) return { r, g, b, a } end }

local luaunit = require("luaunit")
local ScreenMarker = require("nodes/actions/screen_marker")
local EffectRegistry = require("effects")

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
    luaunit.assertNil(byName.rect.default) -- a never-drawn rect never fires
    luaunit.assertEquals(byName.thickness.dataType, "number")
    luaunit.assertEquals(byName.color.dataType, "color")
end

--- run(): a fake ctx whose `state` persists across calls for the same node (mirroring the
--- engine's per-node ctx.state, like action.screen_flash's own Stack-keyed-by-state idiom). --

local function makeCtxFactory()
    local states = {}
    return function(nodeId, values, pin)
        states[nodeId] = states[nodeId] or {}
        return {
            nodeId = nodeId,
            pin = pin,
            state = states[nodeId],
            In = function(_self, name) return values[name] end,
        }
    end
end

TestScreenMarkerRun = {}

function TestScreenMarkerRun:setUp()
    self.reg = makeFakeRegistry()
    self.effects = EffectRegistry.new()
    ScreenMarker.Register(self.reg, { effects = self.effects })
    self.desc = self.reg.types["action.screen_marker"]
    self.ctx = makeCtxFactory()
end

function TestScreenMarkerRun:testShowWithARectPushesOneEffect()
    local ctx = self.ctx("n1", { rect = { x = 1, y = 2, w = 3, h = 4 } }, "show")
    self.desc.run(ctx)
    luaunit.assertEquals(self.effects:StackCount(ctx.state), 1)
end

function TestScreenMarkerRun:testShowWithNilRectNeverFires()
    local ctx = self.ctx("n1", {}, "show")
    self.desc.run(ctx)
    luaunit.assertEquals(self.effects:StackCount(ctx.state), 0)
end

function TestScreenMarkerRun:testDismissRemovesTheEffect()
    local rect = { x = 1, y = 2, w = 3, h = 4 }
    self.desc.run(self.ctx("n1", { rect = rect }, "show"))
    local ctx = self.ctx("n1", {}, "dismiss")
    self.desc.run(ctx)
    luaunit.assertEquals(self.effects:StackCount(ctx.state), 0)
end

function TestScreenMarkerRun:testDismissOnUnshownNodeIsANoop()
    local ok = pcall(function() self.desc.run(self.ctx("ghost", {}, "dismiss")) end)
    luaunit.assertTrue(ok)
end

function TestScreenMarkerRun:testReShowReplacesRatherThanStacking()
    local rect = { x = 1, y = 2, w = 3, h = 4 }
    local ctx1 = self.ctx("n1", { rect = rect }, "show")
    self.desc.run(ctx1)
    local ctx2 = self.ctx("n1", { rect = rect }, "show")
    self.desc.run(ctx2)
    luaunit.assertEquals(self.effects:StackCount(ctx2.state), 1)
end

function TestScreenMarkerRun:testDifferentNodesStackIndependently()
    local rect = { x = 1, y = 2, w = 3, h = 4 }
    local ctxA = self.ctx("a", { rect = rect }, "show")
    local ctxB = self.ctx("b", { rect = rect }, "show")
    self.desc.run(ctxA)
    self.desc.run(ctxB)
    luaunit.assertEquals(self.effects:StackCount(ctxA.state), 1)
    luaunit.assertEquals(self.effects:StackCount(ctxB.state), 1)
end

function TestScreenMarkerRun:testMissingPinFallsBackToShowBehavior()
    -- No `.pin` (a ctx shaped like a single-exec-in node) still treats a rect'd firing as Show.
    local ctx = self.ctx("n1", { rect = { x = 0, y = 0, w = 5, h = 5 } })
    self.desc.run(ctx)
    luaunit.assertEquals(self.effects:StackCount(ctx.state), 1)
end

--- BuildHandle: a persistent effect handle that never auto-expires -------------------------

function TestScreenMarkerRun:testBuildHandleIsAWellFormedEffectHandle()
    local h = ScreenMarker.BuildHandle({ x = 0, y = 0, w = 10, h = 10 })
    luaunit.assertEquals(h.kind, "screen_marker")
    luaunit.assertEquals(type(h.update), "function")
    luaunit.assertEquals(type(h.draw), "function")
end

function TestScreenMarkerRun:testHandleUpdateNeverExpiresOnItsOwn()
    local h = ScreenMarker.BuildHandle({ x = 0, y = 0, w = 10, h = 10 })
    for _ = 1, 1000 do
        luaunit.assertTrue(h.update(0.02))
    end
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
