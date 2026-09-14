local Location = {}

---@class Watchdog.Payload.Location
---@field coord CoordGrid  # the player's tile this tick ({ x, z, level })

local function chebyshev(a, b)
    return math.max(math.abs(a.x - b.x), math.abs(a.z - b.z))
end

local function normalizeRadius(radius)
    if type(radius) ~= "number" or radius < 0 then
        return 0
    end
    return radius
end

local function validTarget(target)
    if type(target) ~= "table" then
        return nil
    end
    if target.x == nil or target.z == nil or target.level == nil then
        return nil
    end
    return target
end

---@param registry LibNodeGraph.Registry
---@param runtime Watchdog.Runtime
function Location.Register(registry, runtime)
    registry:RegisterNodeType("trigger.location", {
        category = "trigger",
        displayName = "Location",
        description = "Entering/leaving a radius around a tile",
        pins = {
            { name = "target", kind = "data", direction = "in", dataType = "coordgrid", default = nil },
            { name = "radius", kind = "data", direction = "in", dataType = "number", default = 0 },
            { name = "Enter", kind = "exec", direction = "out" },
            { name = "Leave", kind = "exec", direction = "out" },
            { name = "coord", kind = "data", direction = "out", dataType = "coordgrid" },
            { name = "distance", kind = "data", direction = "out", dataType = "number" },
        },
        run = function(ctx)
            local coord = ctx.payload.sample.coord
            ctx:Out("coord", coord)
            local target = validTarget(ctx:In("target"))
            if target ~= nil then
                ctx:Out("distance", chebyshev(coord, target))
            end
            ctx:Fire(ctx.payload.edge)
        end,
    })

    runtime:BindTrigger("trigger.location", {
        {
            kind = "poll",
            event = "Logic",
            -- Logged out => nil: dispatcher freezes edge state (no Leave on logout / Enter on relog).
            transform = function()
                if not Player.IsAvailable() then
                    return nil
                end
                local c = Player.GetEntity().coordGrid
                return { coord = { x = c.x, z = c.z, level = c.level } }
            end,
            -- Target/radius identity: load and a Control rewrite reseed without Enter/Leave (#72).
            seedKey = function(node)
                local target = validTarget(node.GetControl("target"))
                if target == nil then
                    return nil
                end
                return string.format("%s:%s:%s:%s", target.x, target.z, target.level,
                    normalizeRadius(node.GetControl("radius")))
            end,
            filter = function(payload, node)
                local target = validTarget(node.GetControl("target"))
                if target == nil then
                    return false
                end
                local coord = payload.coord
                if coord.level ~= target.level then
                    return false
                end
                return chebyshev(coord, target) <= normalizeRadius(node.GetControl("radius"))
            end,
        },
    })
end

return Location
