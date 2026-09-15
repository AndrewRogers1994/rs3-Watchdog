-- controls.lua is the Type-Tag -> Pin Control registry (ADR-0005). PinControlFor(tag) is nil for
-- an unregistered tag (ADR-0004: no Pin Control, no Control).

config = config or {}
config.Inv = config.Inv or {}
config.Inv.INV = config.Inv.INV or { id = 93, size = 28 }
config.Inv.BANK = config.Inv.BANK or { id = 95, size = 28 }

local luaunit = require("luaunit")
local Controls = require("ui/controls")

local INV, BANK = config.Inv.INV, config.Inv.BANK

--- Built-in registrations land a Pin Control ----------------------------------------------

TestBuiltinRegistry = {}

function TestBuiltinRegistry:testPrimitiveAndCompositeTagsResolveAPinControl()
    for _, tag in ipairs({ "number", "string", "bool", "color", "coordgrid", "matcher", "toastIcon" }) do
        luaunit.assertNotNil(Controls.PinControlFor(tag), "expected a Pin Control for " .. tag)
    end
end

function TestBuiltinRegistry:testUnregisteredTagHasNoPinControl()
    -- coord/any are intentionally absent, so their pins get no Control (ADR-0004).
    luaunit.assertNil(Controls.PinControlFor("coord"))
    luaunit.assertNil(Controls.PinControlFor("nope.not.a.tag"))
    luaunit.assertNil(Controls.PinControlFor(nil))
end

function TestBuiltinRegistry:testInlineVsBandShape()
    -- Scalars/enums/swatch are inline; the composite bands reserve height.
    luaunit.assertTrue(Controls.PinControlFor("number").Inline)
    luaunit.assertTrue(Controls.PinControlFor("bool").Inline)
    luaunit.assertNil(Controls.PinControlFor("coordgrid").Inline)
    luaunit.assertNil(Controls.PinControlFor("matcher").Inline)
end

--- Register wires each auto-wired widget kind ---------------------------------------------

TestRegisterWiring = {}

function TestRegisterWiring:testEnumDescriptorWiresAnEnumPinControlOverItsChoices()
    Controls.Register("test.enum61", {
        widget = "enum",
        choices = { { value = 1, label = "One" }, { value = 2, label = "Two" } },
    })
    local pc = Controls.PinControlFor("test.enum61")
    luaunit.assertNotNil(pc)
    luaunit.assertEquals(pc.Display({ value = 2 }), "Two")
end

function TestRegisterWiring:testCaptureDescriptorThreadsItsConfig()
    Controls.Register("test.capture61", {
        widget = "capture", captureKind = "object", placeholder = "Pick it",
        format = function(v) return v and v.name or "" end,
    })
    local pc = Controls.PinControlFor("test.capture61")
    luaunit.assertNotNil(pc)
    luaunit.assertEquals(pc.Display({ value = { name = "Anvil" } }), "Anvil")
end

function TestRegisterWiring:testModeDescriptorWiresAModeBand()
    Controls.Register("test.mode61", {
        widget = "mode",
        modes = { { key = "tile", label = "Tile", enabled = true } },
    })
    local pc = Controls.PinControlFor("test.mode61")
    luaunit.assertNotNil(pc)
    luaunit.assertNil(pc.Inline)
    luaunit.assertEquals(pc.Display({ axis = "tile" }), "Tile")
end

function TestRegisterWiring:testRegisterRejectsAWidgetlessDescriptor()
    luaunit.assertErrorMsgContains("needs a widget", function()
        Controls.Register("test.bad61", {})
    end)
end

--- The skill enum (#31): registered by requiring the skill trigger node ------------------

TestSkillControl = {}

function TestSkillControl:setUp()
    require("nodes/triggers/skill")
    self.pc = Controls.PinControlFor("skill")
end

function TestSkillControl:testRegisteredAsAnEnumPinControl()
    luaunit.assertNotNil(self.pc)
    luaunit.assertTrue(self.pc.Inline)
end

function TestSkillControl:testSkillValuesFormatToLabels()
    -- Values are the raw SkillType ids the client delivers on SkillTransmit.skill, so the Control
    -- round-trips against the payload with no name lookup; "any" is the Any default.
    luaunit.assertEquals(self.pc.Display({ value = 0 }), "Attack")
    luaunit.assertEquals(self.pc.Display({ value = 28 }), "Necromancy")
    luaunit.assertEquals(self.pc.Display({ value = "any" }), "Any")
end

TestInvContainerControl = {}

function TestInvContainerControl:setUp()
    config.Inv = { INV = INV, BANK = BANK }
    require("nodes/triggers/inventory")
    self.pc = Controls.PinControlFor("invContainer")
end

function TestInvContainerControl:testRegisteredAsAnEnumPinControl()
    luaunit.assertNotNil(self.pc)
    luaunit.assertTrue(self.pc.Inline)
end

function TestInvContainerControl:testValuesFormatToInventoryAndBank()
    luaunit.assertEquals(self.pc.Display({ value = config.Inv.INV }), "Inventory")
    luaunit.assertEquals(self.pc.Display({ value = config.Inv.BANK }), "Bank")
end

TestInvNoteFilterControl = {}

function TestInvNoteFilterControl:setUp()
    require("nodes/triggers/inventory")
    self.pc = Controls.PinControlFor("invNoteFilter")
end

function TestInvNoteFilterControl:testRegisteredAsAnEnumPinControl()
    luaunit.assertNotNil(self.pc)
    luaunit.assertTrue(self.pc.Inline)
end

function TestInvNoteFilterControl:testValuesFormatToNotedUnnotedBoth()
    luaunit.assertEquals(self.pc.Display({ value = "both" }), "Both")
    luaunit.assertEquals(self.pc.Display({ value = "noted" }), "Noted")
    luaunit.assertEquals(self.pc.Display({ value = "unnoted" }), "Unnoted")
end

return {}
