-- action.overlay (#36): a small draggable toast on the always-on effect overlay Canvas
-- (effects.lua/overlay.lua). Two exec-in pins share one node type — `show` pushes a new
-- toast (STACKing alongside any earlier ones this same node already showed), `dismiss`
-- clears every toast this node currently has live. `icon`/`sticky` are plain data-in pins
-- (unconnected, edited via their Control like `action.sound`'s `soundId` or `trigger.chat`'s
-- `contains` — this codebase has no separate "config" pin kind, see CONTEXT.md's Control
-- Box) rather than a distinct mechanism, even though the issue groups them as "Config".
--
-- Which exec-in pin fired is read off `ctx.exec`, and the node's own stable identity (for
-- STACKing/dismissing only *this* node's toasts) off `ctx.nodeId` — both provided by
-- LibNodeGraph's run ctx (see LibNodeGraph/graph.lua's _makeCtx).
local Overlay = {}

local DEFAULT_COLOR = { r = 240, g = 160, b = 32, a = 255 }

---@param registry LibNodeGraph.Registry
function Overlay.Register(registry, runtime)
    registry:RegisterNodeType("action.overlay", {
        category = "action",
        displayName = "Overlay",
        pins = {
            { name = "show", kind = "exec", direction = "in" },
            { name = "dismiss", kind = "exec", direction = "in" },
            { name = "text", kind = "data", direction = "in", dataType = "string", default = "" },
            { name = "color", kind = "data", direction = "in", dataType = "color", default = DEFAULT_COLOR },
            { name = "icon", kind = "data", direction = "in", dataType = "overlayIcon", default = nil },
            { name = "sticky", kind = "data", direction = "in", dataType = "bool", default = false },
        },
        run = function(ctx)
            local stack = runtime.overlay
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
            })
        end,
    })
end

return Overlay
