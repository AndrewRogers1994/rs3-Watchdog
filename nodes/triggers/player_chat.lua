local ChatTypes = require("chat_types")
local Matcher = require("matcher")
local Text = require("text")

local PlayerChat = {}

---@class Watchdog.Payload.PlayerChat
---@field message any     # the tag-stripped chat line (string in practice; guarded in filter)
---@field sender string|nil # tag-stripped senderNameSimple, or nil when the client omits it
---@field chatType any    # the raw ChatType id the group dropdown filters on

local matchesGroup = ChatTypes.Matcher(ChatTypes.PLAYER_CHAT)

local function logSenderNames(raw)
    if raw == nil or log == nil then return end
    local simple = raw.senderNameSimple
    local filtered = raw.senderNameFiltered
    local unfiltered = raw.senderNameUnfiltered
    if simple == nil and filtered == nil and unfiltered == nil then
        return
    end
    log(string.format("Watchdog chat sender simple=%s filtered=%s unfiltered=%s",
        simple ~= nil and tostring(simple) or "",
        filtered ~= nil and tostring(filtered) or "",
        unfiltered ~= nil and tostring(unfiltered) or ""))
end

local function transform(raw)
    -- logSenderNames(raw)
    local sender = raw and raw.senderNameSimple
    return {
        message = Text.StripTags(raw and raw.chatMessage),
        sender = (sender ~= nil) and Text.StripTags(sender) or nil,
        chatType = raw and raw.chatType,
    }
end

local function passesFilter(payload, node)
    if payload == nil or type(payload.message) ~= "string" then
        return false
    end
    if not matchesGroup(node.GetControl("type"), payload.chatType) then
        return false
    end
    if not Matcher.Test(node.GetControl("contains"), payload.message) then
        return false
    end
    if payload.sender ~= nil and not Matcher.Test(node.GetControl("senderContains"), payload.sender) then
        return false
    end
    return true
end

---@param registry LibNodeGraph.Registry
---@param runtime Watchdog.Runtime
function PlayerChat.Register(registry, runtime)
    pcall(function()
        local Controls = require("ui/controls")
        Controls.Register("playerChatType",
            { widget = "enum", choices = ChatTypes.Choices(ChatTypes.PLAYER_CHAT) })
    end)

    registry:RegisterNodeType("trigger.player_chat", {
        category = "trigger",
        displayName = "Player Chat",
        description = "Fires on a player's chat line of a chosen channel and sender",
        pins = {
            { name = "type", kind = "data", direction = "in", dataType = "playerChatType", default = "any" },
            { name = "contains", kind = "data", direction = "in", dataType = "matcher",
              label = "Message contains", default = { needle = "", mode = "substring" } },
            { name = "senderContains", kind = "data", direction = "in", dataType = "matcher",
              label = "Sender contains", default = { needle = "", mode = "substring" } },
            { name = "out", kind = "exec", direction = "out" },
            { name = "message", kind = "data", direction = "out", dataType = "string" },
            { name = "sender", kind = "data", direction = "out", dataType = "string" },
        },
        run = function(ctx)
            ctx:Out("message", ctx.payload.message)
            ctx:Out("sender", ctx.payload.sender or "")
            ctx:Fire("out")
        end,
    })

    runtime:BindTrigger("trigger.player_chat",
        { { event = "ChatMessage", transform = transform, filter = passesFilter } })
end

return PlayerChat
