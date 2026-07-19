-- Exercises the action.object_marker node (nodes/actions/object_marker.lua, #40) through its
-- pure seams: the world-anchored, auto-expiring (TTL + sticky) effect handle it builds, the
-- pure tile-corner projection that handle re-runs every Draw, and `run` pushing/dismissing that
-- handle on a real EffectRegistry. Mirrors test_screen_marker's convention (a real
-- LibNodeGraph + EffectRegistry, plus a fake registry for the pin-shape assertions). The
-- CoordGrid/CoordFine/ScreenConvert projection is a client primitive, so it's tested through an
-- injected fake projector rather than the absent client globals.

_G.Vector4 = _G.Vector4 or { new = function(r, g, b, a) return { r, g, b, a } end }

local luaunit = require("luaunit")
local ObjectMarker = require("nodes/actions/object_marker")
local EffectRegistry = require("effects")
-- Real engine (LibNodeGraph, on package.path — see tests/run.lua), so run() is exercised
-- through a genuine ctx rather than a fabricated one.
local Registry = require("registry")
local Graph = require("graph")

local function makeFakeRegistry()
    return {
        types = {},
        RegisterNodeType = function(self, key, desc) self.types[key] = desc end,
    }
end

-- A fully-specified captured object param, as the select-mode capture (#40) stores it.
local function sampleObject()
    return { name = "Bank booth", coordGrid = { x = 3162, z = 3487, level = 0 }, subjectHash = 12345 }
end

--- Registration --------------------------------------------------------------------------

TestObjectMarkerRegistration = {}

function TestObjectMarkerRegistration:setUp()
    self.reg = makeFakeRegistry()
    ObjectMarker.Register(self.reg, { effects = EffectRegistry.new() })
    self.desc = self.reg.types["action.object_marker"]
end

function TestObjectMarkerRegistration:testRegistersActionObjectMarkerWithShowAndDismissExecIns()
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

    luaunit.assertEquals(byName.object.dataType, "object_marker.object")
    luaunit.assertNil(byName.object.default) -- a never-captured object never fires
    luaunit.assertEquals(byName.mode.dataType, "object_marker.mode")
    luaunit.assertEquals(byName.color.dataType, "color")
    luaunit.assertEquals(byName.width.dataType, "number")
    luaunit.assertEquals(byName.showLabel.dataType, "bool")
    luaunit.assertEquals(byName.sticky.dataType, "bool")
end

--- run(): fired through a REAL LibNodeGraph, so ctx is the engine's genuine run context. ----

TestObjectMarkerRun = {}

function TestObjectMarkerRun:setUp()
    self.registry = Registry.new()
    self.effects = EffectRegistry.new()
    ObjectMarker.Register(self.registry, { effects = self.effects })
    self.graph = Graph.new(self.registry)
end

local function stateOf(graph, id) return graph.nodes[id].state end

function TestObjectMarkerRun:testShowWithACapturedObjectPushesOneEffect()
    local id = self.graph:AddNode("action.object_marker", { object = sampleObject() })
    self.graph:FireInput(id, "show")
    luaunit.assertEquals(self.effects:StackCount(stateOf(self.graph, id)), 1)
end

function TestObjectMarkerRun:testShowWithNoCaptureIsANoop()
    local id = self.graph:AddNode("action.object_marker")
    self.graph:FireInput(id, "show")
    luaunit.assertEquals(self.effects:StackCount(stateOf(self.graph, id)), 0)
end

function TestObjectMarkerRun:testDismissRemovesTheEffect()
    local id = self.graph:AddNode("action.object_marker", { object = sampleObject() })
    self.graph:FireInput(id, "show")
    self.graph:FireInput(id, "dismiss")
    luaunit.assertEquals(self.effects:StackCount(stateOf(self.graph, id)), 0)
end

function TestObjectMarkerRun:testDismissOnUnshownNodeIsANoop()
    local id = self.graph:AddNode("action.object_marker")
    local ok = pcall(function() self.graph:FireInput(id, "dismiss") end)
    luaunit.assertTrue(ok)
end

function TestObjectMarkerRun:testReShowReplacesRatherThanStacking()
    local id = self.graph:AddNode("action.object_marker", { object = sampleObject() })
    self.graph:FireInput(id, "show")
    self.graph:FireInput(id, "show")
    luaunit.assertEquals(self.effects:StackCount(stateOf(self.graph, id)), 1)
end

function TestObjectMarkerRun:testDifferentNodesStackIndependently()
    local a = self.graph:AddNode("action.object_marker", { object = sampleObject() })
    local b = self.graph:AddNode("action.object_marker", { object = sampleObject() })
    self.graph:FireInput(a, "show")
    self.graph:FireInput(b, "show")
    luaunit.assertEquals(self.effects:StackCount(stateOf(self.graph, a)), 1)
    luaunit.assertEquals(self.effects:StackCount(stateOf(self.graph, b)), 1)
end

--- BuildHandle: TTL + sticky lifecycle (the Overlay idiom) ---------------------------------

function TestObjectMarkerRun:testBuildHandleIsAWellFormedEffectHandle()
    local h = ObjectMarker.BuildHandle({ object = sampleObject() })
    luaunit.assertEquals(h.kind, "object_marker")
    luaunit.assertEquals(type(h.update), "function")
    luaunit.assertEquals(type(h.draw), "function")
end

function TestObjectMarkerRun:testHandleExpiresAfterTheDefaultTTL()
    local h = ObjectMarker.BuildHandle({ object = sampleObject() })
    -- Alive up to but not past the 5s default TTL.
    luaunit.assertTrue(h.update(4.9))
    luaunit.assertFalse(h.update(0.2)) -- 5.1s total -> expired
end

function TestObjectMarkerRun:testStickyHandleNeverExpires()
    local h = ObjectMarker.BuildHandle({ object = sampleObject(), sticky = true })
    for _ = 1, 1000 do
        luaunit.assertTrue(h.update(1.0))
    end
end

function TestObjectMarkerRun:testShowRespectsStickyThroughTheEffectRegistry()
    local id = self.graph:AddNode("action.object_marker", { object = sampleObject(), sticky = true })
    self.graph:FireInput(id, "show")
    for _ = 1, 500 do self.effects:Update(1.0) end
    luaunit.assertEquals(self.effects:StackCount(stateOf(self.graph, id)), 1)
end

function TestObjectMarkerRun:testShowExpiresOnItsOwnAfterTTL()
    local id = self.graph:AddNode("action.object_marker", { object = sampleObject() })
    self.graph:FireInput(id, "show")
    for _ = 1, 6 do self.effects:Update(1.0) end -- 6s > 5s TTL
    luaunit.assertEquals(self.effects:StackCount(stateOf(self.graph, id)), 0)
end

--- TileCorners: pure re-projection (nil-any-corner => nothing) -----------------------------

-- A fake projector standing in for the CoordGrid->CoordFine->ScreenConvert chain: maps a
-- fine (x, z) linearly to screen space so the four corners are deterministic and checkable.
local function fakeProject(level, fineX, fineZ)
    return { x = fineX / 10, y = fineZ / 10 }
end

function TestObjectMarkerRun:testTileCornersProjectsFourCornersAtTheTileFineOffsets()
    local coord = { x = 100, z = 200, level = 0 }
    -- base fine of a tile = grid * 512; the four corners add {0/512, 512} in x/z.
    local corners = ObjectMarker.TileCorners(coord, fakeProject)
    luaunit.assertNotNil(corners)
    luaunit.assertEquals(#corners, 4)
    local baseX, baseZ = 100 * 512, 200 * 512
    luaunit.assertEquals(corners[1].x, baseX / 10)
    luaunit.assertEquals(corners[1].y, baseZ / 10)
    luaunit.assertEquals(corners[3].x, (baseX + 512) / 10)
    luaunit.assertEquals(corners[3].y, (baseZ + 512) / 10)
end

function TestObjectMarkerRun:testTileCornersReturnsNilWhenAnyCornerIsUnavailable()
    local coord = { x = 1, z = 1, level = 0 }
    local calls = 0
    local corners = ObjectMarker.TileCorners(coord, function()
        calls = calls + 1
        if calls == 3 then return nil end -- a single unavailable corner nukes the whole tile
        return { x = 0, y = 0 }
    end)
    luaunit.assertNil(corners)
end

function TestObjectMarkerRun:testTileCornersReturnsNilForNilCoord()
    luaunit.assertNil(ObjectMarker.TileCorners(nil, fakeProject))
end

--- Draw: tile outline (4 lines) + optional label ------------------------------------------

local function makeFakeCanvas()
    local calls = { lines = {}, texts = {} }
    return calls, {
        AddLine = function(_self, x0, y0, x1, y1, thickness, color)
            calls.lines[#calls.lines + 1] = { x0 = x0, y0 = y0, x1 = x1, y1 = y1, thickness = thickness, color = color }
        end,
        AddText = function(_self, x, y, text, font, color)
            calls.texts[#calls.texts + 1] = { x = x, y = y, text = text }
        end,
    }
end

function TestObjectMarkerRun:testDrawTileOutlineEmitsFourLines()
    local calls, canvas = makeFakeCanvas()
    ObjectMarker.DrawTile(canvas, { object = sampleObject(), width = 3 }, fakeProject)
    luaunit.assertEquals(#calls.lines, 4)
    luaunit.assertEquals(calls.lines[1].thickness, 3)
end

function TestObjectMarkerRun:testDrawTileDrawsNothingWhenProjectionUnavailable()
    local calls, canvas = makeFakeCanvas()
    ObjectMarker.DrawTile(canvas, { object = sampleObject() }, function() return nil end)
    luaunit.assertEquals(#calls.lines, 0)
    luaunit.assertEquals(#calls.texts, 0)
end

function TestObjectMarkerRun:testDrawTileDrawsLabelWhenShowLabelOn()
    _G.Theme = nil
    local calls, canvas = makeFakeCanvas()
    ObjectMarker.DrawTile(canvas, { object = sampleObject(), showLabel = true }, fakeProject)
    luaunit.assertEquals(#calls.texts, 1)
    luaunit.assertEquals(calls.texts[1].text, "Bank booth")
end

function TestObjectMarkerRun:testDrawTileOmitsLabelWhenShowLabelOff()
    local calls, canvas = makeFakeCanvas()
    ObjectMarker.DrawTile(canvas, { object = sampleObject(), showLabel = false }, fakeProject)
    luaunit.assertEquals(#calls.texts, 0)
end

function TestObjectMarkerRun:testDrawTileDrawsNothingWhenTileModeUnset()
    local calls, canvas = makeFakeCanvas()
    ObjectMarker.DrawTile(canvas, { object = sampleObject(), mode = { tile = false } }, fakeProject)
    luaunit.assertEquals(#calls.lines, 0)
end

return TestObjectMarkerRegistration
