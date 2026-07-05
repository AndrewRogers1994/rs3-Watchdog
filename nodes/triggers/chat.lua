local Chat = {}

-- Fired by main.lua on each incoming chat line, with the message text as the payload
-- (see LibNodeGraph/docs/adr/0009). The trigger matches against its `contains` control
-- and, on a match, republishes the text on the `message` Data output for downstream
-- nodes before firing `out`. `contains` empty => match every line.
function Chat.Register(registry)
    registry:RegisterNodeType("trigger.chat", {
        category = "trigger",
        displayName = "Chat Trigger",
        pins = {
            { name = "contains", kind = "data", direction = "in", dataType = "string", default = "" },
            { name = "out", kind = "exec", direction = "out" },
            { name = "message", kind = "data", direction = "out", dataType = "string" },
        },
        run = function(ctx)
            local message = ctx.payload.chatMessage
            if type(message) ~= "string" then
                return
            end
            log(formatStr("Got chat message: {}|{}", ctx.payload.chatType, message))
            local needle = ctx:In("contains")
            if needle ~= nil and needle ~= "" and not string.find(message, needle) then
                return
            end
            ctx:Out("message", message)
            ctx:Fire("out")
        end,
    })
end

return Chat
