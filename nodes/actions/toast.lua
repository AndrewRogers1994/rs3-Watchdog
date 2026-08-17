-- action.toast (#36): a small draggable toast on the always-on effect overlay Canvas
-- (effects.lua/toast.lua). Two exec-in pins share one node type — `show` pushes a new
-- toast (STACKing alongside any earlier ones this same node already showed), `dismiss`
-- clears every toast this node currently has live. `icon`/`sticky` are plain data-in pins
-- (unconnected, edited via their Control like `action.sound`'s `soundId` or `trigger.chat`'s
-- `contains` — this codebase has no separate "config" pin kind, see CONTEXT.md's Control
-- Box) rather than a distinct mechanism, even though the issue groups them as "Config".
--
-- Which exec-in pin fired is read off `ctx.exec`, and the node's own stable identity (for
-- STACKing/dismissing only *this* node's toasts) off `ctx.nodeId` — both provided by
-- LibNodeGraph's run ctx (see LibNodeGraph/graph.lua's _makeCtx).
local ToastStack = require("toast")

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
            -- How long a non-sticky toast holds before fading, in seconds (RuneLite parity
            -- default). Ignored when `sticky` is set (a sticky toast only ever leaves via
            -- `dismiss`). Mirrors action.popup's `hold` config pin.
            { name = "hold", kind = "data", direction = "in", dataType = "number",
              default = ToastStack.DEFAULT_TTL },
        },
        run = function(ctx)
            local stack = runtime.toast
            if stack == nil then
                return
            end
            local nodeKey = ctx.nodeId
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
