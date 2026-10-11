-- Entity Spawn and the Game Message trigger stay quiet while RestrictedAreas
-- reports Restricted. Real dispatcher, fake event source, fake global.
-- IsRestricted() is the whole answer; this suite does not load that plugin.

local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local Runtime = require("src/runtime")
local newFakeEventSource = require("fake_event_source")
local EntitySpawn = require("src/nodes/triggers/entity_spawn")
local GameMessageTrigger = require("src/nodes/triggers/game_message")
local PlayerChat = require("src/nodes/triggers/player_chat")
local GameMessageAction = require("src/nodes/actions/game_message")

TestRestricted = {}

function TestRestricted:setUp()
    self.saved = {
        RestrictedAreas = _G.RestrictedAreas,
        Plugin = _G.Plugin,
        PluginPermissions = _G.PluginPermissions,
        Event = _G.Event,
        Chat = _G.Chat,
    }
    _G.RestrictedAreas = nil

    self.registry = Registry.new()
    self.source = newFakeEventSource()
    self.runtime = Runtime.new(self.source.source)
    self.graph = Graph.new(self.registry)
    self.runtime:SetGraph(self.graph)

    EntitySpawn.Register(self.registry, self.runtime)

    self.spawned = 0
    local test = self
    self.registry:RegisterNodeType("fixture.spawned", {
        category = "action",
        pins = { { name = "in", kind = "exec", direction = "in" } },
        run = function() test.spawned = test.spawned + 1 end,
    })
end

function TestRestricted:tearDown()
    _G.RestrictedAreas = self.saved.RestrictedAreas
    _G.Plugin = self.saved.Plugin
    _G.PluginPermissions = self.saved.PluginPermissions
    _G.Event = self.saved.Event
    _G.Chat = self.saved.Chat
end

function TestRestricted:installAreas(answer)
    _G.RestrictedAreas = {
        IsRestricted = function()
            return answer
        end,
    }
end

function TestRestricted:addEntitySpawn()
    local id = self.graph:AddNode("trigger.entity_spawn", {})
    self.graph:Connect(id, "Spawned", self.graph:AddNode("fixture.spawned"), "in")
    return id
end

function TestRestricted:pushNpc()
    self.source:Push("NPCEntityAdded", {
        npcEntity = { displayName = "Goblin", coordGrid = { x = 1, z = 2, level = 0 } },
    })
end

function TestRestricted:testEntitySpawnDoesNotFireWhileRestricted()
    self:installAreas(true)
    local desc = self.registry:GetNodeType("trigger.entity_spawn")
    luaunit.assertEquals(desc.displayName, "Entity Spawn")
    self:addEntitySpawn()
    self:pushNpc()
    luaunit.assertEquals(self.spawned, 0)
end

function TestRestricted:testEntitySpawnFiresWhenNotRestricted()
    self:installAreas(false)
    self:addEntitySpawn()
    self:pushNpc()
    luaunit.assertEquals(self.spawned, 1)
end

function TestRestricted:addGameMessage()
    GameMessageTrigger.Register(self.registry, self.runtime)
    self.messages = 0
    local test = self
    self.registry:RegisterNodeType("fixture.message", {
        category = "action",
        pins = { { name = "in", kind = "exec", direction = "in" } },
        run = function() test.messages = test.messages + 1 end,
    })
    local id = self.graph:AddNode("trigger.game_message", { type = "any" })
    self.graph:Connect(id, "out", self.graph:AddNode("fixture.message"), "in")
    return id
end

function TestRestricted:pushGameLine()
    self.source:Push("ChatMessage", { chatMessage = "Welcome to RuneScape.", chatType = 0 })
end

function TestRestricted:testGameMessageTriggerDoesNotFireWhileRestricted()
    self:installAreas(true)
    self:addGameMessage()
    local desc = self.registry:GetNodeType("trigger.game_message")
    luaunit.assertEquals(desc.displayName, "Game Message")
    self:pushGameLine()
    luaunit.assertEquals(self.messages, 0)
end

function TestRestricted:testGameMessageTriggerFiresWhenNotRestricted()
    self:installAreas(false)
    self:addGameMessage()
    self:pushGameLine()
    luaunit.assertEquals(self.messages, 1)
end

function TestRestricted:testPlayerChatFiresWhileRestricted()
    self:installAreas(true)
    PlayerChat.Register(self.registry, self.runtime)
    self.chats = 0
    local test = self
    self.registry:RegisterNodeType("fixture.chat", {
        category = "action",
        pins = { { name = "in", kind = "exec", direction = "in" } },
        run = function() test.chats = test.chats + 1 end,
    })
    local id = self.graph:AddNode("trigger.player_chat", { type = "any" })
    self.graph:Connect(id, "out", self.graph:AddNode("fixture.chat"), "in")
    self.source:Push("ChatMessage", {
        chatMessage = "hi all",
        chatType = 2,
        senderNameSimple = "Zezima",
    })
    luaunit.assertEquals(self.chats, 1)
end

function TestRestricted:testGameMessageActionInsertsWhileRestricted()
    self:installAreas(true)
    self.lines = {}
    local lines = self.lines
    _G.PluginPermissions = { chatAccess = "chatAccess" }
    _G.Plugin = {
        HasPermission = function()
            return true
        end,
    }
    _G.Event = {
        OptionalPermissionChanged = { Subscribe = function() end },
    }
    _G.Chat = {
        AddMessage = function(message)
            lines[#lines + 1] = message
        end,
    }
    GameMessageAction.Register(self.registry)
    local id = self.graph:AddNode("action.game_message", { message = "The ground shakes." })
    self.graph:FireInput(id, "in")
    luaunit.assertEquals(self.lines, { "The ground shakes." })
end

return TestRestricted
