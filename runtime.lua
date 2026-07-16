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
-- The event source is injectable (`Runtime.new(eventSource)`, defaults to the client `Event`
-- global) so tests can feed synthetic events through a fake source instead.
--
-- Runtime also owns the EffectRegistry (`runtime.effects`, see effects.lua) and two activity
-- tick counters (`runtime.keyboardActivityTick` / `runtime.mouseActivityTick`), consumed later
-- by effect nodes like Screen Flash's dismiss-on (#29). Keyboard activity is tracked the same
-- way as any trigger binding, through the injectable event source; mouse activity has no
-- client event to bind (see Mouse docs — position is poll-only) so it's advanced from
-- `Runtime:Update(dt)`, called once per Logic tick alongside the effect registry. Like the
-- event source, the `Mouse` global is injectable (`Runtime.new(eventSource, mouseSource)`) so
-- this is exercised under the standalone test harness too.

local Effects = require("effects")
local Util = require("util")

local Runtime = {}

-- `mouseSource` is the injectable stand-in for the client `Mouse` global (defaults to it),
-- mirroring `eventSource`'s seam: tests pass a fake exposing `IsAvailable()`/`GetPosition()`
-- instead of relying on the real (test-environment-absent) client global.
function Runtime.new(eventSource, mouseSource)
    Runtime.__index = Runtime
    local self = setmetatable({
        eventSource = eventSource or Event,
        mouseSource = mouseSource or Mouse,
        graph = nil,
        -- eventName -> { bindings = { { typeKey, transform, filter }, ... },
        --                subscribed, subscribeName, source }
        channels = {},
        effects = Effects.new(),
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

-- The live graph the dispatcher fans out over. Set once main.lua knows which graph it's
-- editing (restored from the Store, or freshly seeded).
function Runtime:SetGraph(graph)
    self.graph = graph
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

-- Used for both transform and filter, which fail the same way: don't let one bad
-- node-authored function break dispatch for every other binding. See util.lua.
local function callOrLog(context, fn, ...)
    return Util.CallOrLog("runtime", context, fn, ...)
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

function Runtime:_fireBinding(binding, payload)
    local graph = self.graph
    if graph == nil then
        return
    end
    for _, node in ipairs(graph:GetNodes()) do
        if node.typeKey == binding.typeKey then
            local nodeId = node.id
            local passes = true
            if binding.filter ~= nil then
                local nodeHandle = {
                    id = nodeId,
                    typeKey = node.typeKey,
                    GetControl = function(pinName) return graph:GetControl(nodeId, pinName) end,
                }
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
end

return Runtime
