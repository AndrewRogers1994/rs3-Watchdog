-- Fake client `Event` global: records Subscribe/Unsubscribe and lets a test push a raw event
-- through a named channel synchronously. Shape matches runtime.lua (`source.<Channel>.Subscribe`).
-- This is the one test seam runtime.lua exposes (injectable event source).

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

    function harness:Push(name, raw)
        local channel = channels[name]
        if channel == nil then
            return
        end
        for _, fn in pairs(channel.subscriptions) do
            fn(raw)
        end
    end

    -- Total Subscribe calls on `name` - reverse-index fan-out must subscribe a channel exactly once.
    function harness:SubscribeCount(name)
        local channel = channels[name]
        return channel ~= nil and channel.subscribeCount or 0
    end

    return harness
end

return newFakeEventSource
