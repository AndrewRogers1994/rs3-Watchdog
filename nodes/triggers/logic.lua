-- logic.lua — the two clock triggers (#52): Client Tick (`trigger.logic`, off the 50 Hz
-- `Logic` event) and Server Tick (`trigger.server_logic`, off the ~0.6 s `ServerLogic`
-- event). Both live here because they're the same idea — a bare clock pulse — differing only
-- in which client event drives them and whether the event carries a payload.
--
-- The raw `Logic` clock is a 50 Hz firehose, so each node carries an `interval` config value
-- (a plain, conventionally-unwired data input — the engine's only per-node config store, per
-- ADR-0004, exactly like InfoBox's title/dismissWhenEmpty) and only fires its `out` exec pin
-- once every Nth tick. The gating can't live in the binding `filter` (the dispatcher's filter
-- has no per-node state to count with — see runtime.lua) so it lives in `run`, counting with
-- `ctx.state` (ADR-0010's stateful-node support). `clamp(interval) = max(1, floor(interval))`,
-- so a stray 0, a negative, or a fraction all behave as "every tick" rather than breaking.
--
-- Registered from main.lua with one `require("nodes/triggers/logic").Register(registry, runtime)`
-- line — both node types and both event bindings are declared here, so the self-contained-trigger
-- architecture (#24) holds: no dispatcher or main.lua edits beyond that single require.

local Logic = {}

-- max(1, floor(interval)): a non-positive or fractional interval collapses to 1 ("every
-- tick"), so a stray value never silently stops the graph or errors. A non-number (e.g. a
-- nil control) is treated as 1 too.
local function clampInterval(interval)
    if type(interval) ~= "number" then
        return 1
    end
    local n = math.floor(interval)
    if n < 1 then
        return 1
    end
    return n
end

-- Per-node interval gate: bumps this node's own `ctx.state` counter on every fire and returns
-- true only once it reaches clamp(interval), resetting the counter. Two tick nodes with
-- different intervals each keep their own cadence because `ctx.state` is per-node.
local function shouldFire(ctx)
    local interval = clampInterval(ctx:In("interval"))
    local count = (ctx.state.count or 0) + 1
    if count >= interval then
        ctx.state.count = 0
        return true
    end
    ctx.state.count = count
    return false
end

---@param registry LibNodeGraph.Registry
function Logic.Register(registry, runtime)
    registry:RegisterNodeType("trigger.logic", {
        category = "trigger",
        displayName = "Client Tick",
        description = "Fires 50x/sec",
        pins = {
            -- Conventionally unwired config value (ADR-0004): defaults to 50 so dropping the
            -- node in fires ~once/sec, not 50x/sec instantly.
            { name = "interval", kind = "data", direction = "in", dataType = "number", default = 50 },
            { name = "out", kind = "exec", direction = "out" },
            -- The raw client tick count at fire time (from the Logic event payload), unaffected
            -- by `interval` — for elapsed-time / modulo math downstream.
            { name = "logicTick", kind = "data", direction = "out", dataType = "number", label = "ticks since start" },
        },
        run = function(ctx)
            if not shouldFire(ctx) then
                return
            end
            local payload = ctx.payload
            if type(payload) == "table" then
                ctx:Out("logicTick", payload.logicTick)
            end
            ctx:Fire("out")
        end,
    })

    registry:RegisterNodeType("trigger.server_logic", {
        category = "trigger",
        displayName = "Server Tick",
        description = "Fires every 0.6s",
        pins = {
            { name = "interval", kind = "data", direction = "in", dataType = "number", default = 1 },
            -- No data output: the ServerLogic event carries no payload (ctx.payload is nil),
            -- so there's no tick count to surface.
            { name = "out", kind = "exec", direction = "out" },
        },
        run = function(ctx)
            if not shouldFire(ctx) then
                return
            end
            ctx:Fire("out")
        end,
    })

    runtime:BindTrigger("trigger.logic", { { event = "Logic" } })
    runtime:BindTrigger("trigger.server_logic", { { event = "ServerLogic" } })
end

return Logic
