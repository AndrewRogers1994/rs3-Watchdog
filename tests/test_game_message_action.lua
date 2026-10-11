-- Game Message action (`action.game_message`, #116). A real graph, FireInput, and the
-- line handed to Chat.AddMessage. The chat-permission gate starts from
-- Plugin.HasPermission and flips on OptionalPermissionChanged. No hand-built ctx.

local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local GameMessage = require("src/nodes/actions/game_message")

local CHAT = "chatAccess"
local LINE = "The ground shakes."

TestGameMessageAction = {}

local function savedGlobals()
    return {
        Plugin = _G.Plugin,
        PluginPermissions = _G.PluginPermissions,
        Event = _G.Event,
        Chat = _G.Chat,
        print = print,
    }
end

function TestGameMessageAction:setUp()
    self.saved = savedGlobals()
    self.lines = {}
    self.printed = {}
    self.permissionFn = nil
    _G.PluginPermissions = { chatAccess = CHAT }
    _G.Plugin = {
        HasPermission = function(permission)
            return permission == CHAT and self.chatGranted == true
        end,
    }
    _G.Chat = {
        AddMessage = function(...)
            self.lines[#self.lines + 1] = { n = select("#", ...), select(1, ...) }
        end,
    }
    _G.print = function(...)
        self.printed[#self.printed + 1] = table.concat({ ... }, "\t")
    end
    self.registry = Registry.new()
    self.graph = Graph.new(self.registry)
end

function TestGameMessageAction:tearDown()
    _G.Plugin = self.saved.Plugin
    _G.PluginPermissions = self.saved.PluginPermissions
    _G.Event = self.saved.Event
    _G.Chat = self.saved.Chat
    _G.print = self.saved.print
end

function TestGameMessageAction:installPermissionEvent()
    self.onPermission = nil
    _G.Event = {
        OptionalPermissionChanged = {
            Subscribe = function(_, fn)
                self.onPermission = fn
            end,
        },
    }
end

function TestGameMessageAction:register(granted)
    self.chatGranted = granted == true
    self:installPermissionEvent()
    GameMessage.Register(self.registry)
end

function TestGameMessageAction:place(message)
    return self.graph:AddNode("action.game_message", { message = message })
end

function TestGameMessageAction:testRegistersAsActionMatchingLogPins()
    self:register(true)
    local desc = self.registry:GetNodeType("action.game_message")
    luaunit.assertNotNil(desc)
    luaunit.assertEquals(desc.category, "action")
    luaunit.assertEquals(desc.displayName, "Game Message")

    local byName, execOut = {}, 0
    for _, name in ipairs(desc.pinOrder) do
        local pin = desc.pins[name]
        byName[name] = pin
        if pin.kind == "exec" and pin.direction == "out" then
            execOut = execOut + 1
        end
    end
    luaunit.assertEquals(byName["in"].kind, "exec")
    luaunit.assertEquals(byName["in"].direction, "in")
    luaunit.assertEquals(byName.message.kind, "data")
    luaunit.assertEquals(byName.message.direction, "in")
    luaunit.assertEquals(byName.message.dataType, "string")
    luaunit.assertEquals(execOut, 0)
    luaunit.assertEquals(#desc.pinOrder, 2)
end

function TestGameMessageAction:testFireHandsOneClientSideLineToChat()
    self:register(true)
    local id = self:place(LINE)
    self.graph:FireInput(id, "in")
    luaunit.assertEquals(#self.lines, 1)
    luaunit.assertEquals(self.lines[1].n, 1)
    luaunit.assertEquals(self.lines[1][1], LINE)
end

function TestGameMessageAction:testClosedGateInsertsNothingAndLogsTheReason()
    self:register(false)
    local id = self:place(LINE)
    self.graph:FireInput(id, "in")
    luaunit.assertEquals(#self.lines, 0)
    luaunit.assertEquals(self.printed, { "needs chat permission" })
end

function TestGameMessageAction:testPermissionEventOpensTheGateAndTheNextFireInserts()
    self:register(false)
    local id = self:place(LINE)
    self.graph:FireInput(id, "in")
    luaunit.assertEquals(#self.lines, 0)

    self.onPermission({ permission = CHAT, enabled = true })
    self.graph:FireInput(id, "in")
    luaunit.assertEquals(#self.lines, 1)
    luaunit.assertEquals(self.lines[1][1], LINE)
end

function TestGameMessageAction:testRevokingPermissionStopsTheNextInsert()
    self:register(true)
    local id = self:place(LINE)
    self.onPermission({ permission = CHAT, enabled = false })
    self.graph:FireInput(id, "in")
    luaunit.assertEquals(#self.lines, 0)
    luaunit.assertEquals(self.printed, { "needs chat permission" })
end

return TestGameMessageAction
