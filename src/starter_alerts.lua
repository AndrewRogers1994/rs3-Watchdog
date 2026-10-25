-- Alert Presets on the Pack named Watchdog.
-- New alert copies one into the active Scope. This module does not insert a
-- copy itself, and it does not write the Preset library.
-- 885 is DEVCOM_MINIGAME_ALERT. The graph stores that raw builtin id.

local ALERT_SOUND = 885

local StarterAlerts = {}

-- Pack layout is the same { id, x, y } array an Alert save uses.
---@param layout table<integer, { x: number, y: number }>
---@return { id: integer, x: number, y: number }[]
local function layoutArray(layout)
    local arr = {}
    for id, pos in pairs(layout) do
        arr[#arr + 1] = { id = id, x = pos.x, y = pos.y }
    end
    table.sort(arr, function(a, b) return a.id < b.id end)
    return arr
end

---@param registry LibNodeGraph.Registry
---@return Watchdog.PackAlertPreset
local function friendLogin(registry)
    local graph = LibNodeGraph.NewGraph(registry)
    -- Login/Logout is chat type group "login", id 5. An empty substring Matcher
    -- matches every line of that channel. Restricted silence is the Game
    -- Message trigger's own filter, so this graph does not add another check.
    local message = graph:AddNode("trigger.game_message", {
        type = "login",
        contains = { needle = "", mode = "substring" },
    })
    local toast = graph:AddNode("action.toast")
    local sound = graph:AddNode("action.sound", { soundId = ALERT_SOUND })
    local soundWire, soundReason = graph:Connect(message, "out", sound, "in")
    local showWire, showReason = graph:Connect(message, "out", toast, "show")
    local textWire, textReason = graph:Connect(message, "message", toast, "text")
    if soundWire == nil or showWire == nil or textWire == nil then
        error("Friend login graph: " .. tostring(soundReason or showReason or textReason))
    end
    -- 320 apart, wider than a node body, so the three nodes do not stack.
    return {
        authorId = "friend-login",
        name = "Friend login",
        graph = LibNodeGraph.Serialize(graph),
        layout = layoutArray({
            [message] = { x = 32, y = 48 },
            [toast] = { x = 352, y = 48 },
            [sound] = { x = 672, y = 48 },
        }),
        variables = {},
    }
end

---@param graph LibNodeGraph.Graph
---@param fromNode integer
---@param fromPin string
---@param toNode integer
---@param toPin string
local function connect(graph, fromNode, fromPin, toNode, toPin)
    local id, reason = graph:Connect(fromNode, fromPin, toNode, toPin)
    if id == nil then
        error(string.format("Idle XP graph: %s %s -> %s", tostring(reason), fromPin, toPin))
    end
end

---@param registry LibNodeGraph.Registry
---@return Watchdog.PackAlertPreset
local function idleXp(registry)
    local graph = LibNodeGraph.NewGraph(registry)
    -- Client Tick runs 50 times a second, so interval 5 is a tenth of a second.
    -- Fifty steps of this Counter is five seconds with no XP. Both numbers are
    -- hardcoded Controls. There is no Variable and no timer node.
    local logic = graph:AddNode("trigger.logic", { interval = 5 })
    local counter = graph:AddNode("std.counter", { step = 1, start = 0 })
    local compare = graph:AddNode("std.compare", { operation = ">=", a = 0, b = 50 })
    local branch = graph:AddNode("std.branch")
    local sound = graph:AddNode("action.sound", { soundId = ALERT_SOUND })
    local xp = graph:AddNode("trigger.xp_drop", { skillFilter = "any" })
    connect(graph, logic, "out", counter, "in")
    connect(graph, counter, "count", compare, "a")
    connect(graph, counter, "out", branch, "in")
    connect(graph, compare, "result", branch, "condition")
    -- True plays the sound and resets. Reset terminates, so that edge does not
    -- continue into the sound. XP Drop uses the same reset and has no other wire.
    connect(graph, branch, "true", sound, "in")
    connect(graph, branch, "true", counter, "reset")
    connect(graph, xp, "out", counter, "reset")
    return {
        authorId = "idle-xp",
        name = "Idle XP",
        graph = LibNodeGraph.Serialize(graph),
        -- Same 320 gap as Friend login, wider than a node body.
        layout = layoutArray({
            [logic] = { x = 32, y = 48 },
            [xp] = { x = 352, y = 48 },
            [counter] = { x = 672, y = 48 },
            [compare] = { x = 32, y = 368 },
            [branch] = { x = 352, y = 368 },
            [sound] = { x = 672, y = 368 },
        }),
        variables = {},
    }
end

-- current * 100 < max * threshold. Strict less-than, so equality is recovery.
-- A max of 0 makes both sides 0, and 0 < 0 is false, so no extra case.
-- The threshold input is the only Variable. 25 is the offered default.
local THRESHOLD_DEFAULT = 25

---@param registry LibNodeGraph.Registry
---@param resource string
---@param authorId string
---@param name string
---@return Watchdog.PackAlertPreset
local function lowResource(registry, resource, authorId, name)
    local graph = LibNodeGraph.NewGraph(registry)
    local trigger = graph:AddNode("trigger.resource_changed", { resource = resource })
    local times100 = graph:AddNode("std.math", { operation = "*", b = 100 })
    local timesThreshold = graph:AddNode("std.math", { operation = "*", b = THRESHOLD_DEFAULT })
    local compare = graph:AddNode("std.compare", { operation = "<" })
    local branch = graph:AddNode("std.branch")
    -- startClosed false: the first drop below the line plays. Later drops stay
    -- quiet until the false side resets this node.
    local once = graph:AddNode("std.doonce", { startClosed = false })
    local sound = graph:AddNode("action.sound", { soundId = ALERT_SOUND })
    -- Color, inShape, and outShape stay the node defaults. dismissOn "both"
    -- is that default too: mouse or keyboard clears the flash.
    local flash = graph:AddNode("action.screen_flash")
    local function wire(fromNode, fromPin, toNode, toPin)
        local id, reason = graph:Connect(fromNode, fromPin, toNode, toPin)
        if id == nil then
            error(string.format("%s graph: %s %s -> %s", name, tostring(reason), fromPin, toPin))
        end
    end
    wire(trigger, "current", times100, "a")
    wire(trigger, "max", timesThreshold, "a")
    wire(times100, "result", compare, "a")
    wire(timesThreshold, "result", compare, "b")
    wire(trigger, "out", branch, "in")
    wire(compare, "result", branch, "condition")
    wire(branch, "true", once, "in")
    -- reset terminates, so recovery does not continue into the sound or the flash.
    wire(branch, "false", once, "reset")
    wire(once, "out", sound, "in")
    wire(once, "out", flash, "show")
    -- Same 320 gap as Friend login, wider than a node body.
    local gap = 320
    local order = { trigger, times100, timesThreshold, compare, branch, once, sound, flash }
    local layout = {}
    for index, id in ipairs(order) do
        local col = (index - 1) % 4
        local row = math.floor((index - 1) / 4)
        layout[id] = { x = 32 + col * gap, y = 48 + row * gap }
    end
    return {
        authorId = authorId,
        name = name,
        graph = LibNodeGraph.Serialize(graph),
        layout = layoutArray(layout),
        variables = { { nodeId = timesThreshold, pinName = "b" } },
    }
end

-- `api` is the table published as Watchdog. RegisterDataPack is the method
-- another plugin calls.
---@param api { RegisterDataPack: fun(self, name: string, contributions: table|nil) }
---@param registry LibNodeGraph.Registry
function StarterAlerts.register(api, registry)
    api:RegisterDataPack("Watchdog", {
        alertPresets = {
            friendLogin(registry),
            idleXp(registry),
            lowResource(registry, "life", "low-life-points", "Low life points"),
            lowResource(registry, "prayer", "low-prayer", "Low prayer"),
        },
    })
end

return StarterAlerts
