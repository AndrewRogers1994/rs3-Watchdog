-- Exercises runtime.lua's player-scoping + armed/resident lifecycle (#89) through its injected
-- seams: the fake event source (fake_event_source.lua) drives `GameStateChanged`, a fake identity
-- source stands in for the client `Player` read, and a fake Bucket loader stands in for
-- Store.LoadKey + Store.RestoreAll. No client globals are touched - this is the headless proof
-- the acceptance criteria call for.
--
-- The model under test: `global` is armed at plugin start and never disarmed; a character Bucket
-- arms on the GAME transition (identity resolved deferred, on a Logic tick), disarms but stays
-- resident on leaving GAME, and is discarded+reloaded only on a genuine character switch. The fire
-- predicate is exactly *armed Bucket AND enabled* - nothing else.

local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local Runtime = require("runtime")
local newFakeEventSource = require("fake_event_source")

-- GameState.GAME (30, docs core/events.html) and an arbitrary non-GAME state standing in for a
-- logout / world-hop / reconnect - the runtime treats every non-GAME newState identically (leave
-- GAME → disarm), so the exact value doesn't matter to it.
local GAME = 30
local NOT_GAME = 20 -- LOBBY; any newState ~= GAME behaves the same

TestPlayerScoping = {}

-- A fake identity source. Resolve returns the Tracking ID (nil or "" means logged out / empty
-- id). DisplayName is the tab label and is never used as a bucket key.
local function newFakeIdentity(trackingId, displayName)
    local id = { trackingId = trackingId, displayName = displayName }
    function id:Resolve()
        if type(self.trackingId) ~= "string" or self.trackingId == "" then
            return nil
        end
        return self.trackingId
    end
    function id:DisplayName()
        if type(self.displayName) ~= "string" or self.displayName == "" then
            return nil
        end
        return self.displayName
    end
    return id
end

-- A fake Bucket loader over an in-memory map of Tracking ID -> list of alert specs. Records
-- every id asked for, so a test can prove a display-name key is never requested, a world-hop
-- does NOT reload, and a Tracking ID change does. Each returned alert is a fresh table so the
-- runtime owns its own list.
local function newFakeLoader()
    local loader = { calls = {}, buckets = {} }
    loader.fn = function(trackingId)
        loader.calls[#loader.calls + 1] = trackingId
        local out = {}
        for _, spec in ipairs(loader.buckets[trackingId] or {}) do
            out[#out + 1] = { id = spec.id, name = spec.name, graph = spec.graph, enabled = spec.enabled }
        end
        return out
    end
    return loader
end

function TestPlayerScoping:setUp()
    self.registry = Registry.new()
    self.source = newFakeEventSource()
    self.identity = newFakeIdentity(nil) -- logged out at construction (no cold-start arming)
    self.runtime = Runtime.new(self.source.source, nil, self.identity)
    self.loader = newFakeLoader()
    self.runtime:SetBucketLoader(self.loader.fn)

    -- An echo trigger on the shared "Custom" channel: republishes the payload so a test can read
    -- whether a given alert's node fired, via graph:GetLastValue(nodeId, "payload").
    self.registry:RegisterNodeType("fixture.echo", {
        category = "trigger",
        pins = {
            { name = "out", kind = "exec", direction = "out" },
            { name = "payload", kind = "data", direction = "out", dataType = "any" },
        },
        run = function(ctx)
            ctx:Out("payload", ctx.payload)
            ctx:Fire("out")
        end,
    })
    self.runtime:BindTrigger("fixture.echo", { { event = "Custom" } })
end

function TestPlayerScoping:seedCharacterAlert(trackingId, id, name, enabled)
    local graph = Graph.new(self.registry)
    local nodeId = graph:AddNode("fixture.echo")
    local specs = self.loader.buckets[trackingId] or {}
    specs[#specs + 1] = { id = id, name = name, graph = graph, enabled = enabled ~= false }
    self.loader.buckets[trackingId] = specs
    return graph, nodeId
end

function TestPlayerScoping:login(trackingId, displayName)
    self.identity.trackingId = trackingId
    if displayName ~= nil then
        self.identity.displayName = displayName
    end
    self.source:Push("GameStateChanged", { newState = GAME })
    self.runtime:Update(0.02)
end

-- Leaves GAME (logout / world-hop / reconnect). Does not clear the identity name - a world-hop
-- keeps the same character; a test that models a real logout clears it separately.
function TestPlayerScoping:leaveGame()
    self.source:Push("GameStateChanged", { newState = NOT_GAME })
end

--- global: armed at start, fires regardless of login state --------------------------------

function TestPlayerScoping:testGlobalFiresWithoutAnyLogin()
    local g = Graph.new(self.registry)
    self.runtime:AddAlert(1, "g", g, true) -- default bucket = global
    local nid = g:AddNode("fixture.echo")

    self.source:Push("Custom", "ping")
    luaunit.assertEquals(g:GetLastValue(nid, "payload"), "ping")
end

function TestPlayerScoping:testGlobalKeepsFiringWhileLoggedOut()
    local g = Graph.new(self.registry)
    self.runtime:AddAlert(1, "g", g, true)
    local nid = g:AddNode("fixture.echo")

    self:login("tid-1", "Alice")
    self:leaveGame()
    self.source:Push("Custom", "still-here")
    luaunit.assertEquals(g:GetLastValue(nid, "payload"), "still-here")
end

--- GetActiveCharacter: the resident character's name/key for the Manager scope tab (#90) ---

function TestPlayerScoping:testActiveCharacterNilBeforeAnyLogin()
    local name, key = self.runtime:GetActiveCharacter()
    luaunit.assertNil(name)
    luaunit.assertNil(key)
end

function TestPlayerScoping:testActiveCharacterReportsLoggedInDisplayName()
    self:seedCharacterAlert("tid-1", 1, "a", true)
    self:login("tid-1", "Alice")
    local name, key = self.runtime:GetActiveCharacter()
    luaunit.assertEquals(name, "Alice")
    luaunit.assertEquals(key, "player_tid-1")
end

function TestPlayerScoping:testActiveCharacterSurvivesLeavingGame()
    -- Leaving GAME disarms but keeps the character resident, so the scope tab stays visible while
    -- logged out (editing continues off-world, #77).
    self:seedCharacterAlert("tid-1", 1, "a", true)
    self:login("tid-1", "Alice")
    self:leaveGame()
    local name, key = self.runtime:GetActiveCharacter()
    luaunit.assertEquals(name, "Alice")
    luaunit.assertEquals(key, "player_tid-1")
end

--- Character Bucket: login arms + fires; keyed on the Tracking ID --------------------------

function TestPlayerScoping:testLoginArmsCharacterBucketAndItFires()
    local g, nid = self:seedCharacterAlert("tid-1", 1, "a", true)

    self:login("tid-1", "Alice")
    self.source:Push("Custom", "hi-alice")

    luaunit.assertEquals(self.loader.calls, { "tid-1" })
    luaunit.assertEquals(g:GetLastValue(nid, "payload"), "hi-alice")
    luaunit.assertEquals(self.runtime._characterBucketKey, "player_tid-1")
end

function TestPlayerScoping:testCharacterBucketKeyUsesTrackingIdCharacterForCharacter()
    -- Display-name folding must not touch the id: case and spaces in the name are not the key.
    self:seedCharacterAlert("AbC", 1, "a", true)
    self:seedCharacterAlert("ze zima", 2, "display-name-bucket", true)
    self:login("AbC", "Ze  ZIMA ")
    luaunit.assertEquals(self.loader.calls, { "AbC" })
    luaunit.assertEquals(self.runtime._characterBucketKey, "player_AbC")
    luaunit.assertNil(self.runtime.buckets["player_ze zima"])
    luaunit.assertNil(self.runtime.buckets["player_abc"])
end

function TestPlayerScoping:testEmptyTrackingIdLeavesOnlyTheGlobalScope()
    self:seedCharacterAlert("tid-1", 1, "a", true)
    self:login("", "Alice")
    luaunit.assertEquals(self.loader.calls, {})
    local name, key = self.runtime:GetActiveCharacter()
    luaunit.assertNil(name)
    luaunit.assertNil(key)
    luaunit.assertNil(self.runtime.buckets["player_"])
    luaunit.assertNil(self.runtime.buckets["player_Alice"])
end

function TestPlayerScoping:testCharacterAlertDoesNotFireBeforeLogin()
    local g, nid = self:seedCharacterAlert("tid-1", 1, "a", true)
    self.source:Push("Custom", "too-early")
    luaunit.assertNil(g:GetLastValue(nid, "payload"))
    luaunit.assertEquals(#self.loader.calls, 0)
end

--- Deferred resolution: pending flag drained on a Logic tick ------------------------------

function TestPlayerScoping:testIdentityResolvesDeferredOnLogicTick()
    local g, nid = self:seedCharacterAlert("tid-1", 1, "a", true)
    self.identity.trackingId = "tid-1"
    self.identity.displayName = "Alice"
    self.source:Push("GameStateChanged", { newState = GAME })

    luaunit.assertEquals(#self.loader.calls, 0)
    self.source:Push("Custom", "before-tick")
    luaunit.assertNil(g:GetLastValue(nid, "payload"))

    self.runtime:Update(0.02)
    self.source:Push("Custom", "after-tick")
    luaunit.assertEquals(g:GetLastValue(nid, "payload"), "after-tick")
    luaunit.assertEquals(self.loader.calls, { "tid-1" })
end

function TestPlayerScoping:testPendingResolveRetriesUntilTrackingIdReadable()
    local g, nid = self:seedCharacterAlert("tid-1", 1, "a", true)
    -- GAME arrives but the Tracking ID isn't readable yet (logged out / empty id).
    self.source:Push("GameStateChanged", { newState = GAME })
    self.runtime:Update(0.02)
    luaunit.assertEquals(#self.loader.calls, 0)

    self.identity.trackingId = "tid-1"
    self.identity.displayName = "Alice"
    self.runtime:Update(0.02)
    self.source:Push("Custom", "resolved")
    luaunit.assertEquals(g:GetLastValue(nid, "payload"), "resolved")
    luaunit.assertEquals(self.loader.calls, { "tid-1" })
end

function TestPlayerScoping:testColdStartResolvesInWorldOnConstruction()
    -- A plugin reload mid-session gets no GameStateChanged: construction must poll once and, if
    -- in-world, raise the same pending flag - one code path, drained on the first Update tick.
    local source = newFakeEventSource()
    local identity = newFakeIdentity("tid-1", "Alice") -- already in-world at construction
    local runtime = Runtime.new(source.source, nil, identity)
    local loader = newFakeLoader()
    runtime:SetBucketLoader(loader.fn)

    local graph = Graph.new(self.registry)
    local nodeId = graph:AddNode("fixture.echo")
    loader.buckets["tid-1"] = { { id = 1, name = "a", graph = graph, enabled = true } }
    runtime:BindTrigger("fixture.echo", { { event = "Custom" } })

    runtime:Update(0.02)
    source:Push("Custom", "cold-start")
    luaunit.assertEquals(graph:GetLastValue(nodeId, "payload"), "cold-start")
    luaunit.assertEquals(loader.calls, { "tid-1" })
end

--- Leaving GAME disarms but keeps resident -----------------------------------------------

function TestPlayerScoping:testLogoutDisarmsButKeepsResidentAndReArmsWithoutReload()
    local g, nid = self:seedCharacterAlert("tid-1", 1, "a", true)
    self:login("tid-1", "Alice")
    self.source:Push("Custom", "one")
    luaunit.assertEquals(g:GetLastValue(nid, "payload"), "one")

    self:leaveGame()
    self.source:Push("Custom", "while-out")
    luaunit.assertEquals(g:GetLastValue(nid, "payload"), "one") -- unchanged: disarmed

    self:login("tid-1", "Alice")
    luaunit.assertEquals(self.loader.calls, { "tid-1" })
    self.source:Push("Custom", "back")
    luaunit.assertEquals(g:GetLastValue(nid, "payload"), "back")
end

--- World-hop / reconnect: re-arm in place, no Enter replay --------------------------------

-- A poll fixture (mirrors test_poll.lua): fires the resolved edge and records the sequence, so a
-- test can prove a world-hop's disarm→re-arm replays no `Enter`.
local function registerPollFixture(registry, edges)
    registry:RegisterNodeType("fixture.poll", {
        category = "trigger",
        pins = {
            { name = "Enter", kind = "exec", direction = "out" },
            { name = "Leave", kind = "exec", direction = "out" },
        },
        run = function(ctx)
            edges[#edges + 1] = ctx.payload.edge
            ctx:Fire(ctx.payload.edge)
        end,
    })
end

function TestPlayerScoping:testWorldHopReArmsInPlaceWithNoEnterReplay()
    local edges = {}
    registerPollFixture(self.registry, edges)
    -- Predicate is always true (target 0, sample 1) so the edge state is true after the first tick.
    self.runtime:BindTrigger("fixture.poll", {
        {
            kind = "poll",
            event = "Logic",
            transform = function(raw) return raw ~= nil and raw.sample or nil end,
            filter = function() return true end,
        },
    })

    local graph = Graph.new(self.registry)
    local pollNode = graph:AddNode("fixture.poll")
    self.loader.buckets["tid-1"] = { { id = 1, name = "a", graph = graph, enabled = true } }

    self:login("tid-1", "Alice")
    self.source:Push("Logic", { sample = 1 })
    luaunit.assertEquals(edges, { "Enter" })

    -- World hop: leave GAME (disarm), then GAME again (same Tracking ID → re-arm in place).
    -- No Logic tick fires while disarmed, so no Leave; the frozen edge state survives the re-arm.
    self:leaveGame()
    self:login("tid-1", "Alice")
    luaunit.assertEquals(self.loader.calls, { "tid-1" })

    self.source:Push("Logic", { sample = 1 })
    luaunit.assertEquals(edges, { "Enter" })
end

--- Genuine character switch: discard + load the new Bucket --------------------------------

function TestPlayerScoping:testGenuineSwitchDiscardsOldAndLoadsNew()
    local aliceG, aliceN = self:seedCharacterAlert("tid-alice", 1, "a", true)
    local bobG, bobN = self:seedCharacterAlert("tid-bob", 2, "b", true)

    self:login("tid-alice", "Alice")
    self.source:Push("Custom", "for-alice")
    luaunit.assertEquals(aliceG:GetLastValue(aliceN, "payload"), "for-alice")

    self.identity.trackingId = nil
    self:leaveGame()
    self:login("tid-bob", "Bob")

    luaunit.assertEquals(self.loader.calls, { "tid-alice", "tid-bob" })
    luaunit.assertEquals(self.runtime._characterBucketKey, "player_tid-bob")
    -- Alice's bucket is discarded: her graph is no longer resident, so it never fires again.
    luaunit.assertNil(self.runtime.buckets["player_tid-alice"])
    self.source:Push("Custom", "for-bob")
    luaunit.assertEquals(bobG:GetLastValue(bobN, "payload"), "for-bob")
    luaunit.assertEquals(aliceG:GetLastValue(aliceN, "payload"), "for-alice") -- unchanged, discarded
end

function TestPlayerScoping:testRenameKeepsBucketAndUpdatesTheTabLabel()
    -- Same Tracking ID, new display name: the bucket stays, and a display-name key is never
    -- requested. The tab label follows the current display name.
    self:seedCharacterAlert("tid-1", 1, "a", true)
    self:seedCharacterAlert("Alicia", 2, "display-name-bucket", true)

    self:login("tid-1", "Alice")
    self.identity.displayName = "Alicia"
    local name, key = self.runtime:GetActiveCharacter()
    luaunit.assertEquals(name, "Alicia")
    luaunit.assertEquals(key, "player_tid-1")
    luaunit.assertEquals(self.loader.calls, { "tid-1" })
    luaunit.assertNotNil(self.runtime.buckets["player_tid-1"])
    luaunit.assertNil(self.runtime.buckets["player_Alicia"])
    luaunit.assertNil(self.runtime.buckets["player_alice"])
end

--- Fire predicate: exactly *armed Bucket AND enabled* - nothing else ----------------------

function TestPlayerScoping:testArmedButDisabledDoesNotFire()
    local g, nid = self:seedCharacterAlert("tid-1", 1, "a", true)
    self:login("tid-1", "Alice")
    self.runtime:SetEnabled("a", false) -- armed bucket, but the alert itself is disabled
    self.source:Push("Custom", "nope")
    luaunit.assertNil(g:GetLastValue(nid, "payload"))
end

function TestPlayerScoping:testEnabledButDisarmedDoesNotFire()
    local g, nid = self:seedCharacterAlert("tid-1", 1, "a", true)
    self:login("tid-1", "Alice")
    self:leaveGame() -- bucket disarmed; the alert is still enabled + resident
    self.source:Push("Custom", "nope")
    luaunit.assertNil(g:GetLastValue(nid, "payload"))
end

function TestPlayerScoping:testArmedAndEnabledFires()
    local g, nid = self:seedCharacterAlert("tid-1", 1, "a", true)
    self:login("tid-1", "Alice")
    self.source:Push("Custom", "yes")
    luaunit.assertEquals(g:GetLastValue(nid, "payload"), "yes")
end

function TestPlayerScoping:testCharacterToggleFlipsInMemoryButNotThroughGlobalHook()
    -- A character alert's enable flip must NOT reach the `global` persistence hook: Entry ids are
    -- unique only within a Bucket, so writing a character id through the global hook could collide
    -- with a same-id global entry. The flip still takes effect in memory (it stops firing).
    local calls = {}
    self.runtime:SetPersistence({ SetEnabled = function(id, enabled) calls[#calls + 1] = { id = id, enabled = enabled } end })

    local g, nid = self:seedCharacterAlert("tid-1", 1, "a", true)
    self:login("tid-1", "Alice")
    luaunit.assertTrue(self.runtime:SetEnabled("a", false))

    luaunit.assertEquals(#calls, 0)
    self.source:Push("Custom", "silenced")
    luaunit.assertNil(g:GetLastValue(nid, "payload"))
end

--- Stop tears down the lifecycle subscription --------------------------------------------

function TestPlayerScoping:testStopUnsubscribesLifecycle()
    self:seedCharacterAlert("tid-1", 1, "a", true)
    self.runtime:Stop()
    -- After Stop, a GAME transition is no longer observed, so no pending resolve is raised.
    self.source:Push("GameStateChanged", { newState = GAME })
    self.runtime:Update(0.02)
    luaunit.assertEquals(#self.loader.calls, 0)
end

return TestPlayerScoping
