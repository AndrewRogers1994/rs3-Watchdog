local Logic = {}

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
---@param runtime Watchdog.Runtime
function Logic.Register(registry, runtime)
    registry:RegisterNodeType("trigger.logic", {
        category = "trigger",
        displayName = "Client Tick",
        description = "Fires 50x/sec",
        pins = {
            { name = "interval", kind = "data", direction = "in", dataType = "number", default = 50 },
            { name = "out", kind = "exec", direction = "out" },
            { name = "logicTick", kind = "data", direction = "out", dataType = "number", label = "ticks since start" },
        },
        run = function(ctx)
            if not shouldFire(ctx) then
                return
            end
            local payload = ctx.payload
            if payload ~= nil then
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
