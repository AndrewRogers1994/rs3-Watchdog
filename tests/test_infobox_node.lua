-- Exercises the action.infobox node (nodes/actions/infobox.lua, #41) through a fake registry
-- + fake ctx driving a real ui/infobox.lua InfoBox Area — no LibNodeGraph required, matching
-- test_popup's convention (a real EffectRegistry driven through a fake registry/ctx).

_G.Vector4 = _G.Vector4 or { new = function(r, g, b, a) return { r, g, b, a } end }

local luaunit = require("luaunit")
local InfoBoxNode = require("nodes/actions/infobox")
local InfoBox = require("ui/infobox")

local function makeFakeRegistry()
    return {
        types = {},
        RegisterNodeType = function(self, key, desc) self.types[key] = desc end,
    }
end

-- `pin` stands in for the ctx.pin BUILD-VERIFY assumption (which exec-in pin fired);
-- omitting it exercises the "update" fallback path.
local function makeCtx(nodeId, values, pin)
    return {
        nodeId = nodeId,
        pin = pin,
        In = function(_self, name) return values[name] end,
    }
end

TestInfoBoxNodeRegistration = {}

function TestInfoBoxNodeRegistration:setUp()
    self.reg = makeFakeRegistry()
    self.area = InfoBox.new()
    InfoBoxNode.Register(self.reg, { infobox = self.area })
    self.desc = self.reg.types["action.infobox"]
end

function TestInfoBoxNodeRegistration:testRegistersActionInfoboxWithUpdateAndDismissExecIns()
    luaunit.assertNotNil(self.desc)
    luaunit.assertEquals(self.desc.category, "action")

    local byName, execOutCount = {}, 0
    for _, pin in ipairs(self.desc.pins) do
        byName[pin.name] = pin
        if pin.kind == "exec" and pin.direction == "out" then execOutCount = execOutCount + 1 end
    end
    luaunit.assertEquals(byName.update.kind, "exec")
    luaunit.assertEquals(byName.update.direction, "in")
    luaunit.assertEquals(byName.dismiss.kind, "exec")
    luaunit.assertEquals(byName.dismiss.direction, "in")
    luaunit.assertEquals(execOutCount, 0) -- no exec-out (AC)
    luaunit.assertEquals(byName.value.dataType, "any")
    luaunit.assertEquals(byName.color.dataType, "color")
    luaunit.assertEquals(byName.icon.dataType, "infobox.icon")
    luaunit.assertEquals(byName.title.dataType, "string")
    luaunit.assertEquals(byName.dismissWhenEmpty.dataType, "bool")
    luaunit.assertFalse(byName.dismissWhenEmpty.default)
end

function TestInfoBoxNodeRegistration:testIconChoicesIncludeNoneAndAreCurated()
    local choices = InfoBoxNode.IconChoices()
    luaunit.assertEquals(choices[1].value, nil)
    luaunit.assertEquals(choices[1].label, "None")
    luaunit.assertTrue(#choices > 1)
end

TestInfoBoxNodeRun = {}

function TestInfoBoxNodeRun:setUp()
    self.reg = makeFakeRegistry()
    self.area = InfoBox.new()
    InfoBoxNode.Register(self.reg, { infobox = self.area })
    self.desc = self.reg.types["action.infobox"]
end

function TestInfoBoxNodeRun:testUpdateLazyCreatesTheTile()
    self.desc.run(makeCtx("n1", { value = 5, title = "HP" }, "update"))
    luaunit.assertTrue(self.area:Has("n1"))
    luaunit.assertEquals(self.area:Get("n1").text, "5")
    luaunit.assertEquals(self.area:Get("n1").title, "HP")
end

function TestInfoBoxNodeRun:testUpdateRewritesInPlaceNotANewTile()
    self.desc.run(makeCtx("n1", { value = 1 }, "update"))
    self.desc.run(makeCtx("n1", { value = 2 }, "update"))
    luaunit.assertEquals(self.area:Count(), 1)
    luaunit.assertEquals(self.area:Get("n1").text, "2")
end

function TestInfoBoxNodeRun:testMissingPinFieldFallsBackToUpdate()
    -- BUILD-VERIFY fallback: a ctx with no `.pin` still lazy-creates/refreshes (never dismiss).
    self.desc.run(makeCtx("n1", { value = "x" }))
    luaunit.assertTrue(self.area:Has("n1"))
end

function TestInfoBoxNodeRun:testDismissRemovesTheTile()
    self.desc.run(makeCtx("n1", { value = 1 }, "update"))
    self.desc.run(makeCtx("n1", {}, "dismiss"))
    luaunit.assertFalse(self.area:Has("n1"))
end

function TestInfoBoxNodeRun:testDismissOnUnknownOwnerIsANoop()
    local ok = pcall(function() self.desc.run(makeCtx("ghost", {}, "dismiss")) end)
    luaunit.assertTrue(ok)
    luaunit.assertFalse(self.area:Has("ghost"))
end

function TestInfoBoxNodeRun:testDismissWhenEmptyRemovesOnEmptyUpdate()
    self.desc.run(makeCtx("n1", { value = 1 }, "update"))
    self.desc.run(makeCtx("n1", { value = 0, dismissWhenEmpty = true }, "update"))
    luaunit.assertFalse(self.area:Has("n1"))
end

function TestInfoBoxNodeRun:testDismissWhenEmptyOffKeepsTheTileOnEmptyUpdate()
    self.desc.run(makeCtx("n1", { value = 1 }, "update"))
    self.desc.run(makeCtx("n1", { value = 0, dismissWhenEmpty = false }, "update"))
    luaunit.assertTrue(self.area:Has("n1"))
    luaunit.assertEquals(self.area:Get("n1").text, "0")
end

function TestInfoBoxNodeRun:testFirstUpdateEmptyWithDismissWhenEmptyNeverAppears()
    self.desc.run(makeCtx("n1", { value = nil, dismissWhenEmpty = true }, "update"))
    luaunit.assertFalse(self.area:Has("n1"))
end

function TestInfoBoxNodeRun:testDifferentNodesGetDifferentTiles()
    self.desc.run(makeCtx("a", { value = 1 }, "update"))
    self.desc.run(makeCtx("b", { value = 2 }, "update"))
    luaunit.assertEquals(self.area:Count(), 2)
end

function TestInfoBoxNodeRun:testNilRuntimeInfoboxIsASilentNoop()
    local reg = makeFakeRegistry()
    InfoBoxNode.Register(reg, {})
    local desc = reg.types["action.infobox"]
    local ok = pcall(function() desc.run(makeCtx("n1", { value = 1 }, "update")) end)
    luaunit.assertTrue(ok)
end

function TestInfoBoxNodeRun:testColorPassesThroughUnmodified()
    local color = { r = 10, g = 20, b = 30, a = 255 }
    self.desc.run(makeCtx("n1", { value = 1, color = color }, "update"))
    luaunit.assertEquals(self.area:Get("n1").color, color)
end
