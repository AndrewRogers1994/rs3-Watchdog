local ToastStack = require("src/toast")

local Toast = {}

local DEFAULT_COLOR = { r = 240, g = 160, b = 32, a = 255 }

---@param registry LibNodeGraph.Registry
---@param runtime Watchdog.Runtime
function Toast.Register(registry, runtime)
    registry:RegisterNodeType("action.toast", {
        category = "action",
        displayName = "Toast",
        pins = {
            { name = "show", kind = "exec", direction = "in" },
            { name = "dismiss", kind = "exec", direction = "in" },
            { name = "text", kind = "data", direction = "in", dataType = "string", default = "" },
            { name = "color", kind = "data", direction = "in", dataType = "color", default = DEFAULT_COLOR },
            { name = "icon", kind = "data", direction = "in", dataType = "toastIcon", default = nil },
            { name = "sticky", kind = "data", direction = "in", dataType = "bool", default = false },
            { name = "hold", kind = "data", direction = "in", dataType = "number",
              default = ToastStack.DEFAULT_TTL },
        },
        run = function(ctx)
            local stack = runtime.toast
            if stack == nil then
                return
            end
            -- Node ids are graph-local; instance state stays unique after import.
            local nodeKey = ctx.state
            if ctx.exec == "dismiss" then
                stack:Dismiss(nodeKey)
                return
            end
            stack:Show(nodeKey, {
                text = ctx:In("text"),
                color = ctx:In("color"),
                icon = ctx:In("icon"),
                sticky = ctx:In("sticky") and true or false,
                ttl = ctx:In("hold"),
            })
        end,
    })
end

return Toast
