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

local Runtime = {}

function Runtime.new(eventSource)
    Runtime.__index = Runtime
    return setmetatable({
        eventSource = eventSource or Event,
        graph = nil,
        -- eventName -> { bindings = { { typeKey, transform, filter }, ... },
        --                subscribed, subscribeName, source }
        channels = {},
    }, Runtime)
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

-- pcalls `fn`, logging (and swallowing) any error under a shared "Watchdog runtime: <context>"
-- prefix. Used for both transform and filter, which fail the same way: don't let one bad
-- node-authored function break dispatch for every other binding.
local function callOrLog(context, fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok and log ~= nil then
        log("Watchdog runtime: " .. context .. " — " .. tostring(result))
    end
    return ok, result
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

-- Unsubscribes every channel this runtime subscribed. Mirrors the per-event Unsubscribe
-- calls main.lua used to make by hand for each hardcoded trigger.
function Runtime:Stop()
    for _, channel in pairs(self.channels) do
        if channel.subscribed then
            local source, name = channel.source, channel.subscribeName
            pcall(function() source.Unsubscribe(name) end)
            channel.subscribed = false
        end
    end
end

return Runtime
