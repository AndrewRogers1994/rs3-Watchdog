-- Exercises the Game Message trigger (`trigger.game_message`, #56) against a REAL LibNodeGraph
-- driven through the fake event source + runtime dispatcher - never a hand-built ctx (see
-- CONTEXT.md *Testing node types*). Pushes ChatMessage payloads (chatMessage + chatType) and
-- asserts external behavior: whether `out` fires and what the `message` output holds.
--
-- Covers: Chat Type Group filtering to the right ids, Any = the union of Game Message's own
-- Groups (and the other trigger's types NOT leaking in), substring vs pattern matching, the
-- empty needle matching everything, and tag stripping affecting both the match and the output.

local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local Runtime = require("runtime")
local newFakeEventSource = require("fake_event_source")
local GameMessage = require("nodes/triggers/game_message")

local function sub(needle) return { needle = needle, mode = "substring" } end
local function pat(needle) return { needle = needle, mode = "pattern" } end

TestGameMessage = {}

function TestGameMessage:setUp()
    self.registry = Registry.new()
    self.source = newFakeEventSource()
    self.runtime = Runtime.new(self.source.source)
    self.graph = Graph.new(self.registry)
    self.runtime:SetGraph(self.graph)

    GameMessage.Register(self.registry, self.runtime)

    self.log = {}
    self.registry:RegisterNodeType("fixture.mark", {
        category = "action",
        pins = { { name = "in", kind = "exec", direction = "in", terminates = true } },
        run = function() table.insert(self.log, #self.log + 1) end,
    })
end

-- Adds a game_message node wired to a mark action, returning the node id so a test can read
-- its `message` output.
function TestGameMessage:addWired(controls)
    local id = self.graph:AddNode("trigger.game_message", controls)
    local markId = self.graph:AddNode("fixture.mark")
    self.graph:Connect(id, "out", markId, "in")
    return id
end

function TestGameMessage:push(message, chatType)
    self.source:Push("ChatMessage", { chatMessage = message, chatType = chatType })
end

-- --- Chat Type Group filtering ----------------------------------------------------------

function TestGameMessage:testGroupFiltersToItsOwnIds()
    self:addWired({ type = "examine" })
    self:push("A bar of iron.", 28) -- an examine id
    luaunit.assertEquals(#self.log, 1)
end

function TestGameMessage:testGroupRejectsIdsOutsideIt()
    self:addWired({ type = "examine" })
    self:push("Welcome to RuneScape.", 0) -- Game, not Examine
    luaunit.assertEquals(#self.log, 0)
end

function TestGameMessage:testAnyMatchesUnionOfOwnGroups()
    self:addWired({ type = "any" })
    self:push("Welcome to RuneScape.", 0)   -- Game
    self:push("A bar of iron.", 29)         -- Examine
    self:push("You have a new task.", 116)  -- NPC Dialogue
    luaunit.assertEquals(#self.log, 3)
end

function TestGameMessage:testAnyDoesNotLeakOtherTriggersTypes()
    -- 2 is a Player Chat (Public) id - Game Message's Any must not fire on it.
    self:addWired({ type = "any" })
    self:push("hi there", 2)
    luaunit.assertEquals(#self.log, 0)
end

function TestGameMessage:testDefaultTypeIsAny()
    -- No `type` control set at all defaults to Any (the group filter treats nil as the union).
    self:addWired({})
    self:push("Welcome to RuneScape.", 0)
    luaunit.assertEquals(#self.log, 1)
end

-- --- Matcher: substring vs pattern, empty needle -----------------------------------------

function TestGameMessage:testSubstringIsCaseInsensitive()
    local id = self:addWired({ type = "any", contains = sub("zulrah") })
    self:push("You defeated Zulrah!", 0)
    luaunit.assertEquals(#self.log, 1)
    luaunit.assertEquals(self.graph:GetLastValue(id, "message"), "You defeated Zulrah!")
end

function TestGameMessage:testPatternIsCaseSensitiveWithMagic()
    self:addWired({ type = "any", contains = pat("%d+ gp") })
    self:push("You earn 250 gp.", 0)
    luaunit.assertEquals(#self.log, 1)

    self.log = {}
    self:addWired({ type = "any", contains = pat("Zulrah") })
    self:push("you defeated zulrah", 0) -- wrong case, pattern is case-sensitive
    luaunit.assertEquals(#self.log, 0)
end

function TestGameMessage:testEmptyNeedleMatchesEveryLine()
    self:addWired({ type = "any", contains = sub("") })
    self:push("literally anything", 0)
    luaunit.assertEquals(#self.log, 1)
end

function TestGameMessage:testNonMatchingNeedleDoesNotFire()
    self:addWired({ type = "any", contains = sub("vorago") })
    self:push("You defeated Zulrah!", 0)
    luaunit.assertEquals(#self.log, 0)
end

-- --- Tag stripping -----------------------------------------------------------------------

function TestGameMessage:testTagsStrippedForMatching()
    -- A mid-line <col=…> tag must not break an otherwise-obvious substring match.
    self:addWired({ type = "any", contains = sub("Zulrah defeated") })
    self:push("<col=ff0000>Zulrah</col> defeated", 0)
    -- Stripped haystack is "Zulrah defeated", so the needle matches.
    luaunit.assertEquals(#self.log, 1)
end

function TestGameMessage:testMessageOutputIsStripped()
    local id = self:addWired({ type = "any", contains = sub("") })
    self:push("<col=00ff00>Hello</col> world", 0)
    luaunit.assertEquals(self.graph:GetLastValue(id, "message"), "Hello world")
end

-- --- Dispatcher wiring -------------------------------------------------------------------

function TestGameMessage:testNNodesCostExactlyOneSubscription()
    self.graph:AddNode("trigger.game_message", { contains = sub("a") })
    self.graph:AddNode("trigger.game_message", { contains = sub("b") })
    self:push("a and b", 0)
    luaunit.assertEquals(self.source:SubscribeCount("ChatMessage"), 1)
end

return TestGameMessage
