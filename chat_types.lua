-- chat_types.lua — the Chat Type Group taxonomy (#56): a Watchdog-curated grouping of raw
-- engine `ChatType` ids into human-meaningful Groups, shared by the two Chat Triggers (Game
-- Message + Player Chat). It is deliberately NOT 1:1 with the client's `ChatType` enum — it
-- hides noise types, folds quick-chat into its parent channel, and gives each Group a plain
-- name the author picks from a dropdown instead of reasoning about raw ids.
--
-- Each trigger exposes only its own Groups (Game Message never offers "Private", and vice
-- versa). A Group whose `ids` is nil is the leading **Any** entry: it matches the union of
-- that trigger's own Group ids and nothing outside it — a Game Message trigger never fires on
-- a whisper because "Private"'s ids simply aren't in the Game Message union.
--
-- Ids are taken from #54's Implementation Decisions (authoritative source: the API docs'
-- ChatType enum). Quick-chat variants are folded into their parent channel by listing both the
-- typed and quick-chat ids under the one Group.

local ChatTypes = {}

-- Game Message Groups: system/engine/broadcast/examine lines. The leading Any (no `ids`)
-- matches the union of every Group below it.
---@type Watchdog.ChatTypeGroup[]
ChatTypes.GAME_MESSAGE = {
    { key = "any",        label = "Any" },
    { key = "game",       label = "Game",         ids = { 0 } },
    { key = "examine",    label = "Examine",      ids = { 27, 28, 29 } },
    { key = "npc",        label = "NPC Dialogue", ids = { 116 } },
    { key = "broadcast",  label = "Broadcast",    ids = { 115, 125, 127, 137, 138, 139 } },
    { key = "spam",       label = "Spam",         ids = { 109 } },
    { key = "login",      label = "Login/Logout", ids = { 5 } },
    { key = "worldevent", label = "World Event",  ids = { 126 } },
}

-- Player Chat Groups: lines a player typed. Private folds both directions; the two direction
-- Groups (Sent / Received) narrow it. Quick-chat ids sit alongside typed ids in each channel.
---@type Watchdog.ChatTypeGroup[]
ChatTypes.PLAYER_CHAT = {
    { key = "any",          label = "Any" },
    { key = "public",       label = "Public",             ids = { 2, 17 } },
    { key = "private",      label = "Private",            ids = { 3, 6, 18, 19 } },
    { key = "private_sent", label = "Private (Sent)",     ids = { 6, 19 } },
    { key = "private_recv", label = "Private (Received)", ids = { 3, 18 } },
    { key = "friends",      label = "Friends Chat",       ids = { 9, 20 } },
    { key = "clan",         label = "Clan Chat",          ids = { 41, 42 } },
    { key = "guest_clan",   label = "Guest Clan Chat",    ids = { 44, 45 } },
    { key = "group",        label = "Group Chat",         ids = { 22, 23, 24, 25 } },
}

-- The value/label shape a Chat Type Group takes in the taxonomy tables above. `ids` is nil for
-- the leading **Any** entry, which the matcher resolves to the union of every other Group.
---@class Watchdog.ChatTypeGroup
---@field key string        # the value stored on the enum Control (e.g. "examine", "private_sent")
---@field label string      # the human label shown in the dropdown (e.g. "Examine")
---@field ids number[]|nil  # the raw ChatType ids this Group covers; nil marks the Any entry

-- Enum Control Spec `choices` for a Group list: value = the stored key, label = the display
-- text. Fed straight into `Controls.Register(tag, { widget = "enum", choices = ... })`.
---@param groups Watchdog.ChatTypeGroup[]
---@return { value: string, label: string }[]
function ChatTypes.Choices(groups)
    local choices = {}
    for _, g in ipairs(groups) do
        choices[#choices + 1] = { value = g.key, label = g.label }
    end
    return choices
end

-- Builds a `matcher(groupKey, chatType) -> boolean` closure for one Group list, precomputing
-- each Group's id set and the Any union once. `groupKey` nil or "any" (or unknown) matches the
-- union; any other key matches exactly that Group's ids — so the other trigger's types never
-- leak in. `chatType` that isn't an id in the resolved set fails.
---@param groups Watchdog.ChatTypeGroup[]
---@return fun(groupKey: string|nil, chatType: any): boolean
function ChatTypes.Matcher(groups)
    local byKey = {}
    local union = {}
    for _, g in ipairs(groups) do
        if g.ids ~= nil then
            local set = {}
            for _, id in ipairs(g.ids) do
                set[id] = true
                union[id] = true
            end
            byKey[g.key] = set
        end
    end

    return function(groupKey, chatType)
        -- A named key resolves to its own id set; nil / "any" / an unknown key falls back to the
        -- union (the `or union` covers both the Any case and a missing byKey entry).
        local set = (groupKey ~= nil and groupKey ~= "any") and byKey[groupKey] or union
        return set[chatType] == true
    end
end

return ChatTypes
