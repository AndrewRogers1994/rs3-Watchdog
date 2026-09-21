local Util = require("util")

local ShortestPath = {}

---@param registry LibNodeGraph.Registry
---@param runtime Watchdog.Runtime
function ShortestPath.Register(registry, runtime)
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
            if shortestpath == nil then
                print("shortestpath is not available")
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
