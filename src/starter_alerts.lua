-- Alert Presets on the Pack named Watchdog.

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

---@param graph LibNodeGraph.Graph
---@param label string
---@param fromNode integer
---@param fromPin string
---@param toNode integer
---@param toPin string
local function connect(graph, label, fromNode, fromPin, toNode, toPin)
    local id, reason = graph:Connect(fromNode, fromPin, toNode, toPin)
    if id == nil then
        error(string.format("%s graph: %s %s -> %s", label, tostring(reason), fromPin, toPin))
    end
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
    connect(graph, "Friend login", message, "out", sound, "in")
    connect(graph, "Friend login", message, "out", toast, "show")
    connect(graph, "Friend login", message, "message", toast, "text")
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
    connect(graph, "Idle XP", logic, "out", counter, "in")
    connect(graph, "Idle XP", counter, "count", compare, "a")
    connect(graph, "Idle XP", counter, "out", branch, "in")
    connect(graph, "Idle XP", compare, "result", branch, "condition")
    -- True plays the sound and resets. Reset terminates, so that edge does not
    -- continue into the sound. XP Drop uses the same reset and has no other wire.
    connect(graph, "Idle XP", branch, "true", sound, "in")
    connect(graph, "Idle XP", branch, "true", counter, "reset")
    connect(graph, "Idle XP", xp, "out", counter, "reset")
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
    local once = graph:AddNode("std.doonce", { startClosed = false })
    local sound = graph:AddNode("action.sound", { soundId = ALERT_SOUND })
    local flash = graph:AddNode("action.screen_flash")
    connect(graph, name, trigger, "current", times100, "a")
    connect(graph, name, trigger, "max", timesThreshold, "a")
    connect(graph, name, times100, "result", compare, "a")
    connect(graph, name, timesThreshold, "result", compare, "b")
    connect(graph, name, trigger, "out", branch, "in")
    connect(graph, name, compare, "result", branch, "condition")
    connect(graph, name, branch, "true", once, "in")
    connect(graph, name, branch, "false", once, "reset")
    connect(graph, name, once, "out", sound, "in")
    connect(graph, name, once, "out", flash, "show")
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
