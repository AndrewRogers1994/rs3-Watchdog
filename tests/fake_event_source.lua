-- A fake client `Event` global for tests: records every Subscribe/Unsubscribe and lets a
-- test push a raw event through a named channel synchronously. Mirrors the shape runtime.lua
-- expects from `Event` - `source.<Channel>.Subscribe(name, fn)` / `.Unsubscribe(name)` - via
-- a metatable that lazily creates and caches each channel's API table on first index, just
-- like the client's real `Event` global already has every channel present.
--
-- This is the one test seam runtime.lua exposes (injectable event source); see #24's
-- acceptance criteria and docs/adr/ for the design rationale.

local function newFakeEventSource()
    local channels = {} -- name -> { subscriptions = { [subName] = fn }, subscribeCount = n }

    local source = setmetatable({}, {
        __index = function(t, name)
            local channel = { subscriptions = {}, subscribeCount = 0 }
            channels[name] = channel
            local channelAPI = {
                Subscribe = function(subName, fn)
                    channel.subscriptions[subName] = fn
                    channel.subscribeCount = channel.subscribeCount + 1
                end,
                Unsubscribe = function(subName)
                    channel.subscriptions[subName] = nil
                end,
            }
            rawset(t, name, channelAPI)
            return channelAPI
        end,
    })

    local harness = { source = source }

    -- Synchronously invokes every live subscriber on `name` with `raw`, exactly like the
    -- client firing a real game event.
    function harness:Push(name, raw)
        local channel = channels[name]
        if channel == nil then
            return
        end
        for _, fn in pairs(channel.subscriptions) do
            fn(raw)
        end
    end

    -- Total number of Subscribe calls ever made on `name` - used to assert the reverse-index
    -- fan-out subscribes a channel exactly once regardless of how many node types/nodes bind.
    function harness:SubscribeCount(name)
        local channel = channels[name]
        return channel ~= nil and channel.subscribeCount or 0
    end

    return harness
end

return newFakeEventSource
