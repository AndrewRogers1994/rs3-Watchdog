-- Preset library: the PersistentDB key `presets` (no watchdog_ prefix), beside the Scope Buckets.
-- Builds real graphs through LibNodeGraph. Does not mount PrettyUI.

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

local Store = require("src/store")
local Presets = require("src/presets")
local Registry = require("registry")
local Controls = require("src/ui/controls")
-- Node files register their own tags. Eligibility must follow that registration.
require("src/nodes/triggers/skill")
require("src/nodes/actions/screen_marker")

local function newFakePersistentDB()
    local db = { data = {} }
    function db:GetString(key) return self.data[key] end
    function db:SetString(key, value) self.data[key] = value end
    function db:Delete(key) self.data[key] = nil end
    return db
end

TestPresets = {}

function TestPresets:setUp()
    self.registry = Registry.new()
    self.registry:RegisterNodeType("fixture.trigger", {
        category = "trigger",
        pins = { { name = "out", kind = "exec", direction = "out" } },
        run = function(ctx) ctx:Fire("out") end,
    })
    self.registry:RegisterNodeType("fixture.note", {
        category = "action",
        pins = {
            { name = "in", kind = "exec", direction = "in" },
            { name = "text", kind = "data", direction = "in", default = "" },
            { name = "out", kind = "exec", direction = "out" },
        },
        run = function() end,
    })
    Controls.Register("fixture.mode", {
        widget = "mode",
        modes = { { key = "a", label = "A", enabled = true } },
    })
    Controls.Register("fixture.laterEnum", {
        widget = "enum",
        choices = {
            { value = "one", label = "One" },
            { value = "two", label = "Two" },
        },
    })
    self.registry:RegisterNodeType("fixture.popup", {
        category = "action",
        displayName = "Popup",
        pins = {
            { name = "in", kind = "exec", direction = "in" },
            { name = "body", kind = "data", direction = "in", dataType = "string", default = "" },
            { name = "hold", label = "Hold (seconds)", kind = "data", direction = "in", dataType = "number", default = 4 },
            { name = "theme", label = "Theme", kind = "data", direction = "in", dataType = "bool", default = true },
            { name = "swatch", kind = "data", direction = "in", dataType = "color" },
            { name = "where", kind = "data", direction = "in", dataType = "coordgrid" },
            { name = "shot", kind = "data", direction = "in", dataType = "screen_marker.rect" },
            { name = "op", kind = "data", direction = "in", dataType = "compareOperation", default = "==" },
            { name = "style", kind = "data", direction = "in", dataType = "fixture.mode", default = "a" },
            { name = "later", kind = "data", direction = "in", dataType = "fixture.laterEnum", default = "one" },
            { name = "skillPin", kind = "data", direction = "in", dataType = "skill", default = "any" },
            { name = "out", kind = "exec", direction = "out" },
            { name = "echo", kind = "data", direction = "out", dataType = "string" },
        },
        run = function() end,
    })
    self.registry:RegisterNodeType("fixture.matcher", {
        category = "trigger",
        displayName = "Game Message",
        pins = {
            { name = "contains", kind = "data", direction = "in", dataType = "matcher",
              label = "Message contains", default = { needle = "boss", mode = "pattern" } },
            { name = "out", kind = "exec", direction = "out" },
        },
        run = function() end,
    })
    self.registry:RegisterNodeType("fixture.source", {
        category = "value",
        displayName = "Source",
        pins = {
            { name = "text", kind = "data", direction = "out", dataType = "string" },
        },
        run = function() end,
    })
    PersistentDB = newFakePersistentDB()
end

function TestPresets:tearDown()
    PersistentDB = nil
end

function TestPresets:testMissingKeyLoadsAsEmptyVersion1()
    local doc, err = Presets.Load()
    luaunit.assertNil(err)
    luaunit.assertEquals(doc.version, 1)
    luaunit.assertEquals(doc.presets, {})
    luaunit.assertNil(PersistentDB.data["presets"])
    local keys = {}
    for key in pairs(doc) do keys[#keys + 1] = key end
    table.sort(keys)
    luaunit.assertEquals(keys, { "presets", "version" })
end

function TestPresets:testBadVersionIsLeftOnDisk()
    local raw = '{"version":2,"presets":[]}'
    PersistentDB:SetString("presets", raw)
    local doc, err = Presets.Load()
    luaunit.assertNil(doc)
    luaunit.assertNotNil(err)
    luaunit.assertEquals(PersistentDB:GetString("presets"), raw)
end

function TestPresets:testBadDocumentRefusesAWrite()
    local raw = '{"version":2,"presets":[]}'
    PersistentDB:SetString("presets", raw)
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("fixture.trigger")
    local preset, err = Presets.Add("Kept", graph, {})
    luaunit.assertNil(preset)
    luaunit.assertNotNil(err)
    luaunit.assertEquals(PersistentDB:GetString("presets"), raw)

    PersistentDB:SetString("presets", "{not json")
    local rawBroken = PersistentDB:GetString("presets")
    preset, err = Presets.Add("Kept", graph, {})
    luaunit.assertNil(preset)
    luaunit.assertNotNil(err)
    luaunit.assertEquals(PersistentDB:GetString("presets"), rawBroken)
end

function TestPresets:testSaveTrimsNameAndMintsOneOnAnEmptyLibrary()
    local graph = LibNodeGraph.NewGraph(self.registry)
    local nodeId = graph:AddNode("fixture.trigger")
    local preset, err = Presets.Add("  Alpha  ", graph, { [nodeId] = { x = 4, y = 8 } })
    luaunit.assertNil(err)
    luaunit.assertEquals(preset.id, 1)
    luaunit.assertEquals(preset.name, "Alpha")
    luaunit.assertEquals(preset.variables, {})

    local again = Presets.Add("Alpha", graph, {})
    luaunit.assertEquals(again.id, 2)
    luaunit.assertEquals(again.name, "Alpha")

    local doc = Presets.Load()
    luaunit.assertEquals(#doc.presets, 2)
    luaunit.assertEquals(doc.presets[1].name, "Alpha")
    luaunit.assertEquals(doc.presets[2].id, 2)
end

function TestPresets:testMintIdIsOnePastTheHighestIdStillPresent()
    local seeded = {
        version = 1,
        presets = {
            {
                id = 2,
                name = "low",
                graph = { version = 1, nodes = {}, connections = {} },
                layout = {},
                variables = {},
            },
            {
                id = 4,
                name = "high",
                graph = { version = 1, nodes = {}, connections = {} },
                layout = {},
                variables = {},
            },
        },
    }
    PersistentDB:SetString("presets", LibNodeGraph.Json.Default.encode(seeded))
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("fixture.trigger")
    local preset = Presets.Add("next", graph, {})
    luaunit.assertEquals(preset.id, 5)
    local doc = Presets.Load()
    luaunit.assertEquals(#doc.presets, 3)
    local keys = {}
    for key in pairs(doc) do keys[#keys + 1] = key end
    table.sort(keys)
    luaunit.assertEquals(keys, { "presets", "version" })
end

function TestPresets:testSaveCopiesGraphLayoutAndEmptyVariables()
    local raw = {
        version = 1,
        nodes = {
            { id = 1, type = "fixture.trigger", controls = {} },
            { id = 2, type = "fixture.note", controls = { text = "keep" } },
            { id = 3, type = "gone.type", controls = { hold = "stashed" } },
        },
        connections = {
            { fromNode = 1, fromPin = "out", toNode = 2, toPin = "in" },
        },
    }
    local graph = LibNodeGraph.Deserialize(raw, self.registry, { onUnknown = "placeholder" })
    local layout = {
        [1] = { x = 10, y = 20 },
        [2] = { x = 30, y = 40 },
        [3] = { x = 5, y = 6 },
    }
    local preset = Presets.Add("  Enrage callout  ", graph, layout)
    luaunit.assertEquals(preset.name, "Enrage callout")

    local keys = {}
    for key in pairs(preset) do keys[#keys + 1] = key end
    table.sort(keys)
    luaunit.assertEquals(keys, { "graph", "id", "layout", "name", "variables" })
    luaunit.assertEquals(preset.variables, {})
    luaunit.assertEquals(preset.layout, {
        { id = 1, x = 10, y = 20 },
        { id = 2, x = 30, y = 40 },
        { id = 3, x = 5, y = 6 },
    })
    luaunit.assertEquals(preset.graph.nodes[1].id, 1)
    luaunit.assertEquals(preset.graph.nodes[1].type, "fixture.trigger")
    luaunit.assertEquals(preset.graph.nodes[2].id, 2)
    luaunit.assertEquals(preset.graph.nodes[2].type, "fixture.note")
    luaunit.assertEquals(preset.graph.nodes[2].controls.text, "keep")
    luaunit.assertEquals(preset.graph.nodes[3].id, 3)
    luaunit.assertEquals(preset.graph.nodes[3].type, "gone.type")
    luaunit.assertEquals(preset.graph.nodes[3].controls.hold, "stashed")
    luaunit.assertEquals(preset.graph.connections[1].fromNode, 1)
    luaunit.assertEquals(preset.graph.connections[1].fromPin, "out")
    luaunit.assertEquals(preset.graph.connections[1].toNode, 2)
    luaunit.assertEquals(preset.graph.connections[1].toPin, "in")

    graph:SetControl(2, "text", "changed")
    graph:AddNode("fixture.trigger")
    local doc = Presets.Load()
    luaunit.assertEquals(#doc.presets[1].graph.nodes, 3)
    luaunit.assertEquals(doc.presets[1].graph.nodes[2].controls.text, "keep")
    luaunit.assertEquals(doc.presets[1].name, "Enrage callout")
end

function TestPresets:testListUsesCaseInsensitiveNaturalOrder()
    local function preset(id, name)
        return {
            id = id,
            name = name,
            graph = { version = 1, nodes = {}, connections = {} },
            layout = {},
            variables = {},
        }
    end
    local seeded = {
        version = 1,
        presets = {
            preset(3, "Alert 10"),
            preset(1, "Alert 2"),
            preset(2, "Alert2"),
            preset(4, "alert 2"),
            preset(10, "B"),
            preset(11, "a"),
            preset(8, "img2"),
            preset(7, "img1"),
            preset(6, "img01"),
            preset(5, "img.2"),
        },
    }
    PersistentDB:SetString("presets", LibNodeGraph.Json.Default.encode(seeded))
    local listed, err = Presets.List()
    luaunit.assertNil(err)
    local ids = {}
    for i, presetRow in ipairs(listed) do ids[i] = presetRow.id end
    -- "a" before "B" (case fold). "Alert 2", "Alert2", and "alert 2" compare equal, so lower id first.
    -- "Alert 2" before "Alert 10". "img.2" before "img01" before "img1" before "img2" (dots and padding).
    luaunit.assertEquals(ids, { 11, 1, 2, 4, 3, 10, 5, 6, 7, 8 })
    local stored = Presets.Load()
    luaunit.assertEquals(stored.presets[1].id, 3)
    local storedKeys = {}
    for key in pairs(stored.presets[1]) do storedKeys[#storedKeys + 1] = key end
    table.sort(storedKeys)
    luaunit.assertEquals(storedKeys, { "graph", "id", "layout", "name", "variables" })
end

function TestPresets:testInstantiateWritesAnEnabledAlertIntoTheCallerBucket()
    local raw = {
        version = 1,
        nodes = {
            { id = 1, type = "fixture.trigger", controls = {} },
            { id = 2, type = "fixture.note", controls = { text = "keep" } },
            { id = 3, type = "gone.type", controls = { hold = "stashed" } },
        },
        connections = {
            { fromNode = 1, fromPin = "out", toNode = 2, toPin = "in" },
        },
    }
    local graph = LibNodeGraph.Deserialize(raw, self.registry, { onUnknown = "placeholder" })
    local preset = Presets.Add("Enrage callout", graph, {
        [1] = { x = 10, y = 20 },
        [2] = { x = 30, y = 40 },
        [3] = { x = 5, y = 6 },
    })
    local before = PersistentDB:GetString("presets")

    local bucket = Store.Empty()
    local existing = LibNodeGraph.NewGraph(self.registry)
    existing:AddNode("fixture.trigger")
    Store.InsertEntry(bucket, Store.NewAlertEntry(7, "existing", existing, {}, true))

    local entry, live, layout, err = Presets.Instantiate(bucket, preset.id, self.registry)
    luaunit.assertNil(err)
    luaunit.assertEquals(entry.id, 8)
    luaunit.assertEquals(entry.kind, "alert")
    luaunit.assertEquals(entry.name, "Enrage callout")
    luaunit.assertEquals(entry.enabled, true)
    local entryKeys = {}
    for key in pairs(entry) do entryKeys[#entryKeys + 1] = key end
    table.sort(entryKeys)
    luaunit.assertEquals(entryKeys, { "enabled", "graph", "id", "kind", "layout", "name" })
    luaunit.assertEquals(#bucket.entries, 2)
    luaunit.assertEquals(bucket.entries[2].id, 8)
    luaunit.assertEquals(entry.graph.nodes[1].id, 1)
    luaunit.assertEquals(entry.graph.nodes[2].id, 2)
    luaunit.assertEquals(entry.graph.nodes[2].controls.text, "keep")
    luaunit.assertEquals(entry.graph.nodes[3].id, 3)
    luaunit.assertEquals(entry.graph.nodes[3].type, "gone.type")
    luaunit.assertEquals(entry.graph.nodes[3].controls.hold, "stashed")
    luaunit.assertEquals(entry.layout, {
        { id = 1, x = 10, y = 20 },
        { id = 2, x = 30, y = 40 },
        { id = 3, x = 5, y = 6 },
    })
    luaunit.assertEquals(layout[1].x, 10)
    luaunit.assertEquals(layout[2].y, 40)
    luaunit.assertEquals(live:GetControl(2, "text"), "keep")
    luaunit.assertEquals(PersistentDB:GetString("presets"), before)

    live:SetControl(2, "text", "edited")
    luaunit.assertEquals(Presets.Load().presets[1].graph.nodes[2].controls.text, "keep")
end

function TestPresets:testInstantiateRefusesAPresetThatHasVariables()
    local seeded = {
        version = 1,
        presets = {
            {
                id = 1,
                name = "Needs values",
                graph = {
                    version = 1,
                    nodes = { { id = 1, type = "fixture.note", controls = { text = "keep" } } },
                    connections = {},
                },
                layout = { { id = 1, x = 0, y = 0 } },
                variables = { { nodeId = 1, pinName = "text" } },
            },
        },
    }
    PersistentDB:SetString("presets", LibNodeGraph.Json.Default.encode(seeded))
    local before = PersistentDB:GetString("presets")
    local bucket = Store.Empty()
    local entry, _, _, err = Presets.Instantiate(bucket, 1, self.registry)
    luaunit.assertNil(entry)
    luaunit.assertEquals(err, "variables")
    luaunit.assertEquals(bucket.entries, {})
    luaunit.assertEquals(PersistentDB:GetString("presets"), before)
end

function TestPresets:testScopeSaveLeavesPresetsKeyUnchanged()
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("fixture.trigger")
    Presets.Add("Alpha", graph, {})
    local before = PersistentDB:GetString("presets")

    local bucket = Store.Empty()
    Store.InsertEntry(bucket, Store.NewAlertEntry(1, "New Alert", graph, {}, true))
    luaunit.assertTrue(Store.SaveTo("global", bucket))
    luaunit.assertTrue(Store.SaveTo(Store.PlayerKey("99"), bucket))
    luaunit.assertEquals(PersistentDB:GetString("presets"), before)
    luaunit.assertNotNil(PersistentDB.data["global"])
    luaunit.assertNil(PersistentDB.data["watchdog_presets"])
end

function TestPresets:testNameLongerThan80IsNotSaved()
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("fixture.trigger")
    local tooLong = Presets.Add(string.rep("a", 81), graph, {})
    luaunit.assertNil(tooLong)
    luaunit.assertNil(PersistentDB.data["presets"])
    local capped = Presets.Add(string.rep("b", 80), graph, {})
    luaunit.assertEquals(capped.name, string.rep("b", 80))
end

function TestPresets:testInstantiateRefusesAnUnreadableLibrary()
    PersistentDB:SetString("presets", "{not json")
    local before = PersistentDB:GetString("presets")
    local bucket = Store.Empty()
    local entry = Presets.Instantiate(bucket, 1, self.registry)
    luaunit.assertNil(entry)
    luaunit.assertEquals(#bucket.entries, 0)
    luaunit.assertEquals(PersistentDB:GetString("presets"), before)
end

function TestPresets:testBlankNameIsNotSaved()
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("fixture.trigger")
    local preset, err = Presets.Add("   ", graph, {})
    luaunit.assertNil(preset)
    luaunit.assertNotNil(err)
    luaunit.assertNil(PersistentDB.data["presets"])
    preset = Presets.Add("", graph, {})
    luaunit.assertNil(preset)
    luaunit.assertNil(PersistentDB.data["presets"])
end

function TestPresets:testUnreadableJsonIsLeftOnDisk()
    local raw = "{not json"
    PersistentDB:SetString("presets", raw)
    local doc, err = Presets.Load()
    luaunit.assertNil(doc)
    luaunit.assertNotNil(err)
    luaunit.assertEquals(PersistentDB:GetString("presets"), raw)
end

-- Text, number, enum, and a Matcher needle. Widget kind decides, including a tag registered
-- only by a node file (`skill`) and one registered in this test (`fixture.laterEnum`).
-- Swatch, coordgrid, capture, mode, exec, and data-out pins are absent. The node name is not a mark.
function TestPresets:testUnconnectedTextNumberEnumAndMatcherNeedleCanBeMarked()
    local graph = LibNodeGraph.NewGraph(self.registry)
    local popup = graph:AddNode("fixture.popup")
    local match = graph:AddNode("fixture.matcher")
    graph.nodes[popup].name = "Enrage callout"
    luaunit.assertEquals(Presets.Eligible(graph), {
        { nodeId = popup, pinName = "body" },
        { nodeId = popup, pinName = "hold" },
        { nodeId = popup, pinName = "theme" },
        { nodeId = popup, pinName = "op" },
        { nodeId = popup, pinName = "later" },
        { nodeId = popup, pinName = "skillPin" },
        { nodeId = match, pinName = "contains" },
    })
end

function TestPresets:testConnectedPinAndPlaceholderCannotBeMarked()
    local raw = {
        version = 1,
        nodes = {
            { id = 1, type = "fixture.source", controls = {} },
            { id = 2, type = "fixture.popup", controls = { body = "wired", hold = 4 } },
            { id = 3, type = "gone.type", controls = { hold = "stashed" } },
        },
        connections = {
            { fromNode = 1, fromPin = "text", toNode = 2, toPin = "body" },
        },
    }
    local graph = LibNodeGraph.Deserialize(raw, self.registry, { onUnknown = "placeholder" })
    luaunit.assertEquals(Presets.Eligible(graph), {
        { nodeId = 2, pinName = "hold" },
        { nodeId = 2, pinName = "theme" },
        { nodeId = 2, pinName = "op" },
        { nodeId = 2, pinName = "later" },
        { nodeId = 2, pinName = "skillPin" },
    })
end

function TestPresets:testAddStoresMarksByNodeIdThenPinOrder()
    local graph = LibNodeGraph.NewGraph(self.registry)
    local popup = graph:AddNode("fixture.popup")
    local match = graph:AddNode("fixture.matcher")
    local preset, err = Presets.Add("Callout", graph, {
        [popup] = { x = 1, y = 2 },
        [match] = { x = 3, y = 4 },
    }, {
        { nodeId = match, pinName = "contains", label = "nope" },
        { nodeId = popup, pinName = "hold" },
        { nodeId = popup, pinName = "body" },
        { nodeId = popup, pinName = "body" },
    })
    luaunit.assertNil(err)
    luaunit.assertEquals(preset.variables, {
        { nodeId = popup, pinName = "body" },
        { nodeId = popup, pinName = "hold" },
        { nodeId = match, pinName = "contains" },
    })
    local stored = Presets.Load()
    luaunit.assertEquals(stored.presets[1].variables, {
        { nodeId = popup, pinName = "body" },
        { nodeId = popup, pinName = "hold" },
        { nodeId = match, pinName = "contains" },
    })
    local keys = {}
    for key in pairs(stored.presets[1].variables[1]) do keys[#keys + 1] = key end
    table.sort(keys)
    luaunit.assertEquals(keys, { "nodeId", "pinName" })
    luaunit.assertEquals(stored.presets[1].name, "Callout")
end

function TestPresets:testIneligibleMarkRefusesTheAdd()
    local graph = LibNodeGraph.NewGraph(self.registry)
    local popup = graph:AddNode("fixture.popup")
    local source = graph:AddNode("fixture.source")
    graph:Connect(source, "text", popup, "body")
    local before = PersistentDB:GetString("presets")
    local preset, err = Presets.Add("Callout", graph, {}, {
        { nodeId = popup, pinName = "hold" },
        { nodeId = popup, pinName = "body" },
    })
    luaunit.assertNil(preset)
    luaunit.assertEquals(err, "That control cannot be marked.")
    luaunit.assertEquals(PersistentDB:GetString("presets"), before)

    preset, err = Presets.Add("Callout", graph, {}, {
        { nodeId = popup, pinName = "swatch" },
    })
    luaunit.assertNil(preset)
    luaunit.assertEquals(err, "That control cannot be marked.")
    luaunit.assertNil(PersistentDB.data["presets"])
end

local function markedPopup(registry)
    local graph = LibNodeGraph.NewGraph(registry)
    local popup = graph:AddNode("fixture.popup", {
        body = "saved",
        hold = 4,
        theme = true,
        later = "one",
    })
    local match = graph:AddNode("fixture.matcher", {
        contains = { needle = "boss", mode = "pattern" },
    })
    graph.nodes[popup].name = "Enrage callout"
    local preset, err = Presets.Add("Enrage callout", graph, {
        [popup] = { x = 10, y = 20 },
        [match] = { x = 30, y = 40 },
    }, {
        { nodeId = popup, pinName = "body" },
        { nodeId = popup, pinName = "hold" },
        { nodeId = popup, pinName = "theme" },
        { nodeId = match, pinName = "contains" },
    })
    return preset, err, popup, match
end

function TestPresets:testInstantiateBakesTextNumberEnumAndMatcherNeedle()
    local preset = markedPopup(self.registry)
    local before = PersistentDB:GetString("presets")
    local bucket = Store.Empty()
    local existing = LibNodeGraph.NewGraph(self.registry)
    existing:AddNode("fixture.trigger")
    Store.InsertEntry(bucket, Store.NewAlertEntry(7, "existing", existing, {}, true))

    local entry, live, layout, err = Presets.Instantiate(bucket, preset.id, self.registry, {
        "  keep  ",
        { raw = "1k", quantity = 1000 },
        false,
        "  boss  ",
    })
    luaunit.assertNil(err)
    luaunit.assertEquals(entry.id, 8)
    luaunit.assertEquals(entry.name, "Enrage callout")
    luaunit.assertEquals(entry.enabled, true)
    luaunit.assertEquals(entry.graph.nodes[1].id, 1)
    luaunit.assertEquals(entry.graph.nodes[2].id, 2)
    luaunit.assertEquals(entry.graph.nodes[1].controls.body, "  keep  ")
    luaunit.assertEquals(entry.graph.nodes[1].controls.hold, 1000)
    luaunit.assertEquals(entry.graph.nodes[1].controls.theme, false)
    luaunit.assertEquals(entry.graph.nodes[2].controls.contains, { needle = "  boss  ", mode = "pattern" })
    luaunit.assertEquals(entry.layout, {
        { id = 1, x = 10, y = 20 },
        { id = 2, x = 30, y = 40 },
    })
    luaunit.assertEquals(layout[1].x, 10)
    luaunit.assertEquals(live:GetControl(1, "body"), "  keep  ")
    luaunit.assertEquals(live:GetControl(1, "hold"), 1000)
    luaunit.assertEquals(live:GetControl(1, "theme"), false)
    luaunit.assertEquals(live:GetControl(2, "contains"), { needle = "  boss  ", mode = "pattern" })
    luaunit.assertEquals(PersistentDB:GetString("presets"), before)
    local doc = Presets.Load()
    luaunit.assertEquals(doc.presets[1].graph.nodes[1].controls.body, "saved")
    luaunit.assertEquals(doc.presets[1].graph.nodes[1].controls.hold, 4)
    luaunit.assertEquals(doc.presets[1].graph.nodes[1].controls.theme, true)
    luaunit.assertEquals(doc.presets[1].graph.nodes[2].controls.contains.needle, "boss")
    luaunit.assertEquals(doc.presets[1].graph.nodes[2].controls.contains.mode, "pattern")
end

function TestPresets:testInstantiateBakesEmptyTextAndEmptyNeedle()
    local preset = markedPopup(self.registry)
    local before = PersistentDB:GetString("presets")
    local bucket = Store.Empty()
    local entry, live = Presets.Instantiate(bucket, preset.id, self.registry, {
        "",
        "4",
        true,
        "",
    })
    luaunit.assertEquals(entry.graph.nodes[1].controls.body, "")
    luaunit.assertEquals(live:GetControl(1, "body"), "")
    luaunit.assertEquals(entry.graph.nodes[2].controls.contains, { needle = "", mode = "pattern" })
    luaunit.assertEquals(live:GetControl(2, "contains").mode, "pattern")
    luaunit.assertEquals(PersistentDB:GetString("presets"), before)
end

function TestPresets:testInstantiateRefusesABlankNumberWithoutWritingAnEntry()
    local preset = markedPopup(self.registry)
    local before = PersistentDB:GetString("presets")
    local blanks = { "", "   ", "nope", { raw = "   ", quantity = 0 }, { raw = "", quantity = 0 } }
    for _, hold in ipairs(blanks) do
        local bucket = Store.Empty()
        local entry, _, _, err = Presets.Instantiate(bucket, preset.id, self.registry, {
            "keep",
            hold,
            true,
            "boss",
        })
        luaunit.assertNil(entry)
        luaunit.assertEquals(err, "Enter a number.")
        luaunit.assertEquals(bucket.entries, {})
        luaunit.assertEquals(PersistentDB:GetString("presets"), before)
    end
    local bucket = Store.Empty()
    local entry, live = Presets.Instantiate(bucket, preset.id, self.registry, {
        "keep",
        "0",
        true,
        "boss",
    })
    luaunit.assertEquals(live:GetControl(1, "hold"), 0)
    luaunit.assertEquals(entry.graph.nodes[1].controls.hold, 0)
end

function TestPresets:testInstantiateRefusesAMarkThatDoesNotResolve()
    local seeded = {
        version = 1,
        presets = {
            {
                id = 1,
                name = "Needs values",
                graph = {
                    version = 1,
                    nodes = {
                        { id = 1, type = "fixture.popup", controls = { body = "saved", hold = 4 } },
                        { id = 2, type = "gone.type", controls = { hold = "stashed" } },
                    },
                    connections = {},
                },
                layout = { { id = 1, x = 0, y = 0 } },
                variables = { { nodeId = 1, pinName = "missing" } },
            },
        },
    }
    PersistentDB:SetString("presets", LibNodeGraph.Json.Default.encode(seeded))
    local before = PersistentDB:GetString("presets")
    local bucket = Store.Empty()
    local entry, _, _, err = Presets.Instantiate(bucket, 1, self.registry, { "x" })
    luaunit.assertNil(entry)
    luaunit.assertEquals(err, "A marked control is missing.")
    luaunit.assertEquals(bucket.entries, {})
    luaunit.assertEquals(PersistentDB:GetString("presets"), before)

    seeded.presets[1].variables = { { nodeId = 2, pinName = "hold" } }
    PersistentDB:SetString("presets", LibNodeGraph.Json.Default.encode(seeded))
    before = PersistentDB:GetString("presets")
    bucket = Store.Empty()
    entry, _, _, err = Presets.Instantiate(bucket, 1, self.registry, { "x" })
    luaunit.assertNil(entry)
    luaunit.assertEquals(err, "A marked control is missing.")
    luaunit.assertEquals(bucket.entries, {})
    luaunit.assertEquals(PersistentDB:GetString("presets"), before)
end

function TestPresets:testVariableLabelUsesHeaderTitleAndPinLabel()
    local graph = LibNodeGraph.NewGraph(self.registry)
    local named = graph:AddNode("fixture.popup")
    graph.nodes[named].name = "Enrage callout"
    local unnamed = graph:AddNode("fixture.popup")
    local match = graph:AddNode("fixture.matcher")
    luaunit.assertEquals(Presets.NodeTitle(graph, named), "Popup - Enrage callout")
    luaunit.assertEquals(Presets.NodeTitle(graph, unnamed), "Popup - New Popup")
    luaunit.assertEquals(Presets.MarkLabel(graph, named, "hold"), "Popup - Enrage callout: Hold (seconds)")
    luaunit.assertEquals(Presets.MarkLabel(graph, unnamed, "hold"), "Popup - New Popup: Hold (seconds)")
    luaunit.assertEquals(Presets.MarkLabel(graph, named, "body"), "Popup - Enrage callout: body")
    luaunit.assertEquals(Presets.MarkLabel(graph, match, "contains"), "Game Message - New Game Message: Message contains")
    luaunit.assertEquals(Presets.VariableLabel("Popup", "Enrage callout", "Hold (seconds)"), "Popup - Enrage callout: Hold (seconds)")
end

function TestPresets:testEnumInitialKeepsTheSnapshottedChoiceWhenItIsOffered()
    local choices = {
        { value = "fade", label = "Fade" },
        { value = "instant", label = "Instant" },
    }
    luaunit.assertEquals(Presets.EnumInitial("fade", choices, "instant"), "fade")
    luaunit.assertEquals(Presets.EnumInitial("gone", choices, "instant"), "instant")
    local withNone = {
        { value = nil, label = "None" },
        { value = 1, label = "Tick" },
    }
    luaunit.assertEquals(Presets.EnumInitial(nil, withNone, 1), nil)
    luaunit.assertEquals(Presets.EnumInitial(9, withNone, 1), 1)
end

-- One remaining pin is the whole choice for that node. A node with nothing left is absent.
function TestPresets:testNodesWithNothingLeftToMarkAreAbsent()
    local eligible = {
        { nodeId = 1, pinName = "body" },
        { nodeId = 2, pinName = "hold" },
        { nodeId = 2, pinName = "title" },
        { nodeId = 4, pinName = "contains" },
    }
    luaunit.assertEquals(Presets.UnmarkedNodes(eligible, {
        { nodeId = 4, pinName = "contains" },
    }), {
        { nodeId = 1, pinNames = { "body" } },
        { nodeId = 2, pinNames = { "hold", "title" } },
    })
end
