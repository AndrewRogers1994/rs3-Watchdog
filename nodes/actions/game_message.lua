-- Game Message action. One client-side chat line, same pins as Log.
-- Chat permission is read once from Plugin.HasPermission, then OptionalPermissionChanged
-- flips that same flag. The node type stays registered either way, so a node already
-- on a graph remains and the next fire follows the new flag. Watchdog does not reload.
--
-- The event is not in the stubs yet. The payload we honor is { permission, enabled },
-- matching OptionalDependencyChanged's enabled flag and the chatAccess permission name.
-- Any other payload re-reads HasPermission, which covers a client that updates the
-- permission query before it notifies.

local REASON = "needs chat permission"

local Gates = require("nodes/gates")

local GameMessage = {}

local function readChatPermission()
    if Plugin == nil or Plugin.HasPermission == nil or PluginPermissions == nil then
        return false
    end
    return Plugin.HasPermission(PluginPermissions.chatAccess) == true
end

---@param ev table|userdata|nil
---@return boolean
local function grantFromEvent(ev)
    -- Event payloads are userdata in the client and tables in tests; accept both.
    local kind = type(ev)
    if (kind == "table" or kind == "userdata") and ev.enabled ~= nil then
        local chatName = (PluginPermissions ~= nil and PluginPermissions.chatAccess) or "chatAccess"
        if ev.permission == chatName or ev.permission == "chatAccess" then
            return ev.enabled == true
        end
    end
    return readChatPermission()
end

---@param registry LibNodeGraph.Registry
function GameMessage.Register(registry)
    -- Closure, not a module flag: each Register sees the permission at that moment,
    -- and the Palette and run share this one flag.
    local granted = readChatPermission()
    if Event ~= nil then
        ---@diagnostic disable-next-line: undefined-field
        local channel = Event.OptionalPermissionChanged
        if channel ~= nil then
            channel.Subscribe("watchdog.game_message.permission", function(ev)
                granted = grantFromEvent(ev)
            end)
        end
    end

    Gates.Bind("action.game_message", function()
        if not granted then return REASON end
    end)

    registry:RegisterNodeType("action.game_message", {
        category = "action",
        displayName = "Game Message",
        pins = {
            { name = "in", kind = "exec", direction = "in" },
            { name = "message", kind = "data", direction = "in", dataType = "string" },
        },
        run = function(ctx)
            if not granted then
                print(REASON)
                return
            end
            local message = ctx:In("message")
            if type(message) ~= "string" then
                return
            end
            -- Not in the stubs yet. One argument: the client-side line.
            ---@diagnostic disable-next-line: undefined-global
            Chat.AddMessage(message)
        end,
    })
end

return GameMessage
