-- alert_toggle.lua — the `action.alert_toggle` node (#35): arms or silences another alert
-- (graph), including itself. Reaches runtime.lua's per-alert `enabled` flag (#27) through the
-- runtime handle, mirroring how the other runtime-backed action nodes (screen_flash, popup, …)
-- get theirs — the node never touches the alert store directly, only SetEnabled / Toggle.
--
-- Three exec-in pins, no exec-out — the `std.gate` idiom (LibNodeGraphStd/stateful.lua): each
-- pin mutates then fires nothing, so all three are Terminators (`terminates = true`). Which pin
-- fired is read off `ctx.exec` (LibNodeGraph/graph.lua's _makeCtx): `enable`/`disable` call
-- `runtime:SetEnabled(target, bool)` (persists), `toggle` calls `runtime:Toggle(target)`.
--
-- The target is a free-text string data-in control naming the alert to affect — deliberately a
-- text control, not a pin: a graph self-targets by typing its own name, and a rename leaves the
-- typed name stale (an accepted no-op, #27), which is the price of not wiring identity through a
-- pin. An empty/nil target names nothing and is a silent no-op.

local Node = {}

---@param registry LibNodeGraph.Registry
function Node.Register(registry, runtime)
    registry:RegisterNodeType("action.alert_toggle", {
        category = "action",
        displayName = "Alert Toggle",
        pins = {
            { name = "enable", kind = "exec", direction = "in", terminates = true },
            { name = "disable", kind = "exec", direction = "in", terminates = true },
            { name = "toggle", kind = "exec", direction = "in", terminates = true },
            -- Free-text name of the alert (graph) to affect; self-target by typing this graph's
            -- own name. Not meant to be wired — a config text control (ADR-0004).
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
                -- "enable" (also the fallback for an unnamed firing pin).
                runtime:SetEnabled(target, true)
            end
        end,
    })
end

return Node
