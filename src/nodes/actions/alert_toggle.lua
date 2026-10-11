local Node = {}

---@param registry LibNodeGraph.Registry
---@param runtime Watchdog.Runtime
function Node.Register(registry, runtime)
    registry:RegisterNodeType("action.alert_toggle", {
        category = "action",
        displayName = "Alert Toggle",
        pins = {
            { name = "enable", kind = "exec", direction = "in", terminates = true },
            { name = "disable", kind = "exec", direction = "in", terminates = true },
            { name = "toggle", kind = "exec", direction = "in", terminates = true },
            { name = "target", kind = "data", direction = "in", dataType = "string", default = "" },
        },
        run = function(ctx)
            if runtime == nil then
                return
            end
            local target = ctx:In("target")
            if target == nil or target == "" then
                return
            end
            local e = ctx.exec
            if e == "toggle" then
                runtime:Toggle(target)
            elseif e == "disable" then
                runtime:SetEnabled(target, false)
            else
                runtime:SetEnabled(target, true)
            end
        end,
    })
end

return Node
