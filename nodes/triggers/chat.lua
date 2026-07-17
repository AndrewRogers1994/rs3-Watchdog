local Chat = {}

-- Fired by runtime.lua's dispatcher on each incoming chat line, with the message text as
-- the payload (see LibNodeGraph/docs/adr/0009). The trigger matches against its `contains`
-- control and, on a match, republishes the text on the `message` Data output for downstream
-- nodes before firing `out`. `contains` empty => match every line. No runtime-level
-- transform/filter is needed — this substring match stays in `run`, unchanged from before
-- the migration onto the dispatcher.
---@param registry LibNodeGraph.Registry
function Chat.Register(registry, runtime)
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
            local type = ChatType.FromID(ctx.payload.chatType)
            log(formatStr("Got chat message: {}|{}", type, message))
            local needle = ctx:In("contains")
            if needle ~= nil and needle ~= "" and not string.find(message, needle) then
                return
            end
            ctx:Out("message", message)
            ctx:Fire("out")
        end,
    })

    runtime:BindTrigger("trigger.chat", { { event = "ChatMessage" } })
end

return Chat
