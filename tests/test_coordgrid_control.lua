-- coordgrid Pin Control (ADR-0005 / #58) driven through a FAKE HOST — the tracer-bullet test.
--
-- Good tests exercise external behavior through the highest available seam, not implementation
-- details. For a Pin Control that seam is the host: a test drives a realistic press->commit
-- sequence and asserts the value COMMITTED (recorded by the fake host's Commit), never reaching
-- past the Pin Control's interface into its Widgets. The fake host is the Editor-side analogue
-- of driving a node against a real Graph: a minimal, real-shaped stand-in for the Editor's few
-- capabilities (read the stored Control, commit a new one, mount a transient field), so the
-- interface the test drives is the same one the in-client Editor drives.

local luaunit = require("luaunit")
local CoordGrid = require("ui/controls/coordgrid")
-- The fake host is the Editor-side analogue of driving a node against a real Graph — a minimal,
-- real-shaped stand-in for the Editor's few capabilities (read the stored Control, commit a new
-- one, mount a transient field), so the interface the test drives is the same one the in-client
-- Editor drives. Shared across all the Pin Control tests (tests/fake_control_host.lua).
local FakeHost = require("fake_control_host")

--- Editing an axis through press -> mount -> commit ---------------------------------------

TestCoordgridEditAxis = {}

-- The clicked "field" sub-rect as node.lua hands it to Press: the axis + the default-resolved
-- current value the box shows (ctrl.value), which seeds the transient field's initial content.
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
    -- Two sequential axis edits (each its own press -> mount -> commit) accumulate on the store.
    local host = FakeHost.new({ x = 10, z = 20, level = 0 })
    CoordGrid.Press(host, fieldCtrl("x", { x = 10, z = 20, level = 0 }))
    host:Type("77", 77)
    CoordGrid.Press(host, fieldCtrl("level", host.stored))
    host:Type("2", 2)
    luaunit.assertEquals(host.committed, { x = 77, z = 20, level = 2 })
end

function TestCoordgridEditAxis:testEmptyEditLeavesTheTableAlone()
    -- The empty-box guard: opening a field and clearing it must not clobber the axis (or any
    -- sibling). No commit happens at all.
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
    -- No stored value yet: the first axis edit produces a table with just that axis set, exactly
    -- as the old CommitAxis path did (nil current -> fresh table).
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
    -- Stub the client Player global for the grab-position call the Pin Control makes itself.
    -- The client Player global is called by dot (Player.IsAvailable() / Player.GetEntity()), so
    -- the stub's functions take no self — matching the in-client contract the Pin Control uses.
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
    local Theme = require("ui/theme")
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
        -- Every sub-rect stays within the reserved band.
        luaunit.assertTrue(r.x >= band.x - 1e-9)
        luaunit.assertTrue(r.x + r.w <= band.x + band.w + 1e-9)
        luaunit.assertTrue(r.y >= band.y - 1e-9)
        luaunit.assertTrue(r.y + r.h <= band.y + band.h + 1e-9)
    end
    luaunit.assertTrue(axes.x and axes.z and axes.level)
    luaunit.assertEquals(actions, 1)
end

return {}
