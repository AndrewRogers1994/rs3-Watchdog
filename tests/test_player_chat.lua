-- Exercises the Player Chat trigger (`trigger.player_chat`, #56) against a REAL LibNodeGraph
-- driven through the fake event source + runtime dispatcher — never a hand-built ctx (see
-- CONTEXT.md *Testing node types*). Pushes ChatMessage payloads (chatMessage, chatType, and the
-- placeholder chatSender) and asserts external behavior: whether `out` fires and what the
-- `message`/`sender` outputs hold.
--
-- Covers: Chat Type Group filtering incl. the private direction variants (Sent / Received /
-- both), Any = the union of Player Chat's own Groups (and Game Message's types NOT leaking in),
-- the sender Matcher, the nil-chatSender-passes-with-empty-output case, and tag stripping in
-- both the match and the outputs.

local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local Runtime = require("runtime")
local newFakeEventSource = require("fake_event_source")
local PlayerChat = require("nodes/triggers/player_chat")

local function sub(needle) return { needle = needle, mode = "substring" } end

TestPlayerChat = {}

function TestPlayerChat:setUp()
    self.registry = Registry.new()
    self.source = newFakeEventSource()
    self.runtime = Runtime.new(self.source.source)
    self.graph = Graph.new(self.registry)
    self.runtime:SetGraph(self.graph)

    PlayerChat.Register(self.registry, self.runtime)

    self.log = {}
    self.registry:RegisterNodeType("fixture.mark", {
        category = "action",
        pins = { { name = "in", kind = "exec", direction = "in", terminates = true } },
        run = function() table.insert(self.log, #self.log + 1) end,
    })
end

function TestPlayerChat:addWired(controls)
    local id = self.graph:AddNode("trigger.player_chat", controls)
    local markId = self.graph:AddNode("fixture.mark")
    self.graph:Connect(id, "out", markId, "in")
    return id
end

-- `raw` lets a test omit chatSender entirely (the client doesn't emit it yet).
function TestPlayerChat:push(message, chatType, sender)
    self.source:Push("ChatMessage", { chatMessage = message, chatType = chatType, chatSender = sender })
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

function TestPlayerChat:testSenderMatcherFiltersOnChatSender()
    self:addWired({ type = "any", senderContains = sub("zezima") })
    self:push("hello", 2, "Zezima")
    luaunit.assertEquals(#self.log, 1)

    self.log = {}
    self:addWired({ type = "any", senderContains = sub("zezima") })
    self:push("hello", 2, "Durial321") -- sender doesn't match
    luaunit.assertEquals(#self.log, 0)
end

function TestPlayerChat:testMessageAndSenderOutputs()
    local id = self:addWired({ type = "any", contains = sub("hi") })
    self:push("<col=00ffff>hi there</col>", 2, "<col=ffff00>Zezima</col>")
    luaunit.assertEquals(#self.log, 1)
    -- Both outputs are the tag-stripped, what-you-see text.
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
    -- A sender Matcher is set, but with no chatSender on the payload the filter passes anyway.
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

-- The matcher `placeholder` must survive the engine's pin normalization (RegisterNodeType and
-- GetPins both rebuild pins field-by-field), so the editor's per-control hint reaches the node
-- geometry. Drives the REAL registry + graph path, which the fake-pin control-spec unit test
-- bypasses — this is the seam where the field was being dropped.
function TestPlayerChat:testMatcherPlaceholdersSurviveEnginePinNormalization()
    local id = self.graph:AddNode("trigger.player_chat")
    local byName = {}
    for _, pin in ipairs(self.graph:GetPins(id)) do byName[pin.name] = pin end
    luaunit.assertEquals(byName.contains.placeholder, "any message")
    luaunit.assertEquals(byName.senderContains.placeholder, "any sender")
end

return TestPlayerChat
