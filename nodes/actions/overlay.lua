-- action.overlay (#36): a small draggable toast on the always-on effect overlay Canvas
-- (effects.lua/overlay.lua). Two exec-in pins share one node type — `show` pushes a new
-- toast (STACKing alongside any earlier ones this same node already showed), `dismiss`
-- clears every toast this node currently has live. `icon`/`sticky` are plain data-in pins
-- (unconnected, edited via their Control like `action.sound`'s `soundId` or `trigger.chat`'s
-- `contains` — this codebase has no separate "config" pin kind, see CONTEXT.md's Control
-- Box) rather than a distinct mechanism, even though the issue groups them as "Config".
--
-- BUILD-VERIFY: which exec-in pin fired is read off `ctx.pin`, and the node's own stable
-- identity (for STACKing/dismissing only *this* node's toasts) off `ctx.nodeId` — both
-- inferred from this engine's existing `ctx.payload` naming convention (runtime.lua's
-- dispatcher) and the `nodeId` returned by `graph:AddNode` used everywhere else in this
-- codebase, since every other node registered so far (sound/log/chat) has exactly one
-- exec-in and never needed either. Confirm both field names against the real LibNodeGraph
-- engine (absent from this sandbox — see tests/run.lua) before shipping; nothing else about
-- this node depends on them.
local Overlay = {}

local DEFAULT_COLOR = { r = 240, g = 160, b = 32, a = 255 }

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
            local nodeKey = ctx.nodeId or ctx.id
            if ctx.pin == "dismiss" then
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
