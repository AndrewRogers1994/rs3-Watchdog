-- player_chat.lua — the Player Chat trigger (`trigger.player_chat`, #56): the other node the old
-- bare `trigger.chat` split into (see #54). Fires on lines a player typed (public, private,
-- friends/clan/group), filtered by a curated Chat Type Group, a message Matcher, and a separate
-- sender Matcher.
--
-- Pipeline (rides the #24 event dispatcher, same model as game_message):
--   * transform (once/ChatMessage event) — strips tags off both the line and the sender up
--     front, so matching AND the `message`/`sender` outputs are clean, what-you-see text.
--     Carries the raw `chatType` id through for the group filter.
--   * filter (per node) — the Chat Type Group dropdown against the line's `chatType`, the
--     `contains` Matcher against the clean message, and the `senderContains` Matcher against the
--     clean sender. `Any` (default) matches only Player Chat's own Group ids. Direction is folded
--     into the Groups: Private = both, Private (Sent) = outgoing ids, Private (Received) = incoming.
--   * run (per matched node) — surfaces the clean `message` and `sender` and fires `out`.
--
-- Sender field: read from the placeholder payload field `chatSender`, which the client does NOT
-- emit yet (#54: the ChatMessage payload carries only chatMessage/chatType/timestamp today). When
-- absent, the sender Matcher is skipped (passes) and the `sender` output is empty. When the real
-- field ships, rename `chatSender` in `transform` below — the one place it is read.

local ChatTypes = require("chat_types")
local Matcher = require("matcher")
local Text = require("text")

local PlayerChat = {}

-- The payload every ChatMessage event is shaped into for this node. `message`/`sender` are the
-- tag-stripped strings (used for both match and output); `sender` is nil until the client emits
-- a sender field. `chatType` is the raw id the group filter tests.
---@class Watchdog.Payload.PlayerChat
---@field message any     # the tag-stripped chat line (string in practice; guarded in filter)
---@field sender string|nil # the tag-stripped sender name, or nil when the client omits it
---@field chatType any    # the raw ChatType id the group dropdown filters on

-- Whether a raw ChatType id falls in the Group the node's dropdown selected (Any = the union of
-- Player Chat's own Groups). Built once from the taxonomy; see chat_types.lua.
local matchesGroup = ChatTypes.Matcher(ChatTypes.PLAYER_CHAT)

-- Shapes a raw ChatMessage event into the node payload, stripping tags off the line and (when
-- present) the sender once. `chatSender` is the placeholder field the client does not emit yet.
local function transform(raw)
    local sender = raw and raw.chatSender
    return {
        message = Text.StripTags(raw and raw.chatMessage),
        sender = (sender ~= nil) and Text.StripTags(sender) or nil,
        chatType = raw and raw.chatType,
    }
end

-- Gates a node: reject non-string lines, then require the Chat Type Group match, the `contains`
-- Matcher, and — only when a sender is present — the `senderContains` Matcher. A nil sender (the
-- client field isn't live) passes the sender filter, so graphs built now still fire.
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
    -- Register this node's Chat Type Group dropdown Control Spec (ADR-0004's enum widget),
    -- guarded so a headless/test require (no ui layer) still registers the node itself.
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
            -- Empty (not nil) when the client omits the sender, per #54's placeholder contract.
            ctx:Out("sender", ctx.payload.sender or "")
            ctx:Fire("out")
        end,
    })

    runtime:BindTrigger("trigger.player_chat",
        { { event = "ChatMessage", transform = transform, filter = passesFilter } })
end

return PlayerChat
