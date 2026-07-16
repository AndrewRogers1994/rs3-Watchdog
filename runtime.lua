-- runtime.lua — the single dispatcher that owns every client `Event.*.Subscribe`/
-- `.Unsubscribe` for Watchdog's trigger nodes. Each trigger node file declares its own
-- event binding via `Runtime:BindTrigger(typeKey, entries)` instead of `main.lua`
-- hardcoding one Subscribe block per trigger type (the old `Event.ChatMessage` block this
-- replaces). The engine's node-type descriptor stays client-agnostic; bindings live here.
--
-- Per bound entry, on every raw event: `transform(raw) -> payload` runs once (identity if
-- omitted), then for each live node of that entry's typeKey, `filter(payload, node) -> bool`
-- gates it (always passes if omitted), and a pass calls `graph:Fire(nodeId, payload)` so the
-- node's own `run(ctx)` only shapes outputs and fires exec.
--
-- Every saved graph is a live "alert" (#27): the dispatcher fans out over *all* enabled alerts
-- (`Runtime:AddAlert`), not just the one the editor is viewing, so triggers fire in every alert
-- and while the editor is open mid-edit. A per-alert `enabled` flag is checked at fire time —
-- `Runtime:SetEnabled`/`Toggle` flip it in O(1) without tearing down the graph, and persist it
-- through the injected persistence hook (`Runtime:SetPersistence`, wired to the Store).
--
-- The event source is injectable (`Runtime.new(eventSource)`, defaults to the client `Event`
-- global) so tests can feed synthetic events through a fake source instead.
--
-- Runtime also owns the EffectRegistry (`runtime.effects`, see effects.lua), the shared InfoBox
-- Area (`runtime.infobox`, see ui/infobox.lua, #41), and two activity tick counters
-- (`runtime.keyboardActivityTick` / `runtime.mouseActivityTick`), consumed later by effect
-- nodes like Screen Flash's dismiss-on (#29). Keyboard activity is tracked the same
-- way as any trigger binding, through the injectable event source; mouse activity has no
-- client event to bind (see Mouse docs — position is poll-only) so it's advanced from
-- `Runtime:Update(dt)`, called once per Logic tick alongside the effect registry. Like the
-- event source, the `Mouse` global is injectable (`Runtime.new(eventSource, mouseSource)`) so
-- this is exercised under the standalone test harness too.

local Effects = require("effects")
local InfoBoxArea = require("ui/infobox")
local ScreenMarkerCapture = require("ui/screen_marker_capture")
local Util = require("util")

local Runtime = {}

-- Wraps a node-authored (or persistence-hook) callback so one bad function can't break dispatch
-- for every other binding — used by the transform/filter fan-out and the enable-persistence hook.
-- See util.lua. Declared up here so every method below (SetEnabled included) can see it.
local function callOrLog(context, fn, ...)
    return Util.CallOrLog("runtime", context, fn, ...)
end

-- The read-only `nodeHandle` handed to every node-authored hook — a filter's second arg
-- (`_fireBindingInGraph`) and the preload hook's arg (`_preloadNode`). One builder keeps the
-- `{ id, typeKey, GetControl(pinName) }` shape identical across both call sites.
local function makeNodeHandle(graph, node)
    return {
        id = node.id,
        typeKey = node.typeKey,
        GetControl = function(pinName) return graph:GetControl(node.id, pinName) end,
    }
end

-- `mouseSource` is the injectable stand-in for the client `Mouse` global (defaults to it),
-- mirroring `eventSource`'s seam: tests pass a fake exposing `IsAvailable()`/`GetPosition()`
-- instead of relying on the real (test-environment-absent) client global.
function Runtime.new(eventSource, mouseSource)
    Runtime.__index = Runtime
    local self = setmetatable({
        eventSource = eventSource or Event,
        mouseSource = mouseSource or Mouse,
        -- Every saved graph instantiates live as an "alert" (#27); the dispatcher fans out over
        -- *all* of them, not just the one the editor is viewing. `alerts` is the ordered list of
        -- { name, graph, enabled }; `_alertsByName` indexes it for O(1) SetEnabled/Toggle.
        alerts = {},
        _alertsByName = {},
        _persistence = nil,
        -- eventName -> { bindings = { { typeKey, transform, filter }, ... },
        --                subscribed, subscribeName, source }
        channels = {},
        effects = Effects.new(),
        -- The shared InfoBox Area (#41): a registry-level layout component living on the same
        -- overlay Canvas as `effects`, but not a free EffectRegistry handle (it needs per-box
        -- bounds effects deliberately disclaims — see ui/infobox.lua). Reached by action.infobox
        -- the same way nodes reach `runtime.effects`.
        infobox = InfoBoxArea.new(),
        -- The shared "Draw on screen" capture overlay (#39) behind action.screen_marker's
        -- `rect` Control — armed from the Editor (ui/graph.lua), mounted/drawn/driven from
        -- main.lua the same way runtime.infobox's own click-capture layer is.
        screenMarkerCapture = ScreenMarkerCapture.new(),
        keyboardActivityTick = 0,
        mouseActivityTick = 0,
        _lastMousePos = nil,
    }, Runtime)
    self:_bindActivityTracking()
    return self
end

-- Subscribes to KeyDown on the injectable event source to count keyboard activity (any key,
-- including repeats — "activity" just means the player touched the keyboard). Kept separate
-- from the BindTrigger/channels fan-out below since it isn't tied to a node typeKey; torn
-- down explicitly in Stop.
function Runtime:_bindActivityTracking()
    local source = self.eventSource.KeyDown
    if source == nil or source.Subscribe == nil then
        return
    end
    local runtime = self
    source.Subscribe("watchdog_runtime_activity_key", function()
        print("this is the most important print statement of all time")
        runtime.keyboardActivityTick = runtime.keyboardActivityTick + 1
    end)
    self._activitySource = source
end

-- Advances the effect registry and polls mouse-activity by position change. Called once per
-- Logic tick (see main.lua); `dt` is forwarded verbatim to every live effect handle's update.
function Runtime:Update(dt)
    self:_pollMouseActivity()
    self.effects:Update(dt)
end

-- The last polled mouse position (x, y), or nil, nil before the first Update tick / when no
-- mouseSource is injected. Lets a Draw-pass caller (main.lua, for the InfoBox Area's hover
-- tooltip) reuse the same poll _pollMouseActivity already does each Logic tick, instead of a
-- second GetPosition call of its own.
function Runtime:GetMousePos()
    local pos = self._lastMousePos
    if pos == nil then return nil, nil end
    return pos.x, pos.y
end

-- Mouse position is poll-only (no move/click event on the client — see core/mouse.lua docs),
-- hence advancing this from Update rather than a binding. `mouseSource` defaults to nil (no
-- client global set up) outside the client, so this is a no-op unless injected.
function Runtime:_pollMouseActivity()
    local mouse = self.mouseSource
    if mouse == nil or not mouse.IsAvailable() then
        return
    end
    local ok, pos = pcall(mouse.GetPosition)
    if not ok or pos == nil then
        return
    end
    local last = self._lastMousePos
    -- The first poll only establishes a baseline — there's nothing to compare yet, so it
    -- must not itself count as "activity" (a plugin load/reload isn't a mouse movement).
    if last ~= nil and (pos.x ~= last.x or pos.y ~= last.y) then
        self.mouseActivityTick = self.mouseActivityTick + 1
    end
    self._lastMousePos = { x = pos.x, y = pos.y }
end

-- Registers a live graph as an alert the dispatcher fans out over. `enabled` defaults to true;
-- a disabled alert stays live (its nodes are never torn down) but has its triggers suppressed at
-- fire time, so toggling it back on is O(1) and lossless. `name` may be nil for an anonymous
-- alert (it just can't be targeted by SetEnabled/Toggle then). A duplicate name replaces the
-- prior entry's index binding (last wins), matching the Store's name-keyed model.
--
-- Also runs the generalized `preload(node)` node-type hook (#33) over every node already in the
-- graph — this is the "graph-restore" call site: main.lua adds every restored alert exactly
-- once at startup, through this same method, so no separate restore-time pass is needed.
function Runtime:AddAlert(name, graph, enabled)
    local alert = { name = name, graph = graph, enabled = enabled ~= false }
    self.alerts[#self.alerts + 1] = alert
    if name ~= nil then
        self._alertsByName[name] = alert
    end
    self:PreloadGraph(graph)
    return alert
end

-- Injects the node-type registry (#33) so PreloadNode/PreloadGraph can look up a node's
-- descriptor by typeKey. Kept as its own seam (like SetPersistence) rather than a Runtime.new
-- param, since main.lua constructs the registry after the runtime.
function Runtime:SetRegistry(registry)
    self._registry = registry
end

-- Runs one already-resolved node's `preload(node)` hook, if its registered type declares one.
-- Shared by PreloadGraph (which holds each node from its own scan) and PreloadNode (which
-- resolves by id first), so the type lookup and hook call live in one place.
function Runtime:_preloadNode(graph, node)
    local nodeType = self._registry:GetNodeType(node.typeKey)
    if nodeType == nil or nodeType.preload == nil then
        return
    end
    callOrLog("preload error on '" .. tostring(node.typeKey) .. "'",
        nodeType.preload, makeNodeHandle(graph, node))
end

-- Runs every node's `preload(node)` node-type hook (if it has one) for one graph. A no-op
-- until SetRegistry has been called (e.g. AddAlert during early startup, before the registry
-- exists) or when `graph` is nil.
function Runtime:PreloadGraph(graph)
    if graph == nil or self._registry == nil then
        return
    end
    for _, node in ipairs(graph:GetNodes()) do
        self:_preloadNode(graph, node)
    end
end

-- Runs one node's `preload(node)` node-type hook, if its registered type has one. This is the
-- "control-commit" call site (#33): the Editor calls this right after Graph:SetControl so a
-- resource-backed node (e.g. action.custom_sound) preloads the instant its dropdown Control is
-- picked, not just at graph-restore. `node` (the hook's argument) exposes the same
-- `{ id, typeKey, GetControl(pinName) }` shape as the dispatcher's own filter nodeHandle.
function Runtime:PreloadNode(graph, nodeId)
    if graph == nil or self._registry == nil then
        return
    end
    for _, node in ipairs(graph:GetNodes()) do
        if node.id == nodeId then
            self:_preloadNode(graph, node)
            return
        end
    end
end

-- Back-compat convenience (and the single-graph test path): replace the whole alert set with one
-- anonymous, always-enabled alert. main.lua uses AddAlert for the real multi-alert startup.
function Runtime:SetGraph(graph)
    self.alerts = {}
    self._alertsByName = {}
    if graph ~= nil then
        self:AddAlert(nil, graph, true)
    end
end

-- Injects the persistence hook the alert-enable API writes through: an object exposing
-- `SetEnabled(name, enabled)` (main.lua wires it to Store.SetEnabled + Store.Save; tests pass a
-- fake that records calls). Kept as a seam so the runtime's dispatch logic never touches the
-- client PersistentDB directly.
function Runtime:SetPersistence(persistence)
    self._persistence = persistence
end

-- Enables or disables the named alert and persists the flag. Targets by free-text name (any
-- graph may toggle any alert, including itself; a stale name after a rename is an accepted no-op
-- on the in-memory side, #27). Returns true if a live alert of that name existed. Persistence is
-- attempted regardless, so the on-disk flag can be corrected even if no live alert matches.
function Runtime:SetEnabled(name, enabled)
    enabled = enabled and true or false
    local alert = self._alertsByName[name]
    if alert ~= nil then
        alert.enabled = enabled
    end
    if self._persistence ~= nil and self._persistence.SetEnabled ~= nil then
        callOrLog("persistence SetEnabled for '" .. tostring(name) .. "'",
            self._persistence.SetEnabled, name, enabled)
    end
    return alert ~= nil
end

-- Flips the named alert's enabled flag (and persists it). Returns the new enabled state, or nil
-- if no live alert of that name exists (nothing to flip).
function Runtime:Toggle(name)
    local alert = self._alertsByName[name]
    if alert == nil then
        return nil
    end
    local newEnabled = not alert.enabled
    self:SetEnabled(name, newEnabled)
    return newEnabled
end

-- Registers a trigger node type's event binding(s). `entries` is a list of
-- `{ event = "ChannelName", transform = fn(raw) -> payload, filter = fn(payload, node) -> bool }`.
-- Multi-source nodes (e.g. a future Entity Spawn node) list several entries. Each distinct
-- `event` is subscribed exactly once, no matter how many typeKeys bind to it.
function Runtime:BindTrigger(typeKey, entries)
    assert(type(typeKey) == "string" and typeKey ~= "", "BindTrigger requires a typeKey")
    assert(type(entries) == "table" and #entries > 0, "BindTrigger requires at least one binding entry")
    for _, entry in ipairs(entries) do
        assert(type(entry.event) == "string" and entry.event ~= "",
            "binding entry for '" .. typeKey .. "' requires an event name")
        local channel = self.channels[entry.event]
        if channel == nil then
            channel = { bindings = {}, subscribed = false }
            self.channels[entry.event] = channel
        end
        channel.bindings[#channel.bindings + 1] = {
            typeKey = typeKey,
            transform = entry.transform,
            filter = entry.filter,
        }
        self:_ensureSubscribed(entry.event, channel)
    end
end

function Runtime:_ensureSubscribed(eventName, channel)
    if channel.subscribed then
        return
    end
    local source = self.eventSource[eventName]
    assert(source ~= nil and source.Subscribe ~= nil, "runtime: unknown event channel '" .. eventName .. "'")

    local subscribeName = "watchdog_runtime_" .. eventName
    local runtime = self
    source.Subscribe(subscribeName, function(raw)
        runtime:_dispatch(eventName, raw)
    end)

    channel.subscribed = true
    channel.subscribeName = subscribeName
    channel.source = source
end

function Runtime:_dispatch(eventName, raw)
    local channel = self.channels[eventName]
    if channel == nil then
        return
    end
    for _, binding in ipairs(channel.bindings) do
        local payload = raw
        local transformOk = true
        if binding.transform ~= nil then
            local ok, result = callOrLog(
                "transform error on '" .. eventName .. "' for '" .. binding.typeKey .. "'",
                binding.transform, raw)
            transformOk = ok
            if ok then
                payload = result
            end
        end
        if transformOk then
            self:_fireBinding(binding, payload)
        end
    end
end

-- Fans a shaped payload out to every matching node in every *enabled* alert's graph. The
-- enabled check is done here, at fire time (not by tearing down a disabled alert), so toggling
-- an alert is O(1) and never loses graph state — a disabled alert stays live but silent. The
-- editor's current graph is just one alert among these, so its triggers fire mid-edit like any
-- other's.
function Runtime:_fireBinding(binding, payload)
    for _, alert in ipairs(self.alerts) do
        if alert.enabled then
            self:_fireBindingInGraph(binding, payload, alert.graph)
        end
    end
end

function Runtime:_fireBindingInGraph(binding, payload, graph)
    if graph == nil then
        return
    end
    for _, node in ipairs(graph:GetNodes()) do
        if node.typeKey == binding.typeKey then
            local nodeId = node.id
            local passes = true
            if binding.filter ~= nil then
                local nodeHandle = makeNodeHandle(graph, node)
                local ok, result = callOrLog(
                    "filter error on '" .. binding.typeKey .. "'",
                    binding.filter, payload, nodeHandle)
                passes = ok and (result and true or false)
            end
            if passes then
                pcall(function() graph:Fire(nodeId, payload) end)
            end
        end
    end
end

-- Unsubscribes every channel this runtime subscribed (trigger bindings + the activity
-- tracker) and empties the effect registry. Mirrors the per-event Unsubscribe calls
-- main.lua used to make by hand for each hardcoded trigger.
function Runtime:Stop()
    for _, channel in pairs(self.channels) do
        if channel.subscribed then
            local source, name = channel.source, channel.subscribeName
            pcall(function() source.Unsubscribe(name) end)
            channel.subscribed = false
        end
    end
    if self._activitySource ~= nil then
        pcall(function() self._activitySource.Unsubscribe("watchdog_runtime_activity_key") end)
        self._activitySource = nil
    end
    self.effects:Clear()
    self.infobox:Clear()
end

return Runtime
