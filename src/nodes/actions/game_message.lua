-- Game Message action. One client-side chat line, same pins as Log.
-- The type stays registered when chat permission is off, so a node already on a
-- graph remains. The next fire follows the shared chat-permission flag.

local ChatPermission = require("src/nodes/chat_permission")

local GameMessage = {}

---@param registry LibNodeGraph.Registry
function GameMessage.Register(registry)
    ChatPermission.Bind("action.game_message")

    registry:RegisterNodeType("action.game_message", {
        category = "action",
        displayName = "Game Message",
        pins = {
            { name = "in", kind = "exec", direction = "in" },
            { name = "message", kind = "data", direction = "in", dataType = "string" },
        },
        run = function(ctx)
            if not ChatPermission.Granted() then
                print(ChatPermission.REASON)
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
