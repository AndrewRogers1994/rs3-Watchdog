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

-- A fake identity source: `name` is the display name the runtime will read on the next resolve.
-- nil means "not logged in / not readable yet" (Player.IsAvailable() false), so Resolve returns
-- nil and the runtime keeps the pending-resolve flag raised.
local function newFakeIdentity(name)
    local id = { name = name }
    function id:Resolve() return self.name end
    return id
end

-- A fake Bucket loader over an in-memory map of normalized name -> list of alert specs. Records
-- every call (the normalized names asked for) so a test can prove a world-hop does NOT reload while
-- a genuine switch does. Each returned alert is a fresh table so the runtime owns its own list.
local function newFakeLoader()
    local loader = { calls = {}, buckets = {} }
    loader.fn = function(normalized)
        loader.calls[#loader.calls + 1] = normalized
        local out = {}
        for _, spec in ipairs(loader.buckets[normalized] or {}) do
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

-- Builds a one-echo-node graph and registers it as a loadable alert under `normalized` in the
-- fake loader. Returns the graph + node id so a test can assert firing.
function TestPlayerScoping:seedCharacterAlert(normalized, id, name, enabled)
    local graph = Graph.new(self.registry)
    local nodeId = graph:AddNode("fixture.echo")
    local specs = self.loader.buckets[normalized] or {}
    specs[#specs + 1] = { id = id, name = name, graph = graph, enabled = enabled ~= false }
    self.loader.buckets[normalized] = specs
    return graph, nodeId
end

-- Logs in as `displayName`: raises the GAME transition then drains identity on one Logic tick.
function TestPlayerScoping:login(displayName)
    self.identity.name = displayName
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

    self:login("Alice")
    self:leaveGame() -- logged out again
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
    self:seedCharacterAlert("alice", 1, "a", true)
    self:login("Alice")
    local name, key = self.runtime:GetActiveCharacter()
    luaunit.assertEquals(name, "Alice")           -- the pretty display name, not the normalized key
    luaunit.assertEquals(key, "player_alice")
end

function TestPlayerScoping:testActiveCharacterSurvivesLeavingGame()
    -- Leaving GAME disarms but keeps the character resident, so the scope tab stays visible while
    -- logged out (editing continues off-world, #77).
    self:seedCharacterAlert("alice", 1, "a", true)
    self:login("Alice")
    self:leaveGame()
    local name, key = self.runtime:GetActiveCharacter()
    luaunit.assertEquals(name, "Alice")
    luaunit.assertEquals(key, "player_alice")
end

--- Character Bucket: login arms + fires; keyed on normalized name -------------------------

function TestPlayerScoping:testLoginArmsCharacterBucketAndItFires()
    local g, nid = self:seedCharacterAlert("alice", 1, "a", true)

    self:login("Alice")
    self.source:Push("Custom", "hi-alice")

    luaunit.assertEquals(self.loader.calls, { "alice" }) -- keyed on the *normalized* name
    luaunit.assertEquals(g:GetLastValue(nid, "payload"), "hi-alice")
    luaunit.assertEquals(self.runtime._characterBucketKey, "player_alice")
end

function TestPlayerScoping:testCharacterBucketKeyNormalizesDisplayName()
    self:seedCharacterAlert("ze zima", 1, "a", true)
    self:login("Ze  ZIMA ") -- cosmetic case/whitespace variant of the saved bucket
    luaunit.assertEquals(self.loader.calls, { "ze zima" })
    luaunit.assertEquals(self.runtime._characterBucketKey, "player_ze zima")
end

function TestPlayerScoping:testCharacterAlertDoesNotFireBeforeLogin()
    local g, nid = self:seedCharacterAlert("alice", 1, "a", true)
    -- Not loaded until login: no bucket, nothing resident.
    self.source:Push("Custom", "too-early")
    luaunit.assertNil(g:GetLastValue(nid, "payload"))
    luaunit.assertEquals(#self.loader.calls, 0)
end

--- Deferred resolution: pending flag drained on a Logic tick ------------------------------

function TestPlayerScoping:testIdentityResolvesDeferredOnLogicTick()
    local g, nid = self:seedCharacterAlert("alice", 1, "a", true)
    self.identity.name = "Alice"
    self.source:Push("GameStateChanged", { newState = GAME })

    -- The GAME callback only raised the flag - nothing loaded yet.
    luaunit.assertEquals(#self.loader.calls, 0)
    self.source:Push("Custom", "before-tick")
    luaunit.assertNil(g:GetLastValue(nid, "payload"))

    -- The next Logic tick drains it and loads + arms the bucket.
    self.runtime:Update(0.02)
    self.source:Push("Custom", "after-tick")
    luaunit.assertEquals(g:GetLastValue(nid, "payload"), "after-tick")
end

function TestPlayerScoping:testPendingResolveRetriesUntilNameReadable()
    local g, nid = self:seedCharacterAlert("alice", 1, "a", true)
    -- GAME arrives but the name isn't readable yet (IsAvailable false → Resolve nil).
    self.source:Push("GameStateChanged", { newState = GAME })
    self.runtime:Update(0.02)
    luaunit.assertEquals(#self.loader.calls, 0) -- still pending, not loaded

    -- Name becomes readable a tick later; the still-raised flag resolves it.
    self.identity.name = "Alice"
    self.runtime:Update(0.02)
    self.source:Push("Custom", "resolved")
    luaunit.assertEquals(g:GetLastValue(nid, "payload"), "resolved")
end

function TestPlayerScoping:testColdStartResolvesInWorldOnConstruction()
    -- A plugin reload mid-session gets no GameStateChanged: construction must poll once and, if
    -- in-world, raise the same pending flag - one code path, drained on the first Update tick.
    local source = newFakeEventSource()
    local identity = newFakeIdentity("Alice") -- already in-world at construction
    local runtime = Runtime.new(source.source, nil, identity)
    local loader = newFakeLoader()
    runtime:SetBucketLoader(loader.fn)

    local graph = Graph.new(self.registry)
    local nodeId = graph:AddNode("fixture.echo")
    loader.buckets["alice"] = { { id = 1, name = "a", graph = graph, enabled = true } }
    runtime:BindTrigger("fixture.echo", { { event = "Custom" } })

    runtime:Update(0.02) -- drains the cold-start pending flag
    source:Push("Custom", "cold-start")
    luaunit.assertEquals(graph:GetLastValue(nodeId, "payload"), "cold-start")
    luaunit.assertEquals(loader.calls, { "alice" })
end

--- Leaving GAME disarms but keeps resident -----------------------------------------------

function TestPlayerScoping:testLogoutDisarmsButKeepsResidentAndReArmsWithoutReload()
    local g, nid = self:seedCharacterAlert("alice", 1, "a", true)
    self:login("Alice")
    self.source:Push("Custom", "one")
    luaunit.assertEquals(g:GetLastValue(nid, "payload"), "one")

    -- Leave GAME: the alert stops firing...
    self:leaveGame()
    self.source:Push("Custom", "while-out")
    luaunit.assertEquals(g:GetLastValue(nid, "payload"), "one") -- unchanged: disarmed

    -- ...but stays resident: re-login (same name) re-arms in place with NO second load.
    self:login("Alice")
    luaunit.assertEquals(self.loader.calls, { "alice" }) -- loaded once, not reloaded
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
    self.loader.buckets["alice"] = { { id = 1, name = "a", graph = graph, enabled = true } }

    self:login("Alice")
    self.source:Push("Logic", { sample = 1 })
    luaunit.assertEquals(edges, { "Enter" }) -- fired once on the first true tick

    -- World hop: leave GAME (disarm), then GAME again (same name → re-arm in place). No Logic tick
    -- fires while disarmed, so no Leave; the frozen edge state survives the re-arm.
    self:leaveGame()
    self:login("Alice")
    luaunit.assertEquals(self.loader.calls, { "alice" }) -- re-armed in place, never reloaded

    self.source:Push("Logic", { sample = 1 })
    luaunit.assertEquals(edges, { "Enter" }) -- still just one Enter: no replay
end

--- Genuine character switch: discard + load the new Bucket --------------------------------

function TestPlayerScoping:testGenuineSwitchDiscardsOldAndLoadsNew()
    local aliceG, aliceN = self:seedCharacterAlert("alice", 1, "a", true)
    local bobG, bobN = self:seedCharacterAlert("bob", 2, "b", true)

    self:login("Alice")
    self.source:Push("Custom", "for-alice")
    luaunit.assertEquals(aliceG:GetLastValue(aliceN, "payload"), "for-alice")

    -- Log out, then log in as a *different* character.
    self.identity.name = nil
    self:leaveGame()
    self:login("Bob")

    luaunit.assertEquals(self.loader.calls, { "alice", "bob" })
    luaunit.assertEquals(self.runtime._characterBucketKey, "player_bob")
    -- Alice's bucket is discarded: her graph is no longer resident, so it never fires again.
    luaunit.assertNil(self.runtime.buckets["player_alice"])
    self.source:Push("Custom", "for-bob")
    luaunit.assertEquals(bobG:GetLastValue(bobN, "payload"), "for-bob")
    luaunit.assertEquals(aliceG:GetLastValue(aliceN, "payload"), "for-alice") -- unchanged, discarded
end

function TestPlayerScoping:testRenameOrphansOldBucketNoAdoption()
    -- No stable account id: a rename is indistinguishable from a fresh alt. "Alicia" resolves to a
    -- different normalized key, so the old "alice" bucket is discarded (orphaned on disk) and a
    -- fresh bucket loads - no adoption of the old one (#77 §3).
    self:seedCharacterAlert("alice", 1, "a", true)
    self:seedCharacterAlert("alicia", 2, "b", true)

    self:login("Alice")
    self.identity.name = nil
    self:leaveGame()
    self:login("Alicia")

    luaunit.assertNil(self.runtime.buckets["player_alice"])
    luaunit.assertNotNil(self.runtime.buckets["player_alicia"])
    luaunit.assertEquals(self.loader.calls, { "alice", "alicia" })
end

--- Fire predicate: exactly *armed Bucket AND enabled* - nothing else ----------------------

function TestPlayerScoping:testArmedButDisabledDoesNotFire()
    local g, nid = self:seedCharacterAlert("alice", 1, "a", true)
    self:login("Alice")
    self.runtime:SetEnabled("a", false) -- armed bucket, but the alert itself is disabled
    self.source:Push("Custom", "nope")
    luaunit.assertNil(g:GetLastValue(nid, "payload"))
end

function TestPlayerScoping:testEnabledButDisarmedDoesNotFire()
    local g, nid = self:seedCharacterAlert("alice", 1, "a", true)
    self:login("Alice")
    self:leaveGame() -- bucket disarmed; the alert is still enabled + resident
    self.source:Push("Custom", "nope")
    luaunit.assertNil(g:GetLastValue(nid, "payload"))
end

function TestPlayerScoping:testArmedAndEnabledFires()
    local g, nid = self:seedCharacterAlert("alice", 1, "a", true)
    self:login("Alice")
    self.source:Push("Custom", "yes")
    luaunit.assertEquals(g:GetLastValue(nid, "payload"), "yes")
end

function TestPlayerScoping:testCharacterToggleFlipsInMemoryButNotThroughGlobalHook()
    -- A character alert's enable flip must NOT reach the `global` persistence hook: Entry ids are
    -- unique only within a Bucket, so writing a character id through the global hook could collide
    -- with a same-id global entry. The flip still takes effect in memory (it stops firing).
    local calls = {}
    self.runtime:SetPersistence({ SetEnabled = function(id, enabled) calls[#calls + 1] = { id = id, enabled = enabled } end })

    local g, nid = self:seedCharacterAlert("alice", 1, "a", true)
    self:login("Alice")
    luaunit.assertTrue(self.runtime:SetEnabled("a", false))

    luaunit.assertEquals(#calls, 0) -- nothing persisted through the global hook
    self.source:Push("Custom", "silenced")
    luaunit.assertNil(g:GetLastValue(nid, "payload")) -- but the in-memory flip took effect
end

--- Stop tears down the lifecycle subscription --------------------------------------------

function TestPlayerScoping:testStopUnsubscribesLifecycle()
    self:seedCharacterAlert("alice", 1, "a", true)
    self.runtime:Stop()
    -- After Stop, a GAME transition is no longer observed, so no pending resolve is raised.
    self.source:Push("GameStateChanged", { newState = GAME })
    self.runtime:Update(0.02)
    luaunit.assertEquals(#self.loader.calls, 0)
end

return TestPlayerScoping
