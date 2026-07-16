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
    Store.UpsertCurrent(doc, "alpha", graphWithOneNode(self.registry), {}, nil)
    luaunit.assertEquals(doc.graphs[1].enabled, true)
end

function TestStore:testEnabledTrueSurvivesRoundTrip()
    local doc = Store.Empty()
    Store.UpsertCurrent(doc, "alpha", graphWithOneNode(self.registry), {}, nil, true)

    local reloaded = saveAndReload(doc)

    luaunit.assertEquals(reloaded.graphs[1].name, "alpha")
    luaunit.assertEquals(reloaded.graphs[1].enabled, true)
end

function TestStore:testEnabledFalseSurvivesRoundTrip()
    local doc = Store.Empty()
    Store.UpsertCurrent(doc, "alpha", graphWithOneNode(self.registry), {}, nil, false)

    local reloaded = saveAndReload(doc)

    luaunit.assertEquals(reloaded.graphs[1].enabled, false)
end

-- Older saves predate the flag; Restore/RestoreAll must treat a missing `enabled` as true so a
-- pre-#27 document keeps firing after upgrade rather than loading silently disabled.
function TestStore:testMissingEnabledRestoresAsTrue()
    local doc = Store.Empty()
    Store.UpsertCurrent(doc, "alpha", graphWithOneNode(self.registry), {}, nil)
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
    Store.UpsertCurrent(doc, "alpha", graphWithOneNode(self.registry), {}, nil, false)

    -- Re-save the same graph as the autosave loop would, passing no enabled argument.
    Store.UpsertCurrent(doc, "alpha", graphWithOneNode(self.registry), {}, nil)

    luaunit.assertEquals(doc.graphs[1].enabled, false)
end

--- SetEnabled: the runtime's persistence hook --------------------------------------------

function TestStore:testSetEnabledFlipsExistingEntry()
    local doc = Store.Empty()
    Store.UpsertCurrent(doc, "alpha", graphWithOneNode(self.registry), {}, nil, true)

    luaunit.assertTrue(Store.SetEnabled(doc, "alpha", false))
    luaunit.assertEquals(doc.graphs[1].enabled, false)
end

function TestStore:testSetEnabledReturnsFalseForUnknownName()
    local doc = Store.Empty()
    luaunit.assertFalse(Store.SetEnabled(doc, "ghost", true))
end

function TestStore:testSetEnabledPersistsThroughRoundTrip()
    local doc = Store.Empty()
    Store.UpsertCurrent(doc, "alpha", graphWithOneNode(self.registry), {}, nil, true)
    Store.SetEnabled(doc, "alpha", false)

    local reloaded = saveAndReload(doc)

    luaunit.assertEquals(reloaded.graphs[1].enabled, false)
end

--- RestoreAll: every saved graph comes back live, in order, with its flag -----------------

function TestStore:testRestoreAllReturnsEveryGraphLiveWithFlag()
    local doc = Store.Empty()
    Store.UpsertCurrent(doc, "alpha", graphWithOneNode(self.registry), {}, nil, true)
    Store.UpsertCurrent(doc, "beta", graphWithOneNode(self.registry), {}, nil, false)

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

return TestStore
