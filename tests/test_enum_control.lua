-- enum Pin Control (ADR-0005 / #59) through the fake host. Round-trips by LABEL
-- (ADR-0004: ComboField id is unreliable). Nil-valued "None" must commit nil, not drop the pick.

local luaunit = require("luaunit")
local FakeHost = require("fake_control_host")
local Enum = require("ui/controls/enum")

local boolEnum = Enum.new({ { value = true, label = "true" }, { value = false, label = "false" } })
-- Mirrors the toast icon spec: a nil-valued "None" plus real sprite ids.
local iconEnum = Enum.new({ { value = nil, label = "None" }, { value = 431, label = "Coins" },
    { value = 12764, label = "Star" } })

local function fieldCtrl(value)
    return { kind = "field", pinName = "flag", value = value, x = 0, y = 0, w = 60, h = 16 }
end

--- Picking through press -> mount -> select ----------------------------------------------

TestEnumSelect = {}

function TestEnumSelect:testPickCommitsTheChosenValue()
    local host = FakeHost.new(true)
    boolEnum.Press(host, fieldCtrl(true))
    host:Pick("false")
    luaunit.assertEquals(host.committed, false)
end

function TestEnumSelect:testSelectionRoundTripsByLabel()
    local host = FakeHost.new(431)
    iconEnum.Press(host, fieldCtrl(431))
    host:Pick("Star")
    luaunit.assertEquals(host.committed, 12764)
end

function TestEnumSelect:testNilValuedNoneCommitsNil()
    -- The "None" choice's value is nil, but picking it is a REAL commit (commitCount rises), not a
    -- dropped pick - the Widget's `found` flag is what distinguishes the two.
    local host = FakeHost.new(431)
    iconEnum.Press(host, fieldCtrl(431))
    host:Pick("None")
    luaunit.assertNil(host.committed)
    luaunit.assertEquals(host.commitCount, 1)
end

function TestEnumSelect:testDropdownSeededToTheCurrentLabel()
    local host = FakeHost.new(false)
    boolEnum.Press(host, fieldCtrl(false))
    luaunit.assertEquals(host.mounted.opts.initial, "false")
    luaunit.assertEquals(host.mounted.opts.labels, { "true", "false" })
end

function TestEnumSelect:testUnmatchedValueSeedsToTheFirstLabel()
    local host = FakeHost.new(999)  -- no such sprite id
    iconEnum.Press(host, fieldCtrl(999))
    luaunit.assertEquals(host.mounted.opts.initial, "None")
end

--- Display projection ---------------------------------------------------------------------

TestEnumDisplay = {}

function TestEnumDisplay:testShowsTheLabelForTheValue()
    luaunit.assertEquals(boolEnum.Display(fieldCtrl(true)), "true")
    luaunit.assertEquals(iconEnum.Display(fieldCtrl(431)), "Coins")
end

function TestEnumDisplay:testNilValueShowsItsNoneLabel()
    luaunit.assertEquals(iconEnum.Display(fieldCtrl(nil)), "None")
end

function TestEnumDisplay:testUnmatchedNilShowsEmpty()
    -- bool has no nil-valued choice, so an unset bool has no label at all -> empty.
    luaunit.assertEquals(boolEnum.Display(fieldCtrl(nil)), "")
end

--- Geometry the Node delegates to ---------------------------------------------------------

TestEnumLayout = {}

function TestEnumLayout:testInlineSingleFieldRect()
    luaunit.assertTrue(boolEnum.Inline)
    luaunit.assertEquals(boolEnum.ReservedHeight({}), 0)
    local rects = boolEnum.Layout({ x = 0, y = 0, w = 60, h = 16 })
    luaunit.assertEquals(#rects, 1)
    -- Dropdown caret is the Widget's own draw (#63); the sub-rect is a plain field with no "enum" hint.
    luaunit.assertEquals(rects[1].kind, "field")
end

return {}
