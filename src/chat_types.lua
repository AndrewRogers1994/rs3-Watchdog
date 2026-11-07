local ChatTypes = {}

---@type Watchdog.ChatTypeGroup[]
ChatTypes.GAME_MESSAGE = {
    { key = "any",        label = "Any" },
    { key = "game",       label = "Game/Examine", ids = { ChatType.GENERAL } },
    -- examine chat type isn't actually used
    -- { key = "examine",    label = "Examine",      ids = { ChatType.OBJ_EXAMINE, ChatType.NPC_EXAMINE, ChatType.LOC_EXAMINE } },
    { key = "npc",        label = "NPC Dialogue", ids = { ChatType.NPC_CHAT } },
    { key = "broadcast",  label = "Broadcast",    ids = {
        ChatType.SYSTEM_BROADCAST, ChatType.BROADCAST, ChatType.MISC_BROADCAST,
        ChatType.BROADCAST_GLOBAL, ChatType.BROADCAST_WORLD, ChatType.BROADCAST_FRIENDS,
    } },
    { key = "spam",       label = "Spam",         ids = { ChatType.SPAM } },
    { key = "login",      label = "Login/Logout", ids = { ChatType.LOGIN_LOGOUT } },
    { key = "worldevent", label = "World Event",  ids = { ChatType.WORLD_EVENT } },
}

---@type Watchdog.ChatTypeGroup[]
ChatTypes.PLAYER_CHAT = {
    { key = "any",          label = "Any" },
    { key = "public",       label = "Public",             ids = { ChatType.PUBLIC, ChatType.QUICKCHAT_PUBLIC } },
    { key = "private",      label = "Private",            ids = {
        ChatType.PRIVATE_INCOMING, ChatType.PRIVATE_OUTGOING,
        ChatType.QUICKCHAT_PRIVATE_INCOMING, ChatType.QUICKCHAT_PRIVATE_OUTGOING,
    } },
    { key = "private_sent", label = "Private (Sent)",     ids = { ChatType.PRIVATE_OUTGOING, ChatType.QUICKCHAT_PRIVATE_OUTGOING } },
    { key = "private_recv", label = "Private (Received)", ids = { ChatType.PRIVATE_INCOMING, ChatType.QUICKCHAT_PRIVATE_INCOMING } },
    { key = "friends",      label = "Friends Chat",       ids = { ChatType.FRIEND_CHAT, ChatType.QUICKCHAT_FRIEND_CHAT } },
    { key = "clan",         label = "Clan Chat",          ids = { ChatType.CLANCHANNEL_AFFINED_CHAT, ChatType.CLANCHANNEL_AFFINED_QUICKCHAT } },
    { key = "guest_clan",   label = "Guest Clan Chat",    ids = { ChatType.CLANCHANNEL_GUEST_CHAT, ChatType.CLANCHANNEL_GUEST_QUICKCHAT } },
    { key = "group",        label = "Group Chat",         ids = {
        ChatType.GROUP_SAME_TEAM, ChatType.QUICKCHAT_GROUP_SAME_TEAM,
        ChatType.GROUP_ALL, ChatType.QUICKCHAT_GROUP_ALL,
    } },
}

---@class Watchdog.ChatTypeGroup
---@field key string        # the value stored on the enum Control (e.g. "examine", "private_sent")
---@field label string      # the human label shown in the dropdown (e.g. "Examine")
---@field ids number[]|nil  # ChatType enum values this Group covers; nil marks the Any entry

---@param groups Watchdog.ChatTypeGroup[]
---@return { value: string, label: string }[]
function ChatTypes.Choices(groups)
    local choices = {}
    for _, g in ipairs(groups) do
        choices[#choices + 1] = { value = g.key, label = g.label }
    end
    return choices
end

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
        local set = (groupKey ~= nil and groupKey ~= "any") and byKey[groupKey] or union
        return set[chatType] == true
    end
end

return ChatTypes
