-- coordgrid Pin Control (ADR-0005 / #58) driven through a fake host: press -> commit, assert
-- the COMMITTED value, never Widgets.

local luaunit = require("luaunit")
local CoordGrid = require("src/ui/controls/coordgrid")
local FakeHost = require("fake_control_host")

--- Editing an axis through press -> mount -> commit ---------------------------------------

TestCoordgridEditAxis = {}

-- The clicked "field" sub-rect as node.lua hands it to Press: axis + default-resolved current value.
local function fieldCtrl(axis, value)
    return { kind = "field", axis = axis, pinName = "target", value = value,
        x = 0, y = 0, w = 40, h = 16 }
end

function TestCoordgridEditAxis:testCommittingOneAxisPreservesTheOthers()
    local host = FakeHost.new({ x = 10, z = 20, level = 0 })
    CoordGrid.Press(host, fieldCtrl("z", { x = 10, z = 20, level = 0 }))
    host:Type("99", 99)
    luaunit.assertEquals(host.committed, { x = 10, z = 99, level = 0 })
end

function TestCoordgridEditAxis:testEditingXThenLevelKeepsBothAndPreservesZ()
    local host = FakeHost.new({ x = 10, z = 20, level = 0 })
    CoordGrid.Press(host, fieldCtrl("x", { x = 10, z = 20, level = 0 }))
    host:Type("77", 77)
    CoordGrid.Press(host, fieldCtrl("level", host.stored))
    host:Type("2", 2)
    luaunit.assertEquals(host.committed, { x = 77, z = 20, level = 2 })
end

function TestCoordgridEditAxis:testEmptyEditLeavesTheTableAlone()
    -- Empty-box guard: clearing a field must not clobber the axis. No commit happens at all.
    local host = FakeHost.new({ x = 10, z = 20, level = 0 })
    CoordGrid.Press(host, fieldCtrl("z", { x = 10, z = 20, level = 0 }))
    host:Type("", nil)
    luaunit.assertNil(host.committed)
    luaunit.assertEquals(host.stored, { x = 10, z = 20, level = 0 })
end

function TestCoordgridEditAxis:testUnparsableEditLeavesTheTableAlone()
    local host = FakeHost.new({ x = 10, z = 20, level = 0 })
    CoordGrid.Press(host, fieldCtrl("x", { x = 10, z = 20, level = 0 }))
    host:Type("not-a-number", nil)
    luaunit.assertNil(host.committed)
end

function TestCoordgridEditAxis:testEditingAnUnsetControlSeedsAFreshPartialTable()
    -- No stored value yet: first axis edit produces a table with just that axis (nil current -> fresh table).
    local host = FakeHost.new(nil)
    CoordGrid.Press(host, fieldCtrl("x", nil))
    host:Type("5", 5)
    luaunit.assertEquals(host.committed, { x = 5 })
end

function TestCoordgridEditAxis:testQuantityIsPreferredOverRawText()
    -- The field's suffix-aware quantity (e.g. "1K" -> 1000) wins over the raw string.
    local host = FakeHost.new({ x = 0, z = 0, level = 0 })
    CoordGrid.Press(host, fieldCtrl("x", { x = 0, z = 0, level = 0 }))
    host:Type("1K", 1000)
    luaunit.assertEquals(host.committed.x, 1000)
end

function TestCoordgridEditAxis:testFieldIsSeededFromTheCurrentAxisValue()
    local host = FakeHost.new({ x = 10, z = 20, level = 3 })
    CoordGrid.Press(host, fieldCtrl("level", { x = 10, z = 20, level = 3 }))
    luaunit.assertNotNil(host.mounted)
    luaunit.assertEquals(host.mounted.opts.initial, "3")
    luaunit.assertEquals(host.mounted.opts.filter, "NUMERIC")
end

function TestCoordgridEditAxis:testUnsetAxisSeedsAnEmptyField()
    local host = FakeHost.new({ x = 10 })  -- z/level unset
    CoordGrid.Press(host, fieldCtrl("z", { x = 10 }))
    luaunit.assertEquals(host.mounted.opts.initial, "")
end

--- The one-shot grab action --------------------------------------------------------------

TestCoordgridGrab = {}

function TestCoordgridGrab:setUp()
    -- Player is called by dot (Player.IsAvailable() / Player.GetEntity()), so stubs take no self.
    self.savedPlayer = _G.Player
    local player = { available = true }
    player.IsAvailable = function() return player.available end
    player.GetEntity = function() return { coordGrid = { x = 3200, z = 3200, level = 1 } } end
    _G.Player = player
end

function TestCoordgridGrab:tearDown()
    _G.Player = self.savedPlayer
end

function TestCoordgridGrab:testActionGrabsTheLivePlayerPosition()
    local host = FakeHost.new(nil)
    CoordGrid.Press(host, { kind = "action", pinName = "target" })
    luaunit.assertEquals(host.committed, { x = 3200, z = 3200, level = 1 })
end

function TestCoordgridGrab:testActionIsANoOpWhenPlayerUnavailable()
    _G.Player.available = false
    local host = FakeHost.new(nil)
    CoordGrid.Press(host, { kind = "action", pinName = "target" })
    luaunit.assertNil(host.committed)
end

--- Display projection ---------------------------------------------------------------------

TestCoordgridDisplay = {}

function TestCoordgridDisplay:testFieldShowsItsOwnAxis()
    luaunit.assertEquals(CoordGrid.Display({ kind = "field", axis = "z", value = { x = 10, z = 20, level = 0 } }), "20")
end

function TestCoordgridDisplay:testUnsetAxisShowsEmpty()
    luaunit.assertEquals(CoordGrid.Display({ kind = "field", axis = "level", value = { x = 10 } }), "")
end

function TestCoordgridDisplay:testActionShowsTheButtonLabel()
    luaunit.assertEquals(CoordGrid.Display({ kind = "action" }), "Set to current position")
end

--- Geometry the Node delegates to ---------------------------------------------------------

TestCoordgridGeometryDelegation = {}

function TestCoordgridGeometryDelegation:testReservedHeightIsTheBandConstant()
    local Theme = require("src/ui/theme")
    luaunit.assertEquals(CoordGrid.ReservedHeight({}), Theme.COORDGRID_BAND_H)
end

function TestCoordgridGeometryDelegation:testLayoutProducesThreeFieldsAndOneAction()
    local band = { x = 10, y = 100, w = 170, h = CoordGrid.ReservedHeight({}) }
    local rects = CoordGrid.Layout(band)
    luaunit.assertEquals(#rects, 4)
    local axes, actions = {}, 0
    for _, r in ipairs(rects) do
        if r.kind == "field" then axes[r.axis] = true
        elseif r.kind == "action" then actions = actions + 1 end
        luaunit.assertTrue(r.x >= band.x - 1e-9)
        luaunit.assertTrue(r.x + r.w <= band.x + band.w + 1e-9)
        luaunit.assertTrue(r.y >= band.y - 1e-9)
        luaunit.assertTrue(r.y + r.h <= band.y + band.h + 1e-9)
    end
    luaunit.assertTrue(axes.x and axes.z and axes.level)
    luaunit.assertEquals(actions, 1)
    local fields = {}
    for _, r in ipairs(rects) do
        if r.kind == "field" then fields[#fields + 1] = r.axis end
    end
    luaunit.assertEquals(fields, { "level", "x", "z" })
    luaunit.assertTrue(rects[1].x < rects[2].x and rects[2].x < rects[3].x)
end

return {}
