-- Alert Presets on the Pack named Watchdog.

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
    local message = graph:AddNode("trigger.game_message", {
        type = "login",
        contains = { needle = "", mode = "substring" },
    }, { name = "Login/logout" })
    local toast = graph:AddNode("action.toast", {
        color = { r = 0, g = 255, b = 240, a = 255 },
        icon = id.Sprite.ICON_STAR_FILL,
        sticky = false,
        hold = 5,
    }, { name = "Toast" })
    local sound = graph:AddNode("action.sound", {
        soundId = id.Sound.DEVCOM_MINIGAME_ALERT,
    }, { name = "Ding a ling" })
    connect(graph, "Friend login", message, "out", sound, "in")
    connect(graph, "Friend login", message, "out", toast, "show")
    connect(graph, "Friend login", message, "message", toast, "text")
    return {
        authorId = "friend-login",
        name = "Friend login",
        graph = LibNodeGraph.Serialize(graph),
        layout = layoutArray({
            [message] = { x = 135, y = 50 },
            [toast] = { x = 515, y = 26 },
            [sound] = { x = 514, y = 264 },
        }),
    }
end

---@param registry LibNodeGraph.Registry
---@return Watchdog.PackAlertPreset
local function idleXp(registry)
    local graph = LibNodeGraph.NewGraph(registry)
    local logic = graph:AddNode("trigger.logic", { interval = 50 }, { name = "1/sec" })
    local counter = graph:AddNode("std.counter", { step = 1, start = 0 }, { name = "Second counter" })
    local compare = graph:AddNode("std.compare", { operation = ">=", a = 0, b = 10 }, { name = "X seconds" })
    local branch = graph:AddNode("std.branch", { condition = false }, { name = "If true" })
    local xp = graph:AddNode("trigger.xp_drop", { skillFilter = "any" }, { name = "Any xp drop" })
    local once = graph:AddNode("std.doonce", { startClosed = true }, { name = "Only ding once" })
    local sound = graph:AddNode("action.sound", { soundId = id.Sound.TOWN_CRIER_BELL_RING_1 }, { name = "Ding" })
    connect(graph, "Idle XP", logic, "out", counter, "in")
    connect(graph, "Idle XP", counter, "count", compare, "a")
    connect(graph, "Idle XP", counter, "out", branch, "in")
    connect(graph, "Idle XP", compare, "result", branch, "condition")
    connect(graph, "Idle XP", branch, "true", once, "in")
    connect(graph, "Idle XP", xp, "out", once, "reset")
    connect(graph, "Idle XP", xp, "out", counter, "reset")
    connect(graph, "Idle XP", once, "out", sound, "in")
    return {
        authorId = "idle-xp",
        name = "Idle XP",
        graph = LibNodeGraph.Serialize(graph),
        layout = layoutArray({
            [logic] = { x = 6, y = 10 },
            [counter] = { x = 282, y = 9 },
            [compare] = { x = 580, y = 13 },
            [branch] = { x = 61, y = 279 },
            [xp] = { x = 6, y = 112 },
            [once] = { x = 343, y = 279 },
            [sound] = { x = 615, y = 279 },
        }),
        variables = {
            { nodeId = compare, pinName = "b" },
            { nodeId = xp, pinName = "skillFilter" },
        },
    }
end

local THRESHOLD_DEFAULT = 4
local FLASH_RED = { r = 255, g = 0, b = 0, a = 127 }
local FLASH_PRAYER = { r = 89, g = 0, b = 255, a = 127 }

---@param registry LibNodeGraph.Registry
---@param resource string
---@param authorId string
---@param name string
---@param soundId number
---@param flashColor { r: integer, g: integer, b: integer, a: integer }
---@param triggerName string
---@return Watchdog.PackAlertPreset
local function lowResource(registry, resource, authorId, name, soundId, flashColor, triggerName)
    local graph = LibNodeGraph.NewGraph(registry)
    local trigger = graph:AddNode("trigger.resource_changed", { resource = resource }, { name = triggerName })
    local divide = graph:AddNode("std.math", { operation = "/", a = 0, b = THRESHOLD_DEFAULT }, { name = "25%" })
    local compare = graph:AddNode("std.compare", { operation = "<=", a = 0, b = 0 }, { name = "Less than or equal" })
    local branch = graph:AddNode("std.branch", { condition = false }, { name = "Condition branch" })
    local once = graph:AddNode("std.doonce", { startClosed = false }, { name = "Only alert once" })
    local sound = graph:AddNode("action.sound", { soundId = soundId })
    local flash = graph:AddNode("action.screen_flash", {
        color = flashColor,
        inShape = "instant",
        outShape = "instant",
        dismissOn = "both",
    })
    connect(graph, name, trigger, "current", compare, "a")
    connect(graph, name, trigger, "max", divide, "a")
    connect(graph, name, divide, "result", compare, "b")
    connect(graph, name, trigger, "out", branch, "in")
    connect(graph, name, compare, "result", branch, "condition")
    connect(graph, name, branch, "true", once, "in")
    connect(graph, name, branch, "false", once, "reset")
    connect(graph, name, once, "out", sound, "in")
    connect(graph, name, once, "out", flash, "show")
    return {
        authorId = authorId,
        name = name,
        graph = LibNodeGraph.Serialize(graph),
        -- Positions from the saved preset. Sound and flash share a column.
        layout = layoutArray({
            [trigger] = { x = 9, y = 9 },
            [divide] = { x = 281, y = 17 },
            [compare] = { x = 581, y = 18 },
            [branch] = { x = 61, y = 238 },
            [once] = { x = 336, y = 238 },
            [sound] = { x = 615, y = 165 },
            [flash] = { x = 615, y = 314 },
        }),
        variables = { { nodeId = divide, pinName = "b" } },
    }
end

---@param registry LibNodeGraph.Registry
---@return Watchdog.PackAlertPreset
local function tickCounter(registry)
    local graph = LibNodeGraph.NewGraph(registry)
    -- Taken from the saved preset "Tick Counter". Server Tick interval 1 is
    -- every server tick. The count is shown in the infobox. At or above the
    -- marked number, the branch resets the counter. The infobox icon and that
    -- number are the Variables.
    local tick = graph:AddNode("trigger.server_logic", { interval = 1 }, { name = "Each tick" })
    local counter = graph:AddNode("std.counter", { step = 1, start = 0 }, { name = "Tick Counter" })
    local box = graph:AddNode("action.infobox", {
        icon = id.Sprite.RS3_ICON_CHECK_MARK_24PX_0,
        title = "",
        dismissWhenEmpty = false,
        color = { r = 255, g = 255, b = 255, a = 255 },
    }, { name = "Tick infobox" })
    local compare = graph:AddNode("std.greaterorequal", { a = 0, b = 4 }, { name = "Loop X ticks" })
    local branch = graph:AddNode("std.branch", { condition = false }, { name = "Reset loop" })
    connect(graph, "Tick Counter", tick, "out", counter, "in")
    connect(graph, "Tick Counter", counter, "count", box, "value")
    connect(graph, "Tick Counter", counter, "count", compare, "a")
    connect(graph, "Tick Counter", counter, "out", branch, "in")
    connect(graph, "Tick Counter", counter, "out", box, "update")
    connect(graph, "Tick Counter", compare, "result", branch, "condition")
    connect(graph, "Tick Counter", branch, "true", counter, "reset")
    return {
        authorId = "tick-counter",
        name = "Tick Counter",
        graph = LibNodeGraph.Serialize(graph),
        layout = layoutArray({
            [tick] = { x = 9, y = 11 },
            [counter] = { x = 304, y = 11 },
            [box] = { x = 611, y = 11 },
            [compare] = { x = 50, y = 221 },
            [branch] = { x = 348, y = 225 },
        }),
        variables = {
            { nodeId = box, pinName = "icon" },
            { nodeId = compare, pinName = "b" },
        },
    }
end

---@param api { RegisterDataPack: fun(self, name: string, contributions: table|nil) }
---@param registry LibNodeGraph.Registry
function StarterAlerts.register(api, registry)
    local horn = id.Sound.FISHCOMP_KLAXON
    local alertBells = id.Sound.CHOSEN_HAM_BASE_ALARM
    local alertBellsLong = id.Sound.MAH3_HEIST_ALARM
    api:RegisterDataPack("Watchdog", {
        alertPresets = {
            friendLogin(registry),
            idleXp(registry),
            tickCounter(registry),
            lowResource(registry, "life", "low-life-points", "Low life points", alertBells, FLASH_RED, "Life"),
            lowResource(registry, "prayer", "low-prayer", "Low prayer", horn, FLASH_PRAYER, "Prayer"),
        },
    })
end

return StarterAlerts
