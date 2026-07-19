-- game_message.lua — the Game Message trigger (`trigger.game_message`, #56): one of the two
-- nodes the old bare `trigger.chat` split into (see #54). Fires on system/engine/broadcast/
-- examine chat lines, filtered by a curated Chat Type Group and a reusable Matcher.
--
-- Pipeline (rides the #24 event dispatcher, same model as entity_spawn):
--   * transform (once/ChatMessage event) — strips formatting tags from the incoming line up
--     front, so both matching AND the `message` output operate on clean, what-you-see text
--     (never raw `<col=…>` markup). Carries the raw `chatType` id through for the group filter.
--   * filter (per node) — the node's own Chat Type Group dropdown (`type`) resolved against the
--     line's `chatType`, then the `contains` Matcher against the clean message. `Any` (the
--     default) matches only this trigger's own Group ids — a whisper never leaks in.
--   * run (per matched node) — surfaces the clean `message` and fires `out`.

local ChatTypes = require("chat_types")
local Matcher = require("matcher")
local Text = require("text")

local GameMessage = {}

-- The payload every ChatMessage event is shaped into for this node. `message` is the
-- tag-stripped line (used for both match and output); `chatType` is the raw id the group
-- filter tests.
---@class Watchdog.Payload.GameMessage
---@field message any     # the tag-stripped chat line (string in practice; guarded in filter)
---@field chatType any    # the raw ChatType id the group dropdown filters on

-- Whether a raw ChatType id falls in the Group the node's dropdown selected (Any = the union of
-- Game Message's own Groups). Built once from the taxonomy; see chat_types.lua.
local matchesGroup = ChatTypes.Matcher(ChatTypes.GAME_MESSAGE)

-- Shapes a raw ChatMessage event into the node payload, stripping tags off the line once.
local function transform(raw)
    return {
        message = Text.StripTags(raw and raw.chatMessage),
        chatType = raw and raw.chatType,
    }
end

-- Gates a node: reject non-string lines, then require both the Chat Type Group match and the
-- `contains` Matcher. A nil `type` control means Any (matchesGroup handles nil); a nil/empty
-- `contains` Matcher matches everything (Matcher.Test handles nil).
local function passesFilter(payload, node)
    if payload == nil or type(payload.message) ~= "string" then
        return false
    end
    if not matchesGroup(node.GetControl("type"), payload.chatType) then
        return false
    end
    return Matcher.Test(node.GetControl("contains"), payload.message)
end

---@param registry LibNodeGraph.Registry
function GameMessage.Register(registry, runtime)
    -- Register this node's Chat Type Group dropdown Control Spec (ADR-0004's enum widget),
    -- guarded so a headless/test require (no ui layer) still registers the node itself.
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
              label = "Message contains", placeholder = "any message",
              default = { needle = "", mode = "substring" } },
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
