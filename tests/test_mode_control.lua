-- mode Pin Control (ADR-0005 / #61) driven through the shared FAKE HOST. The object_marker mode
-- multi-select (#40) is a composite BAND of one checkbox row per mode: only enabled rows toggle,
-- disabled rows ("needs render API") are inert. The behavior under test is: Layout produces one
-- "mode" row per mode carrying its enabled flag, Display decorates the label with the disabled
-- reason, and Press flips one enabled row (read-modify-write, siblings preserved) while a disabled
-- row commits nothing.

local luaunit = require("luaunit")
local FakeHost = require("fake_control_host")
local Mode = require("ui/controls/mode")
local Theme = require("ui/theme")

-- A stand-in modes list shaped like ObjectMarker.MODES: one enabled row, some disabled-with-reason.
local MODES = {
    { key = "tile",     label = "Tile",     enabled = true },
    { key = "hull",     label = "Hull",     enabled = false, reason = "needs render API" },
    { key = "outline",  label = "Outline",  enabled = false, reason = "needs render API" },
    { key = "clickbox", label = "Clickbox", enabled = false, reason = "needs render API" },
}

local mode = Mode.new(MODES)

-- One mode checkbox sub-rect, as node.lua hands it to the dispatcher after buildGeoms fills value.
local function modeCtrl(axis, value)
    return { kind = "mode", pinName = "mode", axis = axis, value = value, x = 0, y = 0, w = 170, h = 16 }
end

--- Geometry: one row per mode, within the reserved band -----------------------------------

TestModeLayout = {}

function TestModeLayout:testBandNotInline()
    luaunit.assertNil(mode.Inline)
    luaunit.assertEquals(mode.ReservedHeight({}), Theme.ModeBandH(#MODES))
end

function TestModeLayout:testOneRowPerModeCarryingEnabled()
    local band = { x = 10, y = 100, w = 170, h = mode.ReservedHeight({}) }
    local rects = mode.Layout(band)
    luaunit.assertEquals(#rects, 4)
    local byAxis = {}
    for _, r in ipairs(rects) do
        luaunit.assertEquals(r.kind, "mode")
        byAxis[r.axis] = r
        -- Each row stays within the reserved band.
        luaunit.assertTrue(r.y >= band.y - 1e-9)
        luaunit.assertTrue(r.y + r.h <= band.y + band.h + 1e-9)
    end
    luaunit.assertTrue(byAxis.tile.enabled)
    luaunit.assertFalse(byAxis.hull.enabled)
    for _, axis in ipairs({ "tile", "hull", "outline", "clickbox" }) do
        luaunit.assertNotNil(byAxis[axis])
    end
end

--- Display: decorated label ----------------------------------------------------------------

TestModeDisplay = {}

function TestModeDisplay:testEnabledRowShowsPlainLabel()
    luaunit.assertEquals(mode.Display(modeCtrl("tile", { tile = true })), "Tile")
end

function TestModeDisplay:testDisabledRowAppendsReason()
    luaunit.assertEquals(mode.Display(modeCtrl("hull", nil)), "Hull — needs render API")
end

--- Press: toggle enabled rows read-modify-write, disabled rows inert ----------------------

TestModePress = {}

function TestModePress:testTogglingTileClearsItFromDefaultChecked()
    local host = FakeHost.new({ tile = true })
    mode.Press(host, modeCtrl("tile", { tile = true }))
    luaunit.assertEquals(host.committed.tile, false)
end

function TestModePress:testTogglingTileBackOn()
    local host = FakeHost.new({ tile = false })
    mode.Press(host, modeCtrl("tile", { tile = false }))
    luaunit.assertEquals(host.committed.tile, true)
end

function TestModePress:testFlipBasedOnShownValueNotStored()
    -- The flip is based on ctrl.value (the default-resolved value the row actually shows), so the
    -- first click on a checkbox that reads ticked only because of the pin default clears it.
    local host = FakeHost.new(nil)  -- nothing stored yet
    mode.Press(host, modeCtrl("tile", { tile = true }))  -- shown as ticked via default
    luaunit.assertEquals(host.committed.tile, false)
end

function TestModePress:testTogglePreservesSiblingKeys()
    local host = FakeHost.new({ tile = true, extra = 7 })
    mode.Press(host, modeCtrl("tile", { tile = true, extra = 7 }))
    luaunit.assertEquals(host.committed.tile, false)
    luaunit.assertEquals(host.committed.extra, 7)
end

function TestModePress:testDisabledRowIsInert()
    local host = FakeHost.new({ tile = true })
    mode.Press(host, modeCtrl("hull", { tile = true }))
    luaunit.assertEquals(host.commitCount, 0)  -- a disabled row writes nothing
end

return {}
