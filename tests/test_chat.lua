-- Exercises the Chat trigger migrated onto runtime.lua's dispatcher (#24): Register now
-- takes (registry, runtime) and declares its own ChatMessage binding instead of main.lua
-- hardcoding a Subscribe block. Chat lines pushed through a fake event source must still
-- reach the node's own `contains` substring match and fire `out` on match.

local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local Runtime = require("runtime")
local newFakeEventSource = require("fake_event_source")
local Chat = require("nodes/triggers/chat")

-- Client globals the node's run() touches directly (ChatType.FromID, formatStr, log) —
-- stubbed minimally so the node can execute under a standalone interpreter.
ChatType = { FromID = function(id) return id end }
function formatStr(template, ...)
    return template
end
function log() end

TestChat = {}

function TestChat:setUp()
    self.registry = Registry.new()
    self.source = newFakeEventSource()
    self.runtime = Runtime.new(self.source.source)
    self.graph = Graph.new(self.registry)
    self.runtime:SetGraph(self.graph)

    Chat.Register(self.registry, self.runtime)

    self.log = {}
    self.registry:RegisterNodeType("fixture.mark", {
        category = "action",
        pins = { { name = "in", kind = "exec", direction = "in", terminates = true } },
        run = function() table.insert(self.log, #self.log + 1) end,
    })
end

function TestChat:testMatchingChatLineFiresThroughDispatcher()
    local chatId = self.graph:AddNode("trigger.chat", { contains = "hello" })
    local markId = self.graph:AddNode("fixture.mark")
    self.graph:Connect(chatId, "out", markId, "in")

    self.source:Push("ChatMessage", { chatMessage = "hello world", chatType = 0 })

    luaunit.assertEquals(#self.log, 1)
    luaunit.assertEquals(self.graph:GetLastValue(chatId, "message"), "hello world")
end

function TestChat:testNonMatchingChatLineDoesNotFire()
    local chatId = self.graph:AddNode("trigger.chat", { contains = "hello" })
    local markId = self.graph:AddNode("fixture.mark")
    self.graph:Connect(chatId, "out", markId, "in")

    self.source:Push("ChatMessage", { chatMessage = "goodbye world", chatType = 0 })

    luaunit.assertEquals(#self.log, 0)
end

function TestChat:testNChatNodesCostExactlyOneSubscription()
    self.graph:AddNode("trigger.chat", { contains = "a" })
    self.graph:AddNode("trigger.chat", { contains = "b" })
    self.graph:AddNode("trigger.chat", { contains = "" })

    self.source:Push("ChatMessage", { chatMessage = "a and b", chatType = 0 })

    luaunit.assertEquals(self.source:SubscribeCount("ChatMessage"), 1)
end

function TestChat:testEachMatchingNodeFiresIndependently()
    local aId = self.graph:AddNode("trigger.chat", { contains = "a" })
    local bId = self.graph:AddNode("trigger.chat", { contains = "zzz" })

    self.source:Push("ChatMessage", { chatMessage = "a message", chatType = 0 })

    luaunit.assertEquals(self.graph:GetLastValue(aId, "message"), "a message")
    luaunit.assertNil(self.graph:GetLastValue(bId, "message"))
end

return TestChat
