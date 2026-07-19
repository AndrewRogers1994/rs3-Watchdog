-- Exercises the action.alert_toggle node (nodes/actions/alert_toggle.lua, #35) through a real
-- LibNodeGraph Graph plus a fake runtime standing in for runtime.lua's alert store. The node
-- has enable/disable/toggle exec-in pins (the std.gate idiom, all terminating — no exec-out) and
-- a free-text `target` string naming the alert to affect. Firing each pin must flip the target
-- alert's enabled state through runtime:SetEnabled / runtime:Toggle.

local luaunit = require("luaunit")
local AlertToggle = require("nodes/actions/alert_toggle")
-- Real engine (LibNodeGraph, on package.path — see tests/run.lua), so run() is exercised
-- through a genuine ctx rather than a fabricated one (mirrors test_infobox_node).
local Registry = require("registry")
local Graph = require("graph")

-- A minimal stand-in for runtime.lua: an in-memory `enabled` flag per alert name, mutated by
-- the same SetEnabled/Toggle API the real Runtime exposes (#27). Records call history so tests
-- can assert both the resulting state and which method the node reached for.
local function makeFakeRuntime(initial)
    local rt = {
        enabled = initial or {},
        calls = {},
    }
    function rt:SetEnabled(name, value)
        value = value and true or false
        self.enabled[name] = value
        self.calls[#self.calls + 1] = { method = "SetEnabled", name = name, value = value }
        return true
    end
    function rt:Toggle(name)
        local newValue = not self.enabled[name]
        self.enabled[name] = newValue
        self.calls[#self.calls + 1] = { method = "Toggle", name = name }
        return newValue
    end
    return rt
end

TestAlertToggleRegistration = {}

function TestAlertToggleRegistration:setUp()
    local types = {}
    local reg = { RegisterNodeType = function(_, key, desc) types[key] = desc end }
    AlertToggle.Register(reg, makeFakeRuntime())
    self.desc = types["action.alert_toggle"]
end

function TestAlertToggleRegistration:testRegistersActionAlertToggle()
    luaunit.assertNotNil(self.desc)
    luaunit.assertEquals(self.desc.category, "action")

    local byName, execOutCount = {}, 0
    for _, pin in ipairs(self.desc.pins) do
        byName[pin.name] = pin
        if pin.kind == "exec" and pin.direction == "out" then execOutCount = execOutCount + 1 end
    end
    -- Three exec-in pins, the std.gate idiom (all terminate — mutate then fire nothing).
    for _, name in ipairs({ "enable", "disable", "toggle" }) do
        luaunit.assertEquals(byName[name].kind, "exec")
        luaunit.assertEquals(byName[name].direction, "in")
        luaunit.assertTrue(byName[name].terminates)
    end
    luaunit.assertEquals(execOutCount, 0) -- no exec-out (AC)
    -- Target is a free-text string control (a data-in pin, not an exec pin).
    luaunit.assertEquals(byName.target.kind, "data")
    luaunit.assertEquals(byName.target.direction, "in")
    luaunit.assertEquals(byName.target.dataType, "string")
end

TestAlertToggleRun = {}

function TestAlertToggleRun:setUp()
    self.runtime = makeFakeRuntime({ ["Other Alert"] = false, ["Self"] = true })
    self.registry = Registry.new()
    AlertToggle.Register(self.registry, self.runtime)
    self.graph = Graph.new(self.registry)
end

function TestAlertToggleRun:add(target)
    return self.graph:AddNode("action.alert_toggle", { target = target })
end

function TestAlertToggleRun:testEnableSetsTargetEnabledTrue()
    local id = self:add("Other Alert")
    self.graph:FireInput(id, "enable")
    luaunit.assertTrue(self.runtime.enabled["Other Alert"])
    luaunit.assertEquals(self.runtime.calls[1], { method = "SetEnabled", name = "Other Alert", value = true })
end

function TestAlertToggleRun:testDisableSetsTargetEnabledFalse()
    local id = self:add("Self")
    self.graph:FireInput(id, "disable")
    luaunit.assertFalse(self.runtime.enabled["Self"])
    luaunit.assertEquals(self.runtime.calls[1], { method = "SetEnabled", name = "Self", value = false })
end

function TestAlertToggleRun:testToggleFlipsTargetEnabled()
    local id = self:add("Other Alert") -- starts false
    self.graph:FireInput(id, "toggle")
    luaunit.assertTrue(self.runtime.enabled["Other Alert"])
    self.graph:FireInput(id, "toggle")
    luaunit.assertFalse(self.runtime.enabled["Other Alert"])
    luaunit.assertEquals(self.runtime.calls[1].method, "Toggle")
end

function TestAlertToggleRun:testSelfTargetingByOwnName()
    -- A graph toggling itself just names itself in the target control — no special path.
    local id = self:add("Self") -- starts true
    self.graph:FireInput(id, "disable")
    luaunit.assertFalse(self.runtime.enabled["Self"])
    self.graph:FireInput(id, "enable")
    luaunit.assertTrue(self.runtime.enabled["Self"])
end

function TestAlertToggleRun:testEmptyTargetIsANoop()
    -- Unconfigured target (empty string) reaches neither SetEnabled nor Toggle.
    local id = self:add("")
    self.graph:FireInput(id, "enable")
    self.graph:FireInput(id, "toggle")
    luaunit.assertEquals(#self.runtime.calls, 0)
end

function TestAlertToggleRun:testNilRuntimeIsASilentNoop()
    local registry = Registry.new()
    AlertToggle.Register(registry, nil)
    local graph = Graph.new(registry)
    local id = graph:AddNode("action.alert_toggle", { target = "X" })
    local ok = pcall(function() graph:FireInput(id, "enable") end)
    luaunit.assertTrue(ok)
end
