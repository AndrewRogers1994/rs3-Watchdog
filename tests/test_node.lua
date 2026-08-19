local luaunit = require("luaunit")
local Theme = require("ui/theme")
local Node = require("ui/node")
local View = require("ui/view")

TestCumulativeRowLayout = {}

local function numberPin(name)
    return { name = name, kind = "data", direction = "in", dataType = "number", default = 0, label = name }
end

function TestCumulativeRowLayout:testScalarOnlyLayoutMatchesFixedStrideFormula()
    -- Regression: with no composite Controls in play (extraH == 0 everywhere), the cumulative
    -- row math must collapse to the old (i - 0.5) * PIN_ROW_HEIGHT formula.
    local pins = { numberPin("a"), numberPin("b"), numberPin("c") }
    local geom = Node.BuildGeometry(pins, 0, 0, Theme.NODE_WIDTH)

    for i, name in ipairs({ "a", "b", "c" }) do
        local expected = Theme.HEADER_HEIGHT + Theme.BODY_PAD_TOP + (i - 0.5) * Theme.PIN_ROW_HEIGHT
        luaunit.assertAlmostEquals(geom.byName[name].cy, expected, 1e-9)
    end

    local expectedHeight = Theme.HEADER_HEIGHT + Theme.BODY_PAD_TOP
        + 3 * Theme.PIN_ROW_HEIGHT + Theme.BODY_PAD_BOTTOM
    luaunit.assertAlmostEquals(geom.h, expectedHeight, 1e-9)
end

function TestCumulativeRowLayout:testCompositeControlPushesLaterRowsDown()
    local pins = {
        numberPin("a"),
        { name = "target", kind = "data", direction = "in", dataType = "coordgrid", label = "target" },
        numberPin("b"),
    }
    local plainGeom = Node.BuildGeometry(
        { numberPin("a"), numberPin("target"), numberPin("b") }, 0, 0, Theme.NODE_WIDTH)
    local geom = Node.BuildGeometry(pins, 0, 0, Theme.NODE_WIDTH)

    -- Row 1 ("a") is unaffected: nothing above it grew.
    luaunit.assertAlmostEquals(geom.byName.a.cy, plainGeom.byName.a.cy, 1e-9)
    -- Row 3 ("b") sits exactly one coordgrid band lower than it would without the composite.
    luaunit.assertAlmostEquals(geom.byName.b.cy, plainGeom.byName.b.cy + Theme.COORDGRID_BAND_H, 1e-9)
    -- The node's own height grew by the same reserved band.
    luaunit.assertAlmostEquals(geom.h, plainGeom.h + Theme.COORDGRID_BAND_H, 1e-9)
end

function TestCumulativeRowLayout:testConnectedCompositePinReservesNoBand()
    -- A connected input shows no Control at all (ADR-0004), so it must not reserve extraH.
    local pins = { { name = "target", kind = "data", direction = "in", dataType = "coordgrid" } }
    local geom = Node.BuildGeometry(pins, 0, 0, Theme.NODE_WIDTH, { connected = { target = true } })
    local expected = Theme.HEADER_HEIGHT + Theme.BODY_PAD_TOP + Theme.PIN_ROW_HEIGHT + Theme.BODY_PAD_BOTTOM
    luaunit.assertAlmostEquals(geom.h, expected, 1e-9)
    luaunit.assertEquals(#geom.controls, 0)
end

TestCoordgridGeometry = {}

function TestCoordgridGeometry:setUp()
    self.pins = { { name = "target", kind = "data", direction = "in", dataType = "coordgrid", label = "target" } }
    self.geom = Node.BuildGeometry(self.pins, 0, 0, Theme.NODE_WIDTH)
end

function TestCoordgridGeometry:testFourControlsShareThePinName()
    luaunit.assertEquals(#self.geom.controls, 4)
    for _, ctrl in ipairs(self.geom.controls) do
        luaunit.assertEquals(ctrl.pinName, "target")
    end
end

function TestCoordgridGeometry:testKindsAreThreeFieldsAndOneAction()
    local kinds = {}
    for _, ctrl in ipairs(self.geom.controls) do
        kinds[#kinds + 1] = ctrl.kind
    end
    table.sort(kinds)
    luaunit.assertEquals(kinds, { "action", "field", "field", "field" })
end

function TestCoordgridGeometry:testBandSitsBelowThePinRowAndSpansFullWidth()
    local pinRow = self.geom.byName.target
    local rowBottom = pinRow.cy + Theme.PIN_ROW_HEIGHT * 0.5
    for _, ctrl in ipairs(self.geom.controls) do
        luaunit.assertTrue(ctrl.y >= rowBottom - 1e-9)
        luaunit.assertTrue(ctrl.x >= Theme.PIN_MARGIN_X - 1e-9)
        luaunit.assertTrue(ctrl.x + ctrl.w <= Theme.NODE_WIDTH - Theme.PIN_MARGIN_X + 1e-9)
    end
end

TestControlAtHitTest = {}

function TestControlAtHitTest:setUp()
    local pins = { { name = "target", kind = "data", direction = "in", dataType = "coordgrid", label = "target" } }
    self.geom = Node.BuildGeometry(pins, 0, 0, Theme.NODE_WIDTH)
    self.view = View.new()
end

function TestControlAtHitTest:testClickingAFieldReturnsThatAxis()
    local field
    for _, ctrl in ipairs(self.geom.controls) do
        if ctrl.kind == "field" and ctrl.axis == "z" then field = ctrl end
    end
    assert(field ~= nil)
    local sx, sy = self.view:ToScreen(self.geom.x + field.x + field.w * 0.5,
        self.geom.y + field.y + field.h * 0.5)
    local hit = Node.ControlAt(self.geom, self.view, sx, sy)
    assert(hit ~= nil)
    luaunit.assertEquals(hit.kind, "field")
    luaunit.assertEquals(hit.axis, "z")
end

function TestControlAtHitTest:testClickingTheButtonReturnsAction()
    local action
    for _, ctrl in ipairs(self.geom.controls) do
        if ctrl.kind == "action" then action = ctrl end
    end
    assert(action ~= nil)
    local sx, sy = self.view:ToScreen(self.geom.x + action.x + action.w * 0.5,
        self.geom.y + action.y + action.h * 0.5)
    local hit = Node.ControlAt(self.geom, self.view, sx, sy)
    assert(hit ~= nil)
    luaunit.assertEquals(hit.kind, "action")
end

function TestControlAtHitTest:testBelowMinZoomNothingIsHittable()
    self.view.zoom = Theme.CONTROL_MIN_ZOOM * 0.5
    local action
    for _, ctrl in ipairs(self.geom.controls) do
        if ctrl.kind == "action" then action = ctrl end
    end
    assert(action ~= nil)
    local sx, sy = self.view:ToScreen(self.geom.x + action.x + action.w * 0.5,
        self.geom.y + action.y + action.h * 0.5)
    luaunit.assertNil(Node.ControlAt(self.geom, self.view, sx, sy))
end

TestPlaceholderGeometry = {}

-- A placeholder node (#53) lays out its reconstructed stubs as plain pins but must offer no
-- interactive geometry: no Control boxes (raw controls are opaque without codecs) and no
-- per-exec-in test buttons (FireInput would assert on a pin the engine can't resolve).
function TestPlaceholderGeometry:setUp()
    -- One exec input stub (would normally spawn a test button) + one data input stub (would
    -- normally spawn a Control box) + one output — none of the interactive parts should appear.
    self.pins = {
        { name = "gate", kind = "exec", direction = "in", label = "gate" },
        { name = "amount", kind = "data", direction = "in", dataType = "number", label = "amount" },
        { name = "result", kind = "data", direction = "out", dataType = "any", label = "result" },
    }
    self.geom = Node.BuildGeometry(self.pins, 0, 0, Theme.NODE_WIDTH, { placeholder = true })
end

function TestPlaceholderGeometry:testMarksGeomAsPlaceholder()
    luaunit.assertTrue(self.geom.placeholder)
end

function TestPlaceholderGeometry:testHasNoControlBoxes()
    luaunit.assertEquals(#self.geom.controls, 0)
end

function TestPlaceholderGeometry:testHasNoTestButtons()
    luaunit.assertEquals(#self.geom.testButtons, 0)
end

function TestPlaceholderGeometry:testStubsStillLayOutAsPins()
    luaunit.assertNotNil(self.geom.byName.gate)
    luaunit.assertNotNil(self.geom.byName.amount)
    luaunit.assertNotNil(self.geom.byName.result)
    luaunit.assertEquals(self.geom.byName.result.direction, "out")
end

-- A non-placeholder node with the same exec-in/data-in pins DOES get the interactive parts —
-- proof the suppression is the flag's doing, not an accident of these pins.
function TestPlaceholderGeometry:testNonPlaceholderSamePinsGetsControlsAndTestButtons()
    local geom = Node.BuildGeometry(self.pins, 0, 0, Theme.NODE_WIDTH)
    luaunit.assertEquals(#geom.testButtons, 1)
    luaunit.assertEquals(#geom.controls, 1)
    luaunit.assertFalse(geom.placeholder)
end

TestSwatchGeometry = {}

function TestSwatchGeometry:setUp()
    self.pins = { { name = "tint", kind = "data", direction = "in", dataType = "color", label = "tint" } }
    self.geom = Node.BuildGeometry(self.pins, 0, 0, Theme.NODE_WIDTH)
    self.view = View.new()
end

function TestSwatchGeometry:testOneSwatchControlIsProduced()
    luaunit.assertEquals(#self.geom.controls, 1)
    local ctrl = self.geom.controls[1]
    luaunit.assertEquals(ctrl.pinName, "tint")
    -- `kind` names the row for press/hit-test; how the chip PAINTS is the swatch Widget's Draw
    -- (#63), routed through the Pin Control — no separate "widget" hint on the sub-rect anymore.
    luaunit.assertEquals(ctrl.kind, "swatch")
end

function TestSwatchGeometry:testChipIsFixedWidthAndStaysWithinTheValueColumn()
    local ctrl = self.geom.controls[1]
    luaunit.assertEquals(ctrl.w, Theme.SWATCH_W)
    luaunit.assertTrue(ctrl.x >= Theme.PIN_MARGIN_X - 1e-9)
    luaunit.assertTrue(ctrl.x + ctrl.w <= Theme.NODE_WIDTH - Theme.PIN_MARGIN_X + 1e-9)
end

function TestSwatchGeometry:testChipDoesNotReserveExtraRowHeight()
    -- Unlike coordgrid's composite band, a swatch is a plain value-column box: no extraH.
    local numberPins = {
        { name = "a", kind = "data", direction = "in", dataType = "number", label = "a" },
        { name = "b", kind = "data", direction = "in", dataType = "number", label = "b" },
    }
    local plainGeom = Node.BuildGeometry(numberPins, 0, 0, Theme.NODE_WIDTH)
    local pins = {
        { name = "a", kind = "data", direction = "in", dataType = "number", label = "a" },
        { name = "tint", kind = "data", direction = "in", dataType = "color", label = "tint" },
    }
    local geom = Node.BuildGeometry(pins, 0, 0, Theme.NODE_WIDTH)
    luaunit.assertAlmostEquals(geom.h, plainGeom.h, 1e-9)
end

function TestSwatchGeometry:testClickingTheChipReturnsTheSwatchControl()
    local ctrl = self.geom.controls[1]
    local sx, sy = self.view:ToScreen(self.geom.x + ctrl.x + ctrl.w * 0.5,
        self.geom.y + ctrl.y + ctrl.h * 0.5)
    local hit = Node.ControlAt(self.geom, self.view, sx, sy)
    luaunit.assertNotNil(hit)
    luaunit.assertEquals(hit.kind, "swatch")
end

function TestSwatchGeometry:testConnectedPinReservesNoSwatchControl()
    local geom = Node.BuildGeometry(self.pins, 0, 0, Theme.NODE_WIDTH, { connected = { tint = true } })
    luaunit.assertEquals(#geom.controls, 0)
end

-- #59/#60: the migrated tags (number/string scalars, the bool enum, the matcher, the color swatch,
-- and the screen/object capture) must route to their Pin Control — every geom.controls entry carries
-- `pinControl` — so buildGeoms/beginPress delegate to the module and never reach the old `kind`/spec
-- switches for these tags.
TestMigratedControlRouting = {}

local Controls = require("ui/controls")

local function inPin(name, dataType)
    return { name = name, kind = "data", direction = "in", dataType = dataType, label = name }
end

function TestMigratedControlRouting:testScalarPinsCarryAPinControl()
    for _, dt in ipairs({ "number", "string" }) do
        local geom = Node.BuildGeometry({ inPin("v", dt) }, 0, 0, Theme.NODE_WIDTH)
        luaunit.assertEquals(#geom.controls, 1)
        luaunit.assertNotNil(geom.controls[1].pinControl)
    end
end

function TestMigratedControlRouting:testEnumPinCarriesAPinControl()
    -- The dropdown caret is the dropdown Widget's own draw (#63), not a "widget" hint on the sub-rect,
    -- so the enum box carries only a Pin Control the Node routes its Draw/Press through.
    local geom = Node.BuildGeometry({ inPin("flag", "bool") }, 0, 0, Theme.NODE_WIDTH)
    luaunit.assertEquals(#geom.controls, 1)
    luaunit.assertNotNil(geom.controls[1].pinControl)
    luaunit.assertEquals(geom.controls[1].kind, "field")
end

function TestMigratedControlRouting:testMatcherPinCarriesAPinControlBand()
    local geom = Node.BuildGeometry({ inPin("contains", "matcher") }, 0, 0, Theme.NODE_WIDTH)
    luaunit.assertEquals(#geom.controls, 2)  -- needle + toggle
    for _, c in ipairs(geom.controls) do luaunit.assertNotNil(c.pinControl) end
end

function TestMigratedControlRouting:testSwatchPinCarriesAPinControl()
    -- The `color` tag is registered by ui/controls.lua itself (loaded via Node), so its swatch Pin
    -- Control is already wired — the chip routes through the module, not the old kind == "swatch" path.
    local geom = Node.BuildGeometry({ inPin("tint", "color") }, 0, 0, Theme.NODE_WIDTH)
    luaunit.assertEquals(#geom.controls, 1)
    luaunit.assertNotNil(geom.controls[1].pinControl)
    luaunit.assertEquals(geom.controls[1].kind, "swatch")
end

function TestMigratedControlRouting:testCapturePinCarriesAPinControl()
    -- Capture specs are registered by their node files; register a stand-in here so the routing is
    -- proven without pulling a whole node module in. A widget == "capture" spec auto-wires its
    -- Pin Control the same way (#60), so the box carries one and never reaches kind == "capture".
    Controls.Register("test.capture60", { widget = "capture", placeholder = "Draw on screen" })
    local geom = Node.BuildGeometry({ inPin("rect", "test.capture60") }, 0, 0, Theme.NODE_WIDTH)
    luaunit.assertEquals(#geom.controls, 1)
    luaunit.assertNotNil(geom.controls[1].pinControl)
    luaunit.assertEquals(geom.controls[1].kind, "capture")
end

function TestMigratedControlRouting:testModePinCarriesAPinControlBand()
    -- #61: the object_marker mode multi-select is a band; register a stand-in mode tag so the
    -- routing is proven without pulling the whole node module in. Each checkbox row carries the
    -- Pin Control and its baked `enabled` flag, and never reaches the old kind == "mode" path.
    Controls.Register("test.mode61", {
        widget = "mode",
        modes = {
            { key = "tile", label = "Tile", enabled = true },
            { key = "hull", label = "Hull", enabled = false, reason = "needs render API" },
        },
    })
    local geom = Node.BuildGeometry({ inPin("mode", "test.mode61") }, 0, 0, Theme.NODE_WIDTH)
    luaunit.assertEquals(#geom.controls, 2)  -- one row per mode
    for _, c in ipairs(geom.controls) do
        luaunit.assertNotNil(c.pinControl)
        luaunit.assertEquals(c.kind, "mode")
    end
    luaunit.assertTrue(geom.controls[1].enabled)   -- tile
    luaunit.assertFalse(geom.controls[2].enabled)  -- hull
end

function TestMigratedControlRouting:testInlineScalarsReserveNoBand()
    -- An inline Pin Control (scalar/enum) adds no reserved band, so a row of them collapses to the
    -- fixed PIN_ROW_HEIGHT stride exactly as the old scalar spec path did.
    local geom = Node.BuildGeometry({ inPin("a", "number"), inPin("b", "string") }, 0, 0, Theme.NODE_WIDTH)
    local expected = Theme.HEADER_HEIGHT + Theme.BODY_PAD_TOP
        + 2 * Theme.PIN_ROW_HEIGHT + Theme.BODY_PAD_BOTTOM
    luaunit.assertAlmostEquals(geom.h, expected, 1e-9)
end

TestNodeModes = {}

function TestNodeModes:testSortedModesOrdersByLabelThenKey()
    local nt = {
        modes = {
            zebra = { key = "zebra", label = "B" },
            alpha = { key = "alpha", label = "A" },
            beta = { key = "beta", label = "A" },
        },
    }
    local list = Node.SortedModes(nt)
    luaunit.assertEquals(#list, 3)
    luaunit.assertEquals(list[1].key, "alpha")
    luaunit.assertEquals(list[2].key, "beta")
    luaunit.assertEquals(list[3].key, "zebra")
end

function TestNodeModes:testModeLabelReservesStripAndPushesPins()
    local pins = { numberPin("a") }
    local plain = Node.BuildGeometry(pins, 0, 0, Theme.NODE_WIDTH)
    local geom = Node.BuildGeometry(pins, 0, 0, Theme.NODE_WIDTH, { modeLabel = "Count" })

    luaunit.assertNotNil(geom.modeStrip)
    luaunit.assertEquals(geom.modeStrip.label, "Count")
    luaunit.assertAlmostEquals(geom.byName.a.cy, plain.byName.a.cy + Theme.MODE_STRIP_H, 1e-9)
    luaunit.assertAlmostEquals(geom.h, plain.h + Theme.MODE_STRIP_H, 1e-9)
    luaunit.assertIsNil(plain.modeStrip)
end
