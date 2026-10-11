-- Shortest Path (`action.shortest_path`, #116). The type stays registered when the
-- plugin is absent. A fire while the gate is closed does not call into it. 
-- OptionalDependencyChanged flips the gate; the next fire runs once the plugin is back.

local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local ShortestPath = require("src/nodes/actions/shortest_path")

local END_COORD = { x = 10, y = 20, z = 0 }

TestShortestPath = {}

function TestShortestPath:setUp()
    self.savedPrint = print
    self.savedEvent = _G.Event
    self.savedPath = _G.shortestpath
    self.printed = {}
    self.calls = {}
    _G.print = function(...)
        self.printed[#self.printed + 1] = table.concat({ ... }, "\t")
    end
    self.onDependency = nil
    _G.Event = {
        OptionalDependencyChanged = {
            Subscribe = function(_, fn)
                self.onDependency = fn
            end,
        },
    }
    _G.shortestpath = nil
    self.registry = Registry.new()
    self.graph = Graph.new(self.registry)
end

function TestShortestPath:tearDown()
    _G.print = self.savedPrint
    _G.Event = self.savedEvent
    _G.shortestpath = self.savedPath
end

function TestShortestPath:plugin()
    return {
        StartFromPlayer = function(...)
            self.calls[#self.calls + 1] = { method = "StartFromPlayer", n = select("#", ...), ... }
        end,
        Start = function(...)
            self.calls[#self.calls + 1] = { method = "Start", n = select("#", ...) }
        end,
        ClearPath = function()
            self.calls[#self.calls + 1] = { method = "ClearPath" }
        end,
    }
end

function TestShortestPath:place()
    return self.graph:AddNode("action.shortest_path", {
        ["end"] = END_COORD,
        useCurrentLocation = true,
    })
end

function TestShortestPath:testStaysRegisteredWhenThePluginIsAbsent()
    ShortestPath.Register(self.registry)
    local desc = self.registry:GetNodeType("action.shortest_path")
    luaunit.assertNotNil(desc)
    luaunit.assertEquals(desc.displayName, "Shortest Path")
    luaunit.assertEquals(desc.category, "action")
end

function TestShortestPath:testClosedGateDoesNotCallThePlugin()
    ShortestPath.Register(self.registry)
    local id = self:place()
    self.graph:FireInput(id, "setpath")
    luaunit.assertEquals(#self.calls, 0)
    luaunit.assertEquals(self.printed, { "needs Shortest Path" })
end

function TestShortestPath:testDependencyEventReopensAndTheNextFireRuns()
    ShortestPath.Register(self.registry)
    local id = self:place()
    self.graph:FireInput(id, "setpath")
    luaunit.assertEquals(#self.calls, 0)

    _G.shortestpath = self:plugin()
    self.onDependency({ pluginIdentifier = "shortestpath", enabled = true })
    self.graph:FireInput(id, "setpath")
    luaunit.assertEquals(#self.calls, 1)
    luaunit.assertEquals(self.calls[1].method, "StartFromPlayer")
    luaunit.assertEquals(self.calls[1][1], END_COORD)
end

function TestShortestPath:testDisablingThePluginClosesTheGateEvenIfTheGlobalRemains()
    _G.shortestpath = self:plugin()
    ShortestPath.Register(self.registry)
    local id = self:place()
    self.onDependency({ pluginIdentifier = "shortestpath", enabled = false })
    self.graph:FireInput(id, "setpath")
    luaunit.assertEquals(#self.calls, 0)
    luaunit.assertEquals(self.printed, { "needs Shortest Path" })
end

return TestShortestPath
