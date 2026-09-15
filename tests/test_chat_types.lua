-- Chat type groups (#56): curated group→id maps; Any is the union of that trigger's groups.

local luaunit = require("luaunit")
local ChatTypes = require("chat_types")

TestChatTypesChoices = {}

function TestChatTypesChoices:testGameMessageChoicesLeadWithAny()
    local choices = ChatTypes.Choices(ChatTypes.GAME_MESSAGE)
    luaunit.assertEquals(choices[1], { value = "any", label = "Any" })
    luaunit.assertEquals(#choices, 8)
end

function TestChatTypesChoices:testPlayerChatChoicesLeadWithAny()
    local choices = ChatTypes.Choices(ChatTypes.PLAYER_CHAT)
    luaunit.assertEquals(choices[1], { value = "any", label = "Any" })
    luaunit.assertEquals(#choices, 9)
end

TestChatTypesMatcher = {}

function TestChatTypesMatcher:setUp()
    self.game = ChatTypes.Matcher(ChatTypes.GAME_MESSAGE)
    self.player = ChatTypes.Matcher(ChatTypes.PLAYER_CHAT)
end

function TestChatTypesMatcher:testNamedGroupMatchesOnlyItsIds()
    luaunit.assertTrue(self.game("examine", 27))
    luaunit.assertTrue(self.game("examine", 28))
    luaunit.assertTrue(self.game("examine", 29))
    luaunit.assertFalse(self.game("examine", 0)) -- Game, not Examine
end

function TestChatTypesMatcher:testAnyIsUnionOfOwnGroups()
    for _, id in ipairs({ 0, 27, 116, 115, 109, 5, 126 }) do
        luaunit.assertTrue(self.game("any", id))
    end
    -- A Player Chat id does not leak into Game Message's Any.
    luaunit.assertFalse(self.game("any", 2))
    luaunit.assertFalse(self.game("any", 41))
end

function TestChatTypesMatcher:testNilGroupKeyBehavesAsAny()
    luaunit.assertTrue(self.game(nil, 0))
    luaunit.assertFalse(self.game(nil, 2)) -- still bounded to Game Message's union
end

function TestChatTypesMatcher:testUnknownGroupKeyFallsBackToUnion()
    luaunit.assertTrue(self.game("bogus", 0))
    luaunit.assertFalse(self.game("bogus", 2))
end

function TestChatTypesMatcher:testPrivateDirectionVariants()
    -- Private = both directions; Sent = outgoing only; Received = incoming only.
    luaunit.assertTrue(self.player("private", 3))
    luaunit.assertTrue(self.player("private", 6))
    luaunit.assertTrue(self.player("private_sent", 6))
    luaunit.assertTrue(self.player("private_sent", 19))
    luaunit.assertFalse(self.player("private_sent", 3))  -- received, not sent
    luaunit.assertTrue(self.player("private_recv", 3))
    luaunit.assertTrue(self.player("private_recv", 18))
    luaunit.assertFalse(self.player("private_recv", 6))  -- sent, not received
end

function TestChatTypesMatcher:testTriggersDoNotShareTypes()
    -- A Game Message id is outside Player Chat's Any, and vice versa.
    luaunit.assertFalse(self.player("any", 0))   -- Game
    luaunit.assertFalse(self.game("any", 22))    -- Group Chat
end

return TestChatTypesMatcher
