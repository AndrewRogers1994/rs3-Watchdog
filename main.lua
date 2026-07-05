-- Watchdog — a node-graph editor plugin.
--
-- Orchestrator: builds a live LibNodeGraph Graph over the standard + Watchdog node sets,
-- mounts the Editor UI onto the client's root component, and wires the per-frame draw /
-- per-tick update loops. Follows the idempotent load/reload pattern (CLAUDE.md): tear down
-- any prior instance up top, publish this instance as the global `watchdog` at the end.

if Watchdog ~= nil and Watchdog.Stop ~= nil then
    pcall(function() Watchdog.Stop() end)
end

local Editor = require("ui/graph")

-- Names used to Subscribe/Unsubscribe each event we hook. Events are sandboxed per-plugin
-- by the client, so these don't need a plugin-specific prefix — just enough to be unique
-- within this file and reused between Subscribe and Unsubscribe.
local Events = {
    Logic = "logic",
    Draw = "draw",
    ChatMessage = "chat",
    KeyDown = "key",
}

-- Key that toggles the editor Window. Any GameKey member name (see core/keyboard docs:
-- GameKey.F8, GameKey.P, GameKey.SPACE, ...). Change this one string to rebind.
local TOGGLE_KEY = "F8"

--- Registry + node types ----------------------------------------------------------------

local registry = LibNodeGraph.NewRegistry()
LibNodeGraphStd.Register(registry)
require("nodes/triggers/chat").Register(registry)
require("nodes/actions/log").Register(registry)

--- Demo graph + Layout ------------------------------------------------------------------
-- A small, deliberately varied graph so the Editor has real content: an event flow
-- (Chat Trigger -> Log, exec + data) and a pure data chain (Add -> Multiply).

local graph = LibNodeGraph.NewGraph(registry)

local chatNode = graph:AddNode("trigger.chat", { contains = "hello" })
local logNode  = graph:AddNode("action.log")
local addNode  = graph:AddNode("std.add", { a = 2, b = 3 })
local mulNode  = graph:AddNode("std.multiply", { a = 4, b = 5 })

-- Guard each connect so one bad edge can't stop the plugin from loading.
local function tryConnect(fromN, fromP, toN, toP)
    local ok, err = pcall(function() graph:Connect(fromN, fromP, toN, toP) end)
    if not ok and log ~= nil then
        log("Watchdog: demo connect failed — " .. tostring(err))
    end
end

tryConnect(chatNode, "out", logNode, "in")
tryConnect(chatNode, "message", logNode, "message")
tryConnect(addNode, "result", mulNode, "a")

local layout = {
    [chatNode] = { x = 80,  y = 90 },
    [logNode]  = { x = 460, y = 110 },
    [addNode]  = { x = 80,  y = 360 },
    [mulNode]  = { x = 460, y = 380 },
}

local editor = Editor.new(graph, registry, layout)

--- Client root parent (interface may not be loaded yet; retried on the Logic loop) ------

local function getRootParent()
    local candidates = { "TOPLEVEL_V2__ROOT", "TOPLEVEL__ROOT", "TOPLEVEL_V2__GAME_AREA" }
    for _, key in ipairs(candidates) do
        local componentID = id.Component[key]
        if componentID ~= nil then
            -- Returns nil (not an error) if the interface isn't loaded yet.
            local component = ui.Interfaces:GetComponent(componentID)
            if component ~= nil then
                return component
            end
        end
    end
    return nil
end

--- Event loops --------------------------------------------------------------------------

local state = { mounted = false }

local function onLogic()
    if not state.mounted then
        local parent = getRootParent()
        if parent ~= nil then
            local ok, err = pcall(function() editor:Mount(parent) end)
            if ok then
                state.mounted = true
            elseif log ~= nil then
                log("Watchdog: mount failed — " .. tostring(err))
            end
        end
        return
    end
    pcall(function() editor:update() end)
end

local function onDraw()
    if state.mounted then
        pcall(function() editor:draw() end)
    end
end

--- Public API + lifecycle ---------------------------------------------------------------

local api = {}

function api.Stop()
    pcall(function() Event.Logic.Unsubscribe(Events.Logic) end)
    pcall(function() Event.Draw.Unsubscribe(Events.Draw) end)
    pcall(function() Event.ChatMessage.Unsubscribe(Events.ChatMessage) end)
    pcall(function() Event.KeyDown.Unsubscribe(Events.KeyDown) end)
    pcall(function() editor:Unmount() end)
    state.mounted = false
end

api.editor = editor
api.graph = graph

Event.Logic.Subscribe(Events.Logic, onLogic)
Event.Draw.Subscribe(Events.Draw, onDraw)

-- Hide/show the editor Window on TOGGLE_KEY. KeyDown payload has gameKey/isRepeat
-- (core/events docs); ignore auto-repeat so a held key doesn't flicker the panel.
Event.KeyDown.Subscribe(Events.KeyDown, function(keyEvent)
    if keyEvent == nil or keyEvent.isRepeat then return end
    local target = GameKey[TOGGLE_KEY]
    if target ~= nil and keyEvent.gameKey == target then
        pcall(function() editor:Toggle() end)
    end
end)

-- Live firing of the Chat Trigger.
Event.ChatMessage.Subscribe(Events.ChatMessage, function(chatMessageEvent)
    pcall(function() graph:Fire(chatNode, chatMessageEvent) end)
end)

Watchdog = api
print("Watchdog editor loaded")

return Watchdog
