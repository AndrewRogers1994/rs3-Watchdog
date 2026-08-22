-- controls.lua is the Type-Tag → Pin Control registry (ADR-0005). After #61 deleted the passive
-- Control Spec path, its whole surface is: Register(tag, descriptor) auto-wires a Pin Control by
-- widget kind, RegisterPinControl(tag, module) registers a composite band's module directly, and
-- PinControlFor(tag) resolves the module (nil for an unregistered tag — ADR-0004's "no Pin Control,
-- no Control" rule). These tests exercise that the built-ins and the descriptor kinds each land a
-- Pin Control, and that the per-kind config (an enum's choices) reaches it via its Display.

id = id or {}
id.Inv = id.Inv or {}
id.Inv.INV = id.Inv.INV or 93
id.Inv.BANK = id.Inv.BANK or 95

local luaunit = require("luaunit")
local Controls = require("ui/controls")

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
    -- The choice list reaches the Pin Control: its Display maps a value to that choice's label.
    luaunit.assertEquals(pc.Display({ value = 2 }), "Two")
end

function TestRegisterWiring:testCaptureDescriptorThreadsItsConfig()
    Controls.Register("test.capture61", {
        widget = "capture", captureKind = "object", placeholder = "Pick it",
        format = function(v) return v and v.name or "" end,
    })
    local pc = Controls.PinControlFor("test.capture61")
    luaunit.assertNotNil(pc)
    -- The format hook reaches the Pin Control's Display.
    luaunit.assertEquals(pc.Display({ value = { name = "Anvil" } }), "Anvil")
end

function TestRegisterWiring:testModeDescriptorWiresAModeBand()
    Controls.Register("test.mode61", {
        widget = "mode",
        modes = { { key = "tile", label = "Tile", enabled = true } },
    })
    local pc = Controls.PinControlFor("test.mode61")
    luaunit.assertNotNil(pc)
    luaunit.assertNil(pc.Inline)  -- a band, not inline
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
    require("nodes/triggers/inventory")
    self.pc = Controls.PinControlFor("invContainer")
end

function TestInvContainerControl:testRegisteredAsAnEnumPinControl()
    luaunit.assertNotNil(self.pc)
    luaunit.assertTrue(self.pc.Inline)
end

function TestInvContainerControl:testValuesFormatToInventoryAndBank()
    luaunit.assertEquals(self.pc.Display({ value = 93 }), "Inventory")
    luaunit.assertEquals(self.pc.Display({ value = 95 }), "Bank")
end

return {}
