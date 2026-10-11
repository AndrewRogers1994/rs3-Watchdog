local ChatTypes = require("chat_types")
local Matcher = require("matcher")
local Text = require("text")
local Util = require("util")

local GameMessage = {}

---@class Watchdog.Payload.GameMessage
---@field message any     # the tag-stripped chat line (string in practice; guarded in filter)
---@field chatType any    # the raw ChatType id the group dropdown filters on

local matchesGroup = ChatTypes.Matcher(ChatTypes.GAME_MESSAGE)

local function transform(raw)
    return {
        message = Text.StripTags(raw and raw.chatMessage),
        chatType = raw and raw.chatType,
    }
end

local function passesFilter(payload, node)
    if Util.PlayerIsRestricted() then
        return false
    end
    if payload == nil or type(payload.message) ~= "string" then
        return false
    end
    if not matchesGroup(node.GetControl("type"), payload.chatType) then
        return false
    end
    return Matcher.Test(node.GetControl("contains"), payload.message)
end

---@param registry LibNodeGraph.Registry
---@param runtime Watchdog.Runtime
function GameMessage.Register(registry, runtime)
    pcall(function()
        local Controls = require("ui/controls")
        Controls.Register("gameMessageType",
            { widget = "enum", choices = ChatTypes.Choices(ChatTypes.GAME_MESSAGE) })
    end)

    registry:RegisterNodeType("trigger.game_message", {
        category = "trigger",
        displayName = "Game Message",
        description = "Fires on a system/game chat line of a chosen type",
        pins = {
            { name = "type", kind = "data", direction = "in", dataType = "gameMessageType", default = "any" },
            { name = "contains", kind = "data", direction = "in", dataType = "matcher",
              label = "Message contains", default = { needle = "", mode = "substring" } },
            { name = "out", kind = "exec", direction = "out" },
            { name = "message", kind = "data", direction = "out", dataType = "string" },
        },
        run = function(ctx)
            ctx:Out("message", ctx.payload.message)
            ctx:Fire("out")
        end,
    })

    runtime:BindTrigger("trigger.game_message",
        { { event = "ChatMessage", transform = transform, filter = passesFilter } })
end

return GameMessage
