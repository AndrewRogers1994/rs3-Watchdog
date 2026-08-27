local luaunit = require("luaunit")
local Theme = require("ui/theme")
local Node = require("ui/node")
local View = require("ui/view")
local InvViewer = require("ui/inv_viewer")

TestInvViewer = {}

function TestInvViewer:testScreenSizeMatchesPrettyUiItemGrid()
    local w, h = InvViewer.ScreenSize()
    luaunit.assertEquals(w, 4 * 40 + 3 * 2)
    luaunit.assertEquals(h, 7 * 40 + 6 * 2)
end

function TestInvViewer:testGraphExtraInvertsZoom()
    local _, sh = InvViewer.ScreenSize()
    local _, gh = InvViewer.GraphExtra(0.5)
    luaunit.assertAlmostEquals(gh, sh / 0.5, 1e-9)
end

function TestInvViewer:testClampRowOffsetForBank()
    luaunit.assertEquals(InvViewer.ClampRowOffset(0, 28), 0)
    luaunit.assertEquals(InvViewer.ClampRowOffset(99, 28), 0)
    luaunit.assertEquals(InvViewer.ClampRowOffset(0, 800), 0)
    luaunit.assertEquals(InvViewer.ClampRowOffset(200, 800), 193)
    luaunit.assertEquals(InvViewer.ClampRowOffset(-3, 800), 0)
end

function TestInvViewer:testGridObjectsWindowsDenseSlots()
    local slots = {}
    slots[1] = { name = "A", objId = 1, count = 1 }
    slots[5] = { name = "E", objId = 5, count = 2 }
    local objects = InvViewer.GridObjects({ slots = slots, slotCount = 40 }, 0)
    luaunit.assertEquals(#objects, 28)
    luaunit.assertEquals(objects[1].object.id, 1)
    luaunit.assertEquals(objects[1].object.name, "A")
    luaunit.assertEquals(objects[1].tooltip, "A")
    luaunit.assertNil(objects[2].object)
    luaunit.assertEquals(objects[5].object.id, 5)
    -- row offset 1 starts at slot 5 (clamped against slotCount 40)
    local windowed = InvViewer.GridObjects({ slots = slots, slotCount = 40 }, 1)
    luaunit.assertEquals(windowed[1].object.id, 5)
    luaunit.assertEquals(windowed[1].tooltip, "E")
end

function TestInvViewer:testBuildGeometryReservesViewerGrid()
    local pins = {
        { name = "in", kind = "exec", direction = "in" },
        { name = "snapshot", kind = "data", direction = "in", dataType = "invSnapshot" },
    }
    local extra = InvViewer.ExtraBodyOpts(1)
    local geom = Node.BuildGeometry(pins, 0, 0, Theme.NODE_WIDTH, extra)
    luaunit.assertNotNil(geom.viewerGrid)
    luaunit.assertAlmostEquals(geom.viewerGrid.h, extra.extraBodyH, 1e-9)
    local without = Node.BuildGeometry(pins, 0, 0, Theme.NODE_WIDTH)
    luaunit.assertAlmostEquals(geom.h, without.h + extra.extraBodyH, 1e-9)
end

function TestInvViewer:testSyncPositionsGridInAbsoluteScreenSpace()
    local extra = InvViewer.ExtraBodyOpts(1)
    local geom = Node.BuildGeometry({
        { name = "in", kind = "exec", direction = "in" },
        { name = "snapshot", kind = "data", direction = "in", dataType = "invSnapshot" },
    }, 10, 20, Theme.NODE_WIDTH, extra)
    local pos = {}
    local grid = {
        root = {
            SetPos = function(_, x, y) pos.x, pos.y = x, y end,
            SetSize = function() end,
        },
        SetObjects = function() end,
    }
    local editor = {
        visible = true,
        window = { x = 100, y = 80, w = 800, h = 600 },
        view = View.new(),
        geoms = { [1] = geom },
        inventoryGrids = { [1] = grid },
        viewerScroll = {},
        graph = {
            GetNodes = function()
                return { { id = 1, typeKey = InvViewer.TYPE_KEY } }
            end,
            GetState = function() return {} end,
        },
        toScreen = function(self, lx, ly)
            return lx + self.window.x, ly + self.window.y
        end,
    }
    InvViewer.Sync(editor)
    local lx, ly = editor.view:ToScreen(geom.x + geom.viewerGrid.x, geom.y + geom.viewerGrid.y)
    luaunit.assertEquals(pos.x, lx + 100)
    luaunit.assertEquals(pos.y, ly + 80)
end

function TestInvViewer:testSyncDoesNotRebuildGridObjectsEveryFrame()
    local extra = InvViewer.ExtraBodyOpts(1)
    local geom = Node.BuildGeometry({
        { name = "in", kind = "exec", direction = "in" },
        { name = "snapshot", kind = "data", direction = "in", dataType = "invSnapshot" },
    }, 0, 0, Theme.NODE_WIDTH, extra)
    local sets = 0
    local snap = { slots = {}, slotCount = 28 }
    local grid = {
        root = { SetPos = function() end, SetSize = function() end },
        SetObjects = function() sets = sets + 1 end,
    }
    local editor = {
        visible = true,
        window = { x = 0, y = 0, w = 800, h = 600 },
        view = View.new(),
        geoms = { [1] = geom },
        inventoryGrids = { [1] = grid },
        viewerScroll = {},
        graph = {
            GetNodes = function()
                return { { id = 1, typeKey = InvViewer.TYPE_KEY } }
            end,
            GetState = function() return { snapshot = snap } end,
        },
        toScreen = function(_, lx, ly) return lx, ly end,
    }
    InvViewer.Sync(editor)
    InvViewer.Sync(editor)
    luaunit.assertEquals(sets, 1)
    snap = { slots = {}, slotCount = 28 }
    InvViewer.Sync(editor)
    luaunit.assertEquals(sets, 2)
end

return TestInvViewer
