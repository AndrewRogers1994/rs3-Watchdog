local luaunit = require("luaunit")
local newFakeEventSource = require("fake_event_source")
local Popup = require("nodes/actions/popup")
local Toast = require("toast")

local globals = { "LibNodeGraph", "LibNodeGraphStd", "Event", "Plugin", "PluginPermissions",
    "prettyui", "id", "config", "PersistentDB", "Player", "Mouse", "LibPluginMenu",
    "shortestpath", "Watchdog", "PluginShutdown", "log", "print", "ui", "ribbon", "Vector4" }
local mainPath = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") .. "../main.lua"

TestMainTiming = {}

function TestMainTiming:setUp()
    self.saved = {}
    for _, name in ipairs(globals) do self.saved[name] = _G[name] end
    local serialize = require("serialize")
    LibNodeGraph = {
        NewRegistry = require("registry").new,
        NewGraph = require("graph").new,
        Serialize = serialize.Serialize,
        Deserialize = serialize.Deserialize,
        Json = require("json"),
        UNKNOWN_TYPE = require("registry").UNKNOWN_TYPE,
    }
    LibNodeGraphStd = { Register = function(registry)
        for _, name in ipairs({ "flow", "boolean", "compare", "mathops", "convert", "stateful" }) do
            require(name).Register(registry)
        end
    end }
    self.events = newFakeEventSource()
    Event = self.events.source
    Plugin = { HasPermission = function() return false end }
    PluginPermissions = { httpAccess = 1, trackingAccess = 2 }
    prettyui = { RibbonBar = { Register = function() return {} end } }
    id = { Sprite = {}, Component = {}, Sound = { TOWN_CRIER_BELL_RING_1 = 2608 } }
    config = { Inv = { INV = { id = 93 }, BANK = { id = 95 } } }
    PersistentDB, Mouse, LibPluginMenu, shortestpath = nil, nil, nil, nil
    Player = { IsAvailable = function() return false end }
    log, print = function() end, function() end
    ui = { Interfaces = { GetComponent = function() return nil end } }
    Vector4 = { new = function(r, g, b, a) return { r, g, b, a } end }
    dofile(mainPath)
    self.runtime = Watchdog.editor.runtime
    self.graph = LibNodeGraph.NewGraph(Watchdog.editor.registry)
    self.runtime:AddAlert(999, "Popup timing regression", self.graph, true)
end

function TestMainTiming:tearDown()
    if Watchdog and Watchdog.Stop then Watchdog.Stop() end
    for _, name in ipairs(globals) do _G[name] = self.saved[name] end
end

function TestMainTiming:tick(counter)
    self.events:Push("Logic", { logicTick = counter })
end

function TestMainTiming:draw(seconds)
    self.events:Push("Draw", { timeDeltaSecs = seconds })
end

function TestMainTiming:firePopup()
    local node = self.graph:AddNode("action.popup", { body = "Keep this notification visible", hold = 4 })
    self.graph:FireInput(node, "in")
    return self.runtime.effects.queues[Popup.OWNER].active
end

function TestMainTiming:testLogicTicksDoNotAdvanceVisualEffectsAfterReload()
    local popup = self:firePopup()
    self:tick(1000000)
    self:tick(1000001)
    self:tick(2000000)
    luaunit.assertEquals(popup.state.anim.phase, "in")
    luaunit.assertEquals(popup.state.elapsed, 0)
    luaunit.assertIs(self.runtime.effects.queues[Popup.OWNER].active, popup)
end

function TestMainTiming:testPopupDrawsForConfiguredSecondsBeforeQueueAdvances()
    self:tick(10000)
    local first = self:firePopup()
    self:firePopup()
    local queue = self.runtime.effects.queues[Popup.OWNER]
    local second = queue.pending[1]
    local rectangles = 0
    local canvas = { width = 1920, AddRectangle = function() rectangles = rectangles + 1 end }

    -- Advance the Draw subscriber by four seconds.
    for _ = 1, 200 do self:draw(0.02) end
    luaunit.assertAlmostEquals(first.state.elapsed, 4, 0.000001)
    luaunit.assertEquals(first.state.anim.phase, "hold")
    luaunit.assertIs(queue.active, first)
    self.runtime.effects:Draw(canvas)
    luaunit.assertEquals(rectangles, 1)
    luaunit.assertEquals(second.state.elapsed, 0)

    for _ = 1, 16 do self:draw(0.02) end
    luaunit.assertEquals(first.state.anim.phase, "out")
    luaunit.assertIs(queue.active, first)
    for _ = 1, 20 do self:draw(0.02) end
    luaunit.assertIs(queue.active, second)
    luaunit.assertEquals(second.state.elapsed, 0)
    self:draw(0.02)
    luaunit.assertAlmostEquals(second.state.elapsed, 0.02, 0.000001)
end

function TestMainTiming:testVariableFrameDurationsUseSecondsWhileUiUnmounted()
    self:tick(50000)
    local popup = self:firePopup()
    self:draw(0.2)
    luaunit.assertAlmostEquals(popup.state.elapsed, 0.2, 0.000001)
    self:tick(50010)
    self:draw(0)
    luaunit.assertAlmostEquals(popup.state.elapsed, 0.2, 0.000001)
    self:draw(0.2)
    luaunit.assertAlmostEquals(popup.state.elapsed, 0.4, 0.000001)
    luaunit.assertEquals(popup.state.anim.phase, "hold")
end

function TestMainTiming:testToastLifetimeUsesTheSameSecondsClock()
    self:tick(70000)
    self.runtime.toast:Show("timed", { text = "Five seconds", ttl = 5 })
    self.runtime.toast:Show("sticky", { text = "Until dismissed", sticky = true })
    for _ = 1, 200 do self:draw(0.02) end
    luaunit.assertEquals(self.runtime.toast:LiveCount(), 2)
    for _ = 1, 51 do self:draw(0.02) end
    luaunit.assertEquals(self.runtime.toast:LiveCount(), 1)
    luaunit.assertEquals(self.runtime.effects:StackCount(Toast.OWNER), 1)
    self.runtime.toast:Dismiss("sticky")
    luaunit.assertEquals(self.runtime.toast:LiveCount(), 0)
end

function TestMainTiming:testDurationIsIndependentOfFrameRate()
    for _, fps in ipairs({ 30, 60, 144 }) do
        self.runtime.effects:Clear()
        local popup = self:firePopup()
        for _ = 1, fps * 4 do self:draw(1 / fps) end
        luaunit.assertAlmostEquals(popup.state.elapsed, 4, 0.000001)
        luaunit.assertEquals(popup.state.anim.phase, "hold")
        for _ = 1, math.ceil(fps * 0.72) do self:draw(1 / fps) end
        luaunit.assertNil(self.runtime.effects.queues[Popup.OWNER].active)
    end
end

return TestMainTiming
