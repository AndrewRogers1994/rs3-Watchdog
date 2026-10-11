-- Exercises the Player Chat trigger (`trigger.player_chat`, #56) against a REAL LibNodeGraph
-- driven through the fake event source + runtime dispatcher - never a hand-built ctx (see
-- CONTEXT.md *Testing node types*). Pushes ChatMessage payloads (chatMessage, chatType, and
-- senderNameSimple) and asserts external behavior: whether `out` fires, what the
-- `message`/`sender` outputs hold, and whether the three sender spellings were logged.
--
-- Covers: Chat Type Group filtering incl. the private direction variants (Sent / Received /
-- both), Any = the union of Player Chat's own Groups (and Game Message's types NOT leaking in),
-- the sender Matcher on the tag-stripped simple name, the nil-sender-passes-with-empty-output
-- case, and one log line of all three sender spellings when any of them is present.

local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local Runtime = require("src/runtime")
local newFakeEventSource = require("fake_event_source")
local PlayerChat = require("src/nodes/triggers/player_chat")

local function sub(needle) return { needle = needle, mode = "substring" } end

TestPlayerChat = {}

function TestPlayerChat:setUp()
    self.registry = Registry.new()
    self.source = newFakeEventSource()
    self.runtime = Runtime.new(self.source.source)
    self.graph = Graph.new(self.registry)
    self.runtime:SetGraph(self.graph)
    self.logs = {}
    self._savedLog = _G.log
    local logs = self.logs
    _G.log = function(line) logs[#logs + 1] = line end

    PlayerChat.Register(self.registry, self.runtime)

    self.log = {}
    self.registry:RegisterNodeType("fixture.mark", {
        category = "action",
        pins = { { name = "in", kind = "exec", direction = "in", terminates = true } },
        run = function() table.insert(self.log, #self.log + 1) end,
    })
end

function TestPlayerChat:tearDown()
    _G.log = self._savedLog
end

function TestPlayerChat:addWired(controls)
    local id = self.graph:AddNode("trigger.player_chat", controls)
    local markId = self.graph:AddNode("fixture.mark")
    self.graph:Connect(id, "out", markId, "in")
    return id
end

-- Omit sender to leave senderNameSimple unset.
function TestPlayerChat:push(message, chatType, sender)
    local raw = { chatMessage = message, chatType = chatType }
    if sender ~= nil then raw.senderNameSimple = sender end
    self.source:Push("ChatMessage", raw)
end

-- --- Chat Type Group filtering, incl. private direction ---------------------------------

function TestPlayerChat:testPublicGroupFiltersToItsIds()
    self:addWired({ type = "public" })
    self:push("hi all", 2)   -- Public
    self:push("hi all", 17)  -- Public (quick-chat, folded in)
    luaunit.assertEquals(#self.log, 2)
end

function TestPlayerChat:testPublicRejectsPrivateIds()
    self:addWired({ type = "public" })
    self:push("secret", 3)   -- a Private (received) id
    luaunit.assertEquals(#self.log, 0)
end

function TestPlayerChat:testPrivateMatchesBothDirections()
    self:addWired({ type = "private" })
    self:push("incoming", 3)  -- received
    self:push("outgoing", 6)  -- sent
    luaunit.assertEquals(#self.log, 2)
end

function TestPlayerChat:testPrivateSentMatchesOnlyOutgoing()
    self:addWired({ type = "private_sent" })
    self:push("outgoing", 6)   -- sent -> fires
    self:push("outgoing", 19)  -- sent (quick-chat) -> fires
    self:push("incoming", 3)   -- received -> no fire
    luaunit.assertEquals(#self.log, 2)
end

function TestPlayerChat:testPrivateReceivedMatchesOnlyIncoming()
    self:addWired({ type = "private_recv" })
    self:push("incoming", 3)   -- received -> fires
    self:push("incoming", 18)  -- received (quick-chat) -> fires
    self:push("outgoing", 6)   -- sent -> no fire
    luaunit.assertEquals(#self.log, 2)
end

function TestPlayerChat:testAnyMatchesUnionButNotGameMessageTypes()
    self:addWired({ type = "any" })
    self:push("hi all", 2)    -- Public (in union)
    self:push("clan msg", 41) -- Clan (in union)
    self:push("Welcome to RuneScape.", 0) -- Game (a Game Message id) -> must NOT fire
    luaunit.assertEquals(#self.log, 2)
end

-- --- Message + sender Matchers -----------------------------------------------------------

function TestPlayerChat:testSenderMatcherFiltersOnSimpleName()
    self:addWired({ type = "any", senderContains = sub("zezima") })
    self:push("hello", 2, "Zezima")
    luaunit.assertEquals(#self.log, 1)

    self.log = {}
    self:addWired({ type = "any", senderContains = sub("zezima") })
    self:push("hello", 2, "Durial321")
    luaunit.assertEquals(#self.log, 0)
end

function TestPlayerChat:testMessageAndSenderOutputs()
    local id = self:addWired({ type = "any", contains = sub("hi") })
    self:push("<col=00ffff>hi there</col>", 2, "<col=ffff00>Zezima</col>")
    luaunit.assertEquals(#self.log, 1)
    luaunit.assertEquals(self.graph:GetLastValue(id, "message"), "hi there")
    luaunit.assertEquals(self.graph:GetLastValue(id, "sender"), "Zezima")
end

function TestPlayerChat:testSenderStrippedForMatching()
    self:addWired({ type = "any", senderContains = sub("Zezima") })
    self:push("hi", 2, "<col=ffff00>Zezima</col>")
    luaunit.assertEquals(#self.log, 1)
end

-- --- Sender absent (client doesn't emit chatSender yet) ----------------------------------

function TestPlayerChat:testNilSenderPassesSenderFilter()
    self:addWired({ type = "any", senderContains = sub("zezima") })
    self:push("hello", 2) -- no sender
    luaunit.assertEquals(#self.log, 1)
end

function TestPlayerChat:testNilSenderOutputsEmptyString()
    local id = self:addWired({ type = "any" })
    self:push("hello", 2) -- no sender
    luaunit.assertEquals(self.graph:GetLastValue(id, "sender"), "")
    luaunit.assertEquals(self.graph:GetLastValue(id, "message"), "hello")
end

function TestPlayerChat:testSenderPinIsStrippedSimpleNameAndOtherSpellingsAreNotPins()
    local nt = self.registry:GetNodeType("trigger.player_chat")
    luaunit.assertNil(nt.pins.senderNameFiltered)
    luaunit.assertNil(nt.pins.senderNameUnfiltered)
    luaunit.assertNotNil(nt.pins.sender)

    local id = self:addWired({ type = "any" })
    self.source:Push("ChatMessage", {
        chatMessage = "hi",
        chatType = 2,
        senderNameSimple = "<col=ffff00>Zezima</col>",
        senderNameFiltered = "Filtered",
        senderNameUnfiltered = "Unfiltered",
        chatSender = "OldField",
    })
    luaunit.assertEquals(self.graph:GetLastValue(id, "sender"), "Zezima")
end

function TestPlayerChat:testSenderMatcherUsesStrippedSimpleName()
    self:addWired({ type = "any", senderContains = sub("Zezima") })
    self.source:Push("ChatMessage", {
        chatMessage = "hi",
        chatType = 2,
        senderNameSimple = "<col=ffff00>Zezima</col>",
        senderNameFiltered = "Filtered",
    })
    luaunit.assertEquals(#self.log, 1)
end

function TestPlayerChat:testSenderMatcherIgnoresFilteredSpelling()
    self:addWired({ type = "any", senderContains = sub("Filtered") })
    self.source:Push("ChatMessage", {
        chatMessage = "hi",
        chatType = 2,
        senderNameSimple = "<col=ffff00>Zezima</col>",
        senderNameFiltered = "Filtered",
    })
    luaunit.assertEquals(#self.log, 0)
end

function TestPlayerChat:testLogsAllThreeSenderNamesWhenAnyIsPresent()
    self:addWired({ type = "any" })
    self.source:Push("ChatMessage", {
        chatMessage = "hi",
        chatType = 2,
        senderNameSimple = "Zezima",
        senderNameFiltered = "Zez*",
        senderNameUnfiltered = "<col=ffff00>Zezima</col>",
    })
    luaunit.assertEquals(#self.logs, 1)
    luaunit.assertStrContains(self.logs[1], "simple=Zezima")
    luaunit.assertStrContains(self.logs[1], "filtered=Zez*")
    luaunit.assertStrContains(self.logs[1], "unfiltered=<col=ffff00>Zezima</col>")
end

function TestPlayerChat:testLogsAllThreeSlotsWhenOnlyOneSenderFieldIsSet()
    self:addWired({ type = "any" })
    self.source:Push("ChatMessage", {
        chatMessage = "hi",
        chatType = 2,
        senderNameFiltered = "OnlyFiltered",
    })
    luaunit.assertEquals(#self.logs, 1)
    luaunit.assertStrContains(self.logs[1], "simple=")
    luaunit.assertStrContains(self.logs[1], "filtered=OnlyFiltered")
    luaunit.assertStrContains(self.logs[1], "unfiltered=")
end

function TestPlayerChat:testChatLineWithNoSenderNamesIsNotLogged()
    self:addWired({ type = "any" })
    self:push("Welcome to RuneScape.", 0)
    luaunit.assertEquals(self.logs, {})
end

return TestPlayerChat
