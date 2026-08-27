local ChatTypes = {}

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

---@class Watchdog.ChatTypeGroup
---@field key string        # the value stored on the enum Control (e.g. "examine", "private_sent")
---@field label string      # the human label shown in the dropdown (e.g. "Examine")
---@field ids number[]|nil  # the raw ChatType ids this Group covers; nil marks the Any entry

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
