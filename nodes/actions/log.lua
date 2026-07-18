local Log = {}
---@param registry LibNodeGraph.Registry
function Log.Register(registry)
    registry:RegisterNodeType("action.log", {
        category = "action",
        displayName = "Log",
        pins = {
            { name = "in", kind = "exec", direction = "in" },
            { name = "message", kind = "data", direction = "in", dataType = "string" },
        },
        run = function(ctx)
            local message = ctx:In("message")
            if message ~= nil then
                print("Watchdog: " .. tostring(message))
            else
                print("Watchdog: message was nil")
            end
        end,
    })
end
return Log
