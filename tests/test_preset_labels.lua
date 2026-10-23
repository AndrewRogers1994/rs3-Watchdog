-- Variable text for the Preset dialog. The Preset library does not own these labels.

local luaunit = require("luaunit")

local Serialize = require("serialize")
local Json = require("json")
LibNodeGraph = {
    NewGraph = require("graph").new,
    Serialize = Serialize.Serialize,
    Deserialize = Serialize.Deserialize,
    Json = Json,
    UNKNOWN_TYPE = require("registry").UNKNOWN_TYPE,
}

local PresetLabels = require("src/ui/preset_labels")
local Packs = require("src/packs")
local Registry = require("registry")

TestPresetLabels = {}

function TestPresetLabels:setUp()
    self.registry = Registry.new()
    self.registry:RegisterNodeType("fixture.popup", {
        category = "action",
        displayName = "Popup",
        pins = {
            { name = "body", kind = "data", direction = "in", dataType = "string", default = "" },
            { name = "hold", label = "Hold (seconds)", kind = "data", direction = "in", dataType = "number", default = 4 },
        },
        run = function() end,
    })
    self.registry:RegisterNodeType("fixture.matcher", {
        category = "trigger",
        displayName = "Game Message",
        pins = {
            { name = "contains", kind = "data", direction = "in", dataType = "matcher",
              label = "Message contains", default = { needle = "boss", mode = "pattern" } },
        },
        run = function() end,
    })
end

function TestPresetLabels:testVariableLabelUsesHeaderTitleAndPinLabel()
    local graph = LibNodeGraph.NewGraph(self.registry)
    local named = graph:AddNode("fixture.popup")
    graph.nodes[named].name = "Enrage callout"
    local unnamed = graph:AddNode("fixture.popup")
    local match = graph:AddNode("fixture.matcher")
    luaunit.assertEquals(PresetLabels.NodeTitle(graph, named), "Popup - Enrage callout")
    luaunit.assertEquals(PresetLabels.NodeTitle(graph, unnamed), "Popup - New Popup")
    luaunit.assertEquals(PresetLabels.MarkLabel(graph, named, "hold"), "Popup - Enrage callout: Hold (seconds)")
    luaunit.assertEquals(PresetLabels.MarkLabel(graph, unnamed, "hold"), "Popup - New Popup: Hold (seconds)")
    luaunit.assertEquals(PresetLabels.MarkLabel(graph, named, "body"), "Popup - Enrage callout: body")
    luaunit.assertEquals(PresetLabels.MarkLabel(graph, match, "contains"), "Game Message - New Game Message: Message contains")
    luaunit.assertEquals(PresetLabels.VariableLabel("Popup", "Enrage callout", "Hold (seconds)"), "Popup - Enrage callout: Hold (seconds)")
end

function TestPresetLabels:testEnumInitialKeepsTheSnapshottedChoiceWhenItIsOffered()
    local choices = {
        { value = "fade", label = "Fade" },
        { value = "instant", label = "Instant" },
    }
    luaunit.assertEquals(PresetLabels.EnumInitial("fade", choices, "instant"), "fade")
    luaunit.assertEquals(PresetLabels.EnumInitial("gone", choices, "instant"), "instant")
    local withNone = {
        { value = nil, label = "None" },
        { value = 1, label = "Tick" },
    }
    luaunit.assertEquals(PresetLabels.EnumInitial(nil, withNone, 1), nil)
    luaunit.assertEquals(PresetLabels.EnumInitial(9, withNone, 1), 1)
end

function TestPresetLabels:testAPackAudioRecordIsNotAskedAsNone()
    local frozen = {
        { value = nil, label = "None" },
        { value = "beep", label = "beep" },
    }
    local stored = { pack = "Voice", authorId = "bell" }
    local value, choices = PresetLabels.EnumSlotValue(stored, frozen, nil, "Voice / bell (missing)")
    luaunit.assertEquals(value, stored)
    luaunit.assertEquals(choices[#choices].value, stored)
    luaunit.assertEquals(choices[#choices].label, "Voice / bell (missing)")
    local live = { pack = "Voice", authorId = "bell" }
    local matched = PresetLabels.EnumSlotValue(stored, {
        { value = nil, label = "None" },
        { value = live, label = "Voice / Bell" },
    }, nil, nil)
    luaunit.assertEquals(matched, live)
end

function TestPresetLabels:testAPackSoundRecordFillsTheNumberFieldWithItsSoundId()
    local packs = Packs.new()
    local record = { pack = "Voice", authorId = "bell", soundId = 12345 }
    luaunit.assertEquals(PresetLabels.NumberVariableText(packs, record), "12345")
    luaunit.assertEquals(PresetLabels.NumberVariableText(packs, 7), "7")
    luaunit.assertEquals(PresetLabels.NumberVariableText(packs, nil), "")
end
