-- Exercises store.lua's document (de)serialization, focused on the alert-model change (#27):
-- each saved graph entry carries a persistent `enabled` flag that survives a serialize ->
-- persist -> load round-trip, defaults to true when absent (older saves), and is preserved by
-- UpsertCurrent when the caller (the editor autosave path) doesn't pass one.
--
-- store.lua reaches its dependencies as globals — `LibNodeGraph` (Serialize/Deserialize/Json)
-- and `PersistentDB`. Neither exists under the bare interpreter, so this suite stands both up:
-- LibNodeGraph from the sibling lib's own modules (already on the path, see run.lua) and a tiny
-- in-memory fake PersistentDB standing in for the client key/value store.

local luaunit = require("luaunit")

-- Build the LibNodeGraph global store.lua expects from the sibling lib's modules (on the path
-- via run.lua). Mirrors what LibNodeGraph/main.lua publishes, minus what store.lua never uses.
local Serialize = require("serialize")
local Json = require("json")
LibNodeGraph = {
    NewGraph = require("graph").new,
    Serialize = Serialize.Serialize,
    Deserialize = Serialize.Deserialize,
    Json = Json,
    UNKNOWN_TYPE = require("registry").UNKNOWN_TYPE,
}

local Store = require("store")
local Registry = require("registry")

-- A minimal in-memory stand-in for the client PersistentDB (string key/value store).
local function newFakePersistentDB()
    local db = { data = {} }
    function db:GetString(key) return self.data[key] end
    function db:SetString(key, value) self.data[key] = value end
    return db
end

TestStore = {}

function TestStore:setUp()
    self.registry = Registry.new()
    -- A trivial trigger type so a saved graph has a real, deserializable node in it.
    self.registry:RegisterNodeType("fixture.trigger", {
        category = "trigger",
        pins = { { name = "out", kind = "exec", direction = "out" } },
        run = function(ctx) ctx:Fire("out") end,
    })
    PersistentDB = newFakePersistentDB()
end

function TestStore:tearDown()
    PersistentDB = nil
end

local function graphWithOneNode(registry)
    local graph = LibNodeGraph.NewGraph(registry)
    graph:AddNode("fixture.trigger")
    return graph
end

-- Full round-trip helper: build a doc, save it through the fake DB, then Load a fresh copy.
local function saveAndReload(doc)
    luaunit.assertTrue(Store.Save(doc))
    return Store.Load()
end

--- enabled flag: default, persistence, and both explicit values ---------------------------

function TestStore:testNewEntryDefaultsEnabledTrue()
    local doc = Store.Empty()
    Store.UpsertCurrent(doc, "alpha", graphWithOneNode(self.registry), {})
    luaunit.assertEquals(doc.graphs[1].enabled, true)
end

function TestStore:testEnabledTrueSurvivesRoundTrip()
    local doc = Store.Empty()
    Store.UpsertCurrent(doc, "alpha", graphWithOneNode(self.registry), {}, true)

    local reloaded = saveAndReload(doc)

    luaunit.assertEquals(reloaded.graphs[1].name, "alpha")
    luaunit.assertEquals(reloaded.graphs[1].enabled, true)
end

function TestStore:testEnabledFalseSurvivesRoundTrip()
    local doc = Store.Empty()
    Store.UpsertCurrent(doc, "alpha", graphWithOneNode(self.registry), {}, false)

    local reloaded = saveAndReload(doc)

    luaunit.assertEquals(reloaded.graphs[1].enabled, false)
end

-- Older saves predate the flag; Restore/RestoreAll must treat a missing `enabled` as true so a
-- pre-#27 document keeps firing after upgrade rather than loading silently disabled.
function TestStore:testMissingEnabledRestoresAsTrue()
    local doc = Store.Empty()
    Store.UpsertCurrent(doc, "alpha", graphWithOneNode(self.registry), {})
    doc.graphs[1].enabled = nil -- simulate a document written before the flag existed

    local restored = Store.RestoreAll(doc, self.registry)

    luaunit.assertEquals(#restored, 1)
    luaunit.assertEquals(restored[1].enabled, true)
end

--- UpsertCurrent preserves the flag when the caller doesn't pass one ----------------------

-- The editor autosave path (main.lua persistNow) re-upserts the current graph every couple of
-- seconds without knowing its enabled state. That must not silently re-arm an alert the user
-- disabled — an omitted `enabled` preserves whatever the entry already had.
function TestStore:testUpsertPreservesExistingEnabledWhenOmitted()
    local doc = Store.Empty()
    Store.UpsertCurrent(doc, "alpha", graphWithOneNode(self.registry), {}, false)

    -- Re-save the same graph as the autosave loop would, passing no enabled argument.
    Store.UpsertCurrent(doc, "alpha", graphWithOneNode(self.registry), {})

    luaunit.assertEquals(doc.graphs[1].enabled, false)
end

--- SetEnabled: the runtime's persistence hook --------------------------------------------

function TestStore:testSetEnabledFlipsExistingEntry()
    local doc = Store.Empty()
    Store.UpsertCurrent(doc, "alpha", graphWithOneNode(self.registry), {}, true)

    luaunit.assertTrue(Store.SetEnabled(doc, "alpha", false))
    luaunit.assertEquals(doc.graphs[1].enabled, false)
end

function TestStore:testSetEnabledReturnsFalseForUnknownName()
    local doc = Store.Empty()
    luaunit.assertFalse(Store.SetEnabled(doc, "ghost", true))
end

function TestStore:testSetEnabledPersistsThroughRoundTrip()
    local doc = Store.Empty()
    Store.UpsertCurrent(doc, "alpha", graphWithOneNode(self.registry), {}, true)
    Store.SetEnabled(doc, "alpha", false)

    local reloaded = saveAndReload(doc)

    luaunit.assertEquals(reloaded.graphs[1].enabled, false)
end

--- RestoreAll: every saved graph comes back live, in order, with its flag -----------------

function TestStore:testRestoreAllReturnsEveryGraphLiveWithFlag()
    local doc = Store.Empty()
    Store.UpsertCurrent(doc, "alpha", graphWithOneNode(self.registry), {}, true)
    Store.UpsertCurrent(doc, "beta", graphWithOneNode(self.registry), {}, false)

    local reloaded = saveAndReload(doc)
    local restored = Store.RestoreAll(reloaded, self.registry)

    luaunit.assertEquals(#restored, 2)
    luaunit.assertEquals(restored[1].name, "alpha")
    luaunit.assertEquals(restored[1].enabled, true)
    luaunit.assertEquals(restored[2].name, "beta")
    luaunit.assertEquals(restored[2].enabled, false)
    -- Each entry carries a live, usable Graph (not the serialized table).
    luaunit.assertEquals(#restored[1].graph:GetNodes(), 1)
    luaunit.assertEquals(#restored[2].graph:GetNodes(), 1)
end

--- Unknown-node preservation (#53): a saved alert with an unregistered type loads as a -----
--- placeholder rather than being skipped, and round-trips losslessly while the type is absent.

-- A stored entry whose graph references a type the reload registry won't have: a known trigger
-- (node 1) wired into an unknown `action.overlay` (node 2). Built as the on-disk serialized
-- shape directly, since the point is that node 2's type is never registered.
local function docWithUnknownNode()
    return {
        version = 1,
        current = "alpha",
        graphs = { {
            name = "alpha",
            enabled = true,
            layout = {},
            graph = {
                version = 1,
                nodes = {
                    { id = 1, type = "fixture.trigger", controls = {} },
                    { id = 2, type = "action.overlay", controls = { text = "hi" } },
                },
                connections = {
                    { fromNode = 1, fromPin = "out", toNode = 2, toPin = "in" },
                },
            },
        } },
    }
end

function TestStore:testUnknownNodeLoadsAsPlaceholderNotSkipped()
    local doc = docWithUnknownNode()

    local restored = Store.RestoreAll(doc, self.registry)

    -- The alert is preserved, not dropped for its one unknown node.
    luaunit.assertEquals(#restored, 1)
    luaunit.assertEquals(restored[1].name, "alpha")
    -- Both nodes come back: the known trigger and the placeholder standing in for the unknown.
    local nodes = restored[1].graph:GetNodes()
    luaunit.assertEquals(#nodes, 2)
    local byId = {}
    for _, n in ipairs(nodes) do byId[n.id] = n.typeKey end
    luaunit.assertEquals(byId[1], "fixture.trigger")
    luaunit.assertEquals(byId[2], LibNodeGraph.UNKNOWN_TYPE)
    -- The wire into the placeholder survives (preserved verbatim).
    luaunit.assertEquals(#restored[1].graph:GetConnections(), 1)
end

function TestStore:testKnownNodesStillFireAlongsideAPlaceholder()
    local doc = docWithUnknownNode()
    local restored = Store.RestoreAll(doc, self.registry)
    -- Firing the known trigger runs through the graph without the placeholder aborting it.
    luaunit.assertEquals(restored[1].graph:Fire(1), nil)
end

function TestStore:testPlaceholderRoundTripsLosslesslyWhileTypeAbsent()
    local first = Store.RestoreAll(docWithUnknownNode(), self.registry)[1]

    -- Re-persist the restored (placeholder-bearing) graph and reload it, exactly as the editor
    -- autosave loop would — the unknown node must re-emit its ORIGINAL type + controls verbatim.
    local doc = Store.Empty()
    Store.UpsertCurrent(doc, first.name, first.graph, first.layout, first.enabled)
    local reloaded = saveAndReload(doc)

    local entry = reloaded.graphs[1]
    luaunit.assertEquals(entry.graph.nodes[2].type, "action.overlay")
    luaunit.assertEquals(entry.graph.nodes[2].controls.text, "hi")

    -- And it still restores to a placeholder (regression: no double-wrapping / drift).
    local second = Store.RestoreAll(reloaded, self.registry)
    luaunit.assertEquals(#second[1].graph:GetNodes(), 2)
    luaunit.assertEquals(#second[1].graph:GetConnections(), 1)
end

-- Once the missing type is registered again, the same saved document loads the REAL node with
-- its original controls + wiring — no placeholder remains.
function TestStore:testPlaceholderRestoresToRealNodeWhenTypeReturns()
    self.registry:RegisterNodeType("action.overlay", {
        category = "action",
        pins = {
            { name = "in", kind = "exec", direction = "in" },
            { name = "text", kind = "data", direction = "in", dataType = "string" },
        },
        run = function() end,
    })

    local restored = Store.RestoreAll(docWithUnknownNode(), self.registry)

    local nodes = restored[1].graph:GetNodes()
    luaunit.assertEquals(#nodes, 2)
    for _, n in ipairs(nodes) do
        luaunit.assertNotEquals(n.typeKey, LibNodeGraph.UNKNOWN_TYPE)
    end
    luaunit.assertEquals(restored[1].graph:GetControl(2, "text"), "hi")
    luaunit.assertEquals(#restored[1].graph:GetConnections(), 1)
end

--- InfoBox Area anchor (#41) --------------------------------------------------------------

function TestStore:testGetInfoBoxAnchorNilOnFreshDocument()
    local doc = Store.Empty()
    local x, y = Store.GetInfoBoxAnchor(doc)
    luaunit.assertNil(x)
    luaunit.assertNil(y)
end

function TestStore:testSetInfoBoxAnchorRoundTrips()
    local doc = Store.Empty()
    Store.SetInfoBoxAnchor(doc, 12, 34)
    local x, y = Store.GetInfoBoxAnchor(doc)
    luaunit.assertEquals(x, 12)
    luaunit.assertEquals(y, 34)
end

function TestStore:testInfoBoxAnchorSurvivesSaveAndLoad()
    local doc = Store.Empty()
    Store.SetInfoBoxAnchor(doc, 12, 34)

    local reloaded = saveAndReload(doc)

    local x, y = Store.GetInfoBoxAnchor(reloaded)
    luaunit.assertEquals(x, 12)
    luaunit.assertEquals(y, 34)
end

return TestStore
