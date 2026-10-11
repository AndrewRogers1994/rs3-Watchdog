local Util = require("src/util")
local Gates = require("src/nodes/gates")

-- Same Unavailable reason the Palette draws. A fire while the gate is closed logs it
-- and does not call into the plugin.
local REASON = "needs Shortest Path"

local ShortestPath = {}

---@param registry LibNodeGraph.Registry
function ShortestPath.Register(registry)
    -- Present at load means the gate starts open. OptionalDependencyChanged flips it
    -- later without reloading Watchdog (a reload used to be the only way to register
    -- this type). `pluginEnabled` is that flag; `run` also requires the global, because
    -- there is nothing to call until the client injects it.
    -- Event payloads are userdata in the client and tables in tests; accept both.
    local pluginEnabled = shortestpath ~= nil
    if Event ~= nil and Event.OptionalDependencyChanged ~= nil then
        Event.OptionalDependencyChanged.Subscribe("watchdog.shortest_path", function(dep)
            local kind = type(dep)
            if kind ~= "table" and kind ~= "userdata" then
                return
            end
            if dep.pluginIdentifier ~= "shortestpath" then
                return
            end
            if dep.enabled ~= nil then
                pluginEnabled = dep.enabled == true
            end
        end)
    end

    Gates.Bind("action.shortest_path", function()
        if not pluginEnabled then return REASON end
    end)

    registry:RegisterNodeType("action.shortest_path", {
        category = "action",
        displayName = "Shortest Path",
        pins = {
            { name = "setpath", kind = "exec", direction = "in" },
            { name = "clearpath", kind = "exec", direction = "in" },
            { name = "start", kind = "data", direction = "in", dataType = "coordgrid", displayName = "Start Location" },
            { name = "useCurrentLocation", kind = "data", direction = "in", dataType = "bool", displayName = "Use Current Location", default = true },
            { name = "end", kind = "data", direction = "in", dataType = "coordgrid", displayName = "End Location" },
            { name = "color", kind = "data", direction = "in", dataType = "color", displayName = "Color", default = { r = 255, g = 212, b = 59, a = 255 } },
        },
        run = function(ctx)
            if not pluginEnabled or shortestpath == nil then
                print(REASON)
                return
            end
            local startCoord = ctx:In("start")
            local useCurrentLocation = ctx:In("useCurrentLocation")
            local endCoord = ctx:In("end")
            if ctx.exec == "setpath" then
                if useCurrentLocation then
                    shortestpath.StartFromPlayer(endCoord, {
                        colour = Util.ColorToInt(ctx:In("color")),
                    })
                else
                    shortestpath.Start(startCoord, endCoord, {
                        colour = Util.ColorToInt(ctx:In("color")),
                    })
                end
            elseif ctx.exec == "clearpath" then
                shortestpath.ClearPath()
            end
        end,
    })
end

return ShortestPath
