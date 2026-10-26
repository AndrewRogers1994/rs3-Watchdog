-- Starter Alert Presets on the Pack Watchdog registers at startup.
-- Loaded the way the timing tests load main.lua. No PrettyUI, and no New alert widget tree.
-- A copy is checked through PresetCopy, the same seam as the Pack alert tests.

local luaunit = require("luaunit")
local newFakeEventSource = require("fake_event_source")

local Packs = require("src/packs")
local PackRows = require("src/pack_rows")
local PresetCopy = require("src/preset_copy")
local Store = require("src/store")
local ChatTypes = require("src/chat_types")

local globals = { "LibNodeGraph", "LibNodeGraphStd", "Event", "Plugin", "PluginPermissions",
    "prettyui", "id", "config", "PersistentDB", "Player", "Mouse", "LibPluginMenu",
    "shortestpath", "Watchdog", "PluginShutdown", "log", "print", "ui", "ribbon", "Vector4" }
local mainPath = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") .. "../main.lua"

TestStarterAlerts = {}

function TestStarterAlerts:setUp()
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
    PluginPermissions = { httpAccess = 1, trackingAccess = 2, chatAccess = 3 }
    prettyui = { RibbonBar = { Register = function() return { Destroy = function() end } end } }
    id = {
        Sprite = {
            RS3_ICON_CHECK_MARK_24PX_0 = 17127,
            ICON_STAR_FILL = 12764,
            COINS = 431,
            EXCLAMATION_MARK = 937,
            RS3_ICON_BOSS_COLLECTION_LOG_0 = 15064,
            ICON_RIBBON_QUESTS_INACTIVE = 6953,
            RS3_ICON_LEAGUES_TASK_LEVEL_1_ACTIVE = 35246,
            RS3_ICON_LEAGUES_TASK_LEVEL_2_ACTIVE = 35247,
            RS3_ICON_LEAGUES_TASK_LEVEL_3_ACTIVE = 35248,
            RS3_ICON_LEAGUES_TASK_LEVEL_4_ACTIVE = 35249,
            RS3_ICON_LEAGUES_TASK_LEVEL_5_ACTIVE = 35250,
        },
        Component = {},
        Sound = {
            TOWN_CRIER_BELL_RING_1 = 3964,
            DEVCOM_MINIGAME_ALERT = 885,
            FISHCOMP_KLAXON = 15659,
            CHOSEN_HAM_BASE_ALARM = 32376,
        },
    }
    config = { Inv = { INV = { id = 93 }, BANK = { id = 95 } } }
    Mouse, LibPluginMenu, shortestpath = nil, nil, nil
    Player = { IsAvailable = function() return false end }
    log, print = function() end, function() end
    ui = { Interfaces = { GetComponent = function() return nil end } }
    Vector4 = { new = function(r, g, b, a) return { r, g, b, a } end }

    -- Missing global Bucket stays empty. The Preset library string is a sentinel.
    -- Registration must not rewrite it.
    self.presetsSentinel = "library-sentinel"
    PersistentDB = {
        data = { presets = self.presetsSentinel },
        GetString = function(db, key) return db.data[key] end,
        SetString = function(db, key, value) db.data[key] = value end,
    }
    dofile(mainPath)
    self.packs = Packs.live()
    self.registry = Watchdog.editor.registry
end

function TestStarterAlerts:tearDown()
    require("src/nodes/triggers/resource").SetReader(nil)
    audio = nil
    if Watchdog and Watchdog.Stop then Watchdog.Stop() end
    for _, name in ipairs(globals) do _G[name] = self.saved[name] end
end

local function entryKeys(entry)
    local keys = {}
    for key in pairs(entry) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

local function onlyNode(graph, typeKey)
    local found = nil
    for _, node in ipairs(graph:GetNodes()) do
        if node.typeKey == typeKey then
            if found ~= nil then
                error("more than one " .. typeKey)
            end
            found = node.id
        end
    end
    if found == nil then
        error("missing " .. typeKey)
    end
    return found
end

local function sortedWires(graph)
    local wires = {}
    for _, conn in ipairs(graph:GetConnections()) do
        wires[#wires + 1] = string.format(
            "%d.%s->%d.%s", conn.fromNode, conn.fromPin, conn.toNode, conn.toPin)
    end
    table.sort(wires)
    return wires
end

local function loginGroup(key)
    for _, group in ipairs(ChatTypes.GAME_MESSAGE) do
        if group.key == key then return group end
    end
    return nil
end

-- Startup registers Pack Watchdog. Friend login copies as an ordinary Alert:
-- Login/Logout (chat type id 5), the chat line on a mint star Toast held for
-- 5 seconds, and builtin sound 885. The contains matcher stays empty, so
-- every login line matches. The copy drops the author id. Nothing is
-- inserted into the global Scope, and the Preset library is left alone.
function TestStarterAlerts:testFriendLoginCopiesAnOrdinaryAlert()
    luaunit.assertNotNil(self.packs)
    local groups = PackRows.AlertPresetGroups(self.packs)
    local watchdog = nil
    for _, group in ipairs(groups) do
        if group.packName == "Watchdog" then watchdog = group end
    end
    luaunit.assertNotNil(watchdog)

    local friend = self.packs:GetAlertPreset("Watchdog", "friend-login")
    luaunit.assertNotNil(friend)
    luaunit.assertEquals(friend.name, "Friend login")
    luaunit.assertEquals(friend.authorId, "friend-login")
    luaunit.assertEquals(friend.variables, {})

    luaunit.assertEquals(Watchdog.document.entries, {})
    luaunit.assertNil(PersistentDB.data.global)
    luaunit.assertEquals(PersistentDB.data.presets, self.presetsSentinel)

    local bucket = Store.Empty()
    local entry, live, layout, err = PresetCopy.InstantiateSnapshot(bucket, friend, self.registry)
    luaunit.assertNil(err)
    luaunit.assertNotNil(entry)
    luaunit.assertEquals(entry.name, "Friend login")
    luaunit.assertEquals(entry.kind, "alert")
    luaunit.assertEquals(entry.enabled, true)
    luaunit.assertEquals(entryKeys(entry), { "enabled", "graph", "id", "kind", "layout", "name" })
    luaunit.assertEquals(Watchdog.document.entries, {})
    luaunit.assertNil(PersistentDB.data.global)
    luaunit.assertEquals(PersistentDB.data.presets, self.presetsSentinel)
    luaunit.assertEquals(self.packs:GetAlertPreset("Watchdog", "friend-login").authorId, "friend-login")

    luaunit.assertEquals(#live:GetNodes(), 3)
    local message = onlyNode(live, "trigger.game_message")
    local toast = onlyNode(live, "action.toast")
    local sound = onlyNode(live, "action.sound")
    local typeKey = live:GetControl(message, "type")
    luaunit.assertEquals(typeKey, "login")
    local group = loginGroup(typeKey)
    luaunit.assertNotNil(group)
    luaunit.assertEquals(group.label, "Login/Logout")
    luaunit.assertEquals(group.ids, { 5 })
    luaunit.assertEquals(live:GetControl(message, "contains"), { needle = "", mode = "substring" })
    luaunit.assertEquals(live:GetControl(toast, "color"), { r = 0, g = 255, b = 240, a = 255 })
    luaunit.assertEquals(live:GetControl(toast, "icon"), 12764)
    luaunit.assertEquals(live:GetControl(toast, "sticky"), false)
    luaunit.assertEquals(live:GetControl(toast, "hold"), 5)
    luaunit.assertEquals(live:GetControl(sound, "soundId"), 885)
    local expectedWires = {
        string.format("%d.message->%d.text", message, toast),
        string.format("%d.out->%d.in", message, sound),
        string.format("%d.out->%d.show", message, toast),
    }
    table.sort(expectedWires)
    luaunit.assertEquals(sortedWires(live), expectedWires)

    luaunit.assertEquals(#entry.layout, 3)
    local seen = {}
    for _, pos in ipairs(entry.layout) do
        luaunit.assertNil(seen[pos.id])
        seen[pos.id] = true
        luaunit.assertEquals(layout[pos.id].x, pos.x)
        luaunit.assertEquals(layout[pos.id].y, pos.y)
    end
    luaunit.assertEquals(layout[message], { x = 135, y = 50 })
    luaunit.assertEquals(layout[toast], { x = 515, y = 26 })
    luaunit.assertEquals(layout[sound], { x = 514, y = 264 })
    luaunit.assertEquals(seen[message], true)
    luaunit.assertEquals(seen[toast], true)
    luaunit.assertEquals(seen[sound], true)
end

local function sortedTypeKeys(graph)
    local types = {}
    for _, node in ipairs(graph:GetNodes()) do
        types[#types + 1] = node.typeKey
    end
    table.sort(types)
    return types
end

local function pinTerminates(graph, nodeId, pinName)
    for _, pin in ipairs(graph:GetPins(nodeId)) do
        if pin.name == pinName then return pin.terminates == true end
    end
    return false
end

-- Idle XP copies as an ordinary Alert. Client Tick interval 50 steps a Counter
-- once a second. Compare b defaults to 10 and is a Variable. Do Once starts
-- closed, so the first stretch of idle time stays quiet. An XP drop resets
-- the counter and re-arms Do Once, and its skill filter is the other Variable.
-- Reset terminates, so the drop does not reach the sound.
function TestStarterAlerts:testIdleXpCopiesAnOrdinaryAlert()
    luaunit.assertNotNil(self.packs)
    local groups = PackRows.AlertPresetGroups(self.packs)
    luaunit.assertEquals(#groups, 1)
    luaunit.assertEquals(groups[1].packName, "Watchdog")
    local authorIds = {}
    for _, preset in ipairs(groups[1].presets) do
        authorIds[#authorIds + 1] = preset.authorId
    end
    table.sort(authorIds)
    luaunit.assertEquals(authorIds, {
        "friend-login", "idle-xp", "low-life-points", "low-prayer", "tick-counter",
    })

    local idle = self.packs:GetAlertPreset("Watchdog", "idle-xp")
    luaunit.assertNotNil(idle)
    luaunit.assertEquals(idle.name, "Idle XP")
    luaunit.assertEquals(idle.authorId, "idle-xp")
    luaunit.assertEquals(#idle.variables, 2)
    luaunit.assertEquals(idle.variables[1].pinName, "b")
    luaunit.assertEquals(idle.variables[2].pinName, "skillFilter")

    local bucket = Store.Empty()
    local entry, live, layout, err = PresetCopy.InstantiateSnapshot(
        bucket, idle, self.registry, { 10, "any" })
    luaunit.assertNil(err)
    luaunit.assertNotNil(entry)
    luaunit.assertEquals(entry.name, "Idle XP")
    luaunit.assertEquals(entry.kind, "alert")
    luaunit.assertEquals(entry.enabled, true)
    luaunit.assertEquals(entryKeys(entry), { "enabled", "graph", "id", "kind", "layout", "name" })
    luaunit.assertEquals(Watchdog.document.entries, {})
    luaunit.assertNil(PersistentDB.data.global)
    luaunit.assertEquals(PersistentDB.data.presets, self.presetsSentinel)

    luaunit.assertEquals(sortedTypeKeys(live), {
        "action.sound",
        "std.branch",
        "std.compare",
        "std.counter",
        "std.doonce",
        "trigger.logic",
        "trigger.xp_drop",
    })
    local logic = onlyNode(live, "trigger.logic")
    local counter = onlyNode(live, "std.counter")
    local compare = onlyNode(live, "std.compare")
    local branch = onlyNode(live, "std.branch")
    local once = onlyNode(live, "std.doonce")
    local sound = onlyNode(live, "action.sound")
    local xp = onlyNode(live, "trigger.xp_drop")

    luaunit.assertEquals(idle.variables[1].nodeId, compare)
    luaunit.assertEquals(idle.variables[2].nodeId, xp)
    luaunit.assertEquals(live:GetControl(logic, "interval"), 50)
    luaunit.assertEquals(live:GetControl(counter, "step"), 1)
    luaunit.assertEquals(live:GetControl(counter, "start"), 0)
    luaunit.assertEquals(live:GetControl(compare, "operation"), ">=")
    luaunit.assertEquals(live:GetControl(compare, "b"), 10)
    luaunit.assertEquals(live:GetControl(once, "startClosed"), true)
    luaunit.assertEquals(live:GetControl(sound, "soundId"), 3964)
    luaunit.assertEquals(live:GetControl(xp, "skillFilter"), "any")
    luaunit.assertTrue(pinTerminates(live, counter, "reset"))
    luaunit.assertTrue(pinTerminates(live, once, "reset"))

    local expectedWires = {
        string.format("%d.out->%d.in", logic, counter),
        string.format("%d.count->%d.a", counter, compare),
        string.format("%d.out->%d.in", counter, branch),
        string.format("%d.result->%d.condition", compare, branch),
        string.format("%d.true->%d.in", branch, once),
        string.format("%d.out->%d.reset", xp, once),
        string.format("%d.out->%d.reset", xp, counter),
        string.format("%d.out->%d.in", once, sound),
    }
    table.sort(expectedWires)
    luaunit.assertEquals(sortedWires(live), expectedWires)

    luaunit.assertEquals(#entry.layout, 7)
    local seen = {}
    for _, pos in ipairs(entry.layout) do
        luaunit.assertNil(seen[pos.id])
        seen[pos.id] = true
        luaunit.assertEquals(layout[pos.id].x, pos.x)
        luaunit.assertEquals(layout[pos.id].y, pos.y)
    end
    luaunit.assertEquals(layout[logic], { x = 6, y = 10 })
    luaunit.assertEquals(layout[counter], { x = 282, y = 9 })
    luaunit.assertEquals(layout[compare], { x = 580, y = 13 })
    luaunit.assertEquals(layout[branch], { x = 61, y = 279 })
    luaunit.assertEquals(layout[xp], { x = 6, y = 112 })
    luaunit.assertEquals(layout[once], { x = 343, y = 279 })
    luaunit.assertEquals(layout[sound], { x = 615, y = 279 })
    for _, id in ipairs({ logic, counter, compare, branch, xp, once, sound }) do
        luaunit.assertEquals(seen[id], true)
    end
end

-- Tick Counter copies as an ordinary Alert. Each server tick steps a Counter
-- and updates an infobox. At or above the marked number the branch resets the
-- counter. The icon and that number are the Variables. The global Scope stays
-- empty.
function TestStarterAlerts:testTickCounterCopiesAnOrdinaryAlert()
    local preset = self.packs:GetAlertPreset("Watchdog", "tick-counter")
    luaunit.assertNotNil(preset)
    luaunit.assertEquals(preset.name, "Tick Counter")
    luaunit.assertEquals(preset.authorId, "tick-counter")
    luaunit.assertEquals(#preset.variables, 2)
    luaunit.assertEquals(preset.variables[1].pinName, "icon")
    luaunit.assertEquals(preset.variables[2].pinName, "b")

    local bucket = Store.Empty()
    local entry, live, layout, err = PresetCopy.InstantiateSnapshot(
        bucket, preset, self.registry, { 17127, 4 })
    luaunit.assertNil(err)
    luaunit.assertNotNil(entry)
    luaunit.assertEquals(entry.name, "Tick Counter")
    luaunit.assertEquals(entry.kind, "alert")
    luaunit.assertEquals(entry.enabled, true)
    luaunit.assertEquals(Watchdog.document.entries, {})
    luaunit.assertNil(PersistentDB.data.global)
    luaunit.assertEquals(PersistentDB.data.presets, self.presetsSentinel)

    luaunit.assertEquals(sortedTypeKeys(live), {
        "action.infobox",
        "std.branch",
        "std.counter",
        "std.greaterorequal",
        "trigger.server_logic",
    })
    local tick = onlyNode(live, "trigger.server_logic")
    local counter = onlyNode(live, "std.counter")
    local box = onlyNode(live, "action.infobox")
    local compare = onlyNode(live, "std.greaterorequal")
    local branch = onlyNode(live, "std.branch")

    luaunit.assertEquals(preset.variables[1].nodeId, box)
    luaunit.assertEquals(preset.variables[2].nodeId, compare)
    luaunit.assertEquals(live:GetControl(tick, "interval"), 1)
    luaunit.assertEquals(live:GetControl(counter, "step"), 1)
    luaunit.assertEquals(live:GetControl(counter, "start"), 0)
    luaunit.assertEquals(live:GetControl(box, "icon"), 17127)
    luaunit.assertEquals(live:GetControl(box, "color"), { r = 255, g = 255, b = 255, a = 255 })
    luaunit.assertEquals(live:GetControl(box, "dismissWhenEmpty"), false)
    luaunit.assertEquals(live:GetControl(compare, "b"), 4)
    luaunit.assertTrue(pinTerminates(live, counter, "reset"))

    local expectedWires = {
        string.format("%d.out->%d.in", tick, counter),
        string.format("%d.count->%d.value", counter, box),
        string.format("%d.count->%d.a", counter, compare),
        string.format("%d.out->%d.in", counter, branch),
        string.format("%d.out->%d.update", counter, box),
        string.format("%d.result->%d.condition", compare, branch),
        string.format("%d.true->%d.reset", branch, counter),
    }
    table.sort(expectedWires)
    luaunit.assertEquals(sortedWires(live), expectedWires)

    luaunit.assertEquals(#entry.layout, 5)
    luaunit.assertEquals(layout[tick], { x = 9, y = 11 })
    luaunit.assertEquals(layout[counter], { x = 304, y = 11 })
    luaunit.assertEquals(layout[box], { x = 611, y = 11 })
    luaunit.assertEquals(layout[compare], { x = 50, y = 221 })
    luaunit.assertEquals(layout[branch], { x = 348, y = 225 })
end

local LOW_RESOURCES = {
    -- Life wakes on LIFEPOINTS. Prayer wakes on base var 3274.
    {
        authorId = "low-life-points", name = "Low life points", resource = "life",
        wake = -1669, other = 3274, soundId = 32376,
        flash = { r = 255, g = 0, b = 0, a = 127 },
    },
    {
        authorId = "low-prayer", name = "Low prayer", resource = "prayer",
        wake = 3274, other = -1669, soundId = 15659,
        flash = { r = 89, g = 0, b = 255, a = 127 },
    },
}

local function serializedNode(graph, id)
    for _, node in ipairs(graph.nodes) do
        if node.id == id then return node end
    end
    return nil
end

-- Low life points and Low prayer copy as ordinary Alerts. Current is compared,
-- less-than-or-equal, with max divided by the marked pin. That pin defaults to
-- 4 and is the only Variable. True goes through Do Once (startClosed false)
-- to the sound and Screen Flash. False resets Do Once and stops there.
-- Life flashes red and plays the ham-base alarm. Prayer keeps the saved blue
-- flash and the klaxon. dismissOn is both.
function TestStarterAlerts:testLowResourceCopiesAnOrdinaryAlert()
    for _, spec in ipairs(LOW_RESOURCES) do
        local preset = self.packs:GetAlertPreset("Watchdog", spec.authorId)
        luaunit.assertNotNil(preset)
        luaunit.assertEquals(preset.name, spec.name)
        luaunit.assertEquals(preset.authorId, spec.authorId)
        luaunit.assertEquals(#preset.variables, 1)
        local mark = preset.variables[1]
        luaunit.assertEquals(mark.pinName, "b")
        local marked = serializedNode(preset.graph, mark.nodeId)
        luaunit.assertNotNil(marked)
        luaunit.assertEquals(marked.type, "std.math")
        luaunit.assertEquals(marked.controls.operation, "/")
        luaunit.assertEquals(marked.controls.b, 4)

        local bucket = Store.Empty()
        local entry, live, layout, err = PresetCopy.InstantiateSnapshot(
            bucket, preset, self.registry, { 4 })
        luaunit.assertNil(err)
        luaunit.assertNotNil(entry)
        luaunit.assertEquals(entry.name, spec.name)
        luaunit.assertEquals(entry.kind, "alert")
        luaunit.assertEquals(entry.enabled, true)
        luaunit.assertEquals(entryKeys(entry), { "enabled", "graph", "id", "kind", "layout", "name" })
        luaunit.assertEquals(Watchdog.document.entries, {})
        luaunit.assertNil(PersistentDB.data.global)
        luaunit.assertEquals(PersistentDB.data.presets, self.presetsSentinel)

        luaunit.assertEquals(sortedTypeKeys(live), {
            "action.screen_flash",
            "action.sound",
            "std.branch",
            "std.compare",
            "std.doonce",
            "std.math",
            "trigger.resource_changed",
        })
        local resource = onlyNode(live, "trigger.resource_changed")
        local compare = onlyNode(live, "std.compare")
        local branch = onlyNode(live, "std.branch")
        local once = onlyNode(live, "std.doonce")
        local sound = onlyNode(live, "action.sound")
        local flash = onlyNode(live, "action.screen_flash")

        luaunit.assertEquals(live:GetControl(resource, "resource"), spec.resource)
        luaunit.assertEquals(live:GetControl(mark.nodeId, "operation"), "/")
        luaunit.assertEquals(live:GetControl(mark.nodeId, "b"), 4)
        luaunit.assertEquals(live:GetControl(compare, "operation"), "<=")
        luaunit.assertEquals(live:GetControl(once, "startClosed"), false)
        luaunit.assertEquals(live:GetControl(sound, "soundId"), spec.soundId)
        luaunit.assertEquals(live:GetControl(flash, "dismissOn"), "both")
        luaunit.assertEquals(live:GetControl(flash, "color"), spec.flash)
        luaunit.assertEquals(live:GetControl(flash, "inShape"), "instant")
        luaunit.assertEquals(live:GetControl(flash, "outShape"), "instant")
        luaunit.assertTrue(pinTerminates(live, once, "reset"))

        local expectedWires = {
            string.format("%d.current->%d.a", resource, compare),
            string.format("%d.max->%d.a", resource, mark.nodeId),
            string.format("%d.result->%d.b", mark.nodeId, compare),
            string.format("%d.out->%d.in", resource, branch),
            string.format("%d.result->%d.condition", compare, branch),
            string.format("%d.true->%d.in", branch, once),
            string.format("%d.false->%d.reset", branch, once),
            string.format("%d.out->%d.in", once, sound),
            string.format("%d.out->%d.show", once, flash),
        }
        table.sort(expectedWires)
        luaunit.assertEquals(sortedWires(live), expectedWires)

        luaunit.assertEquals(#entry.layout, 7)
        local seen = {}
        for _, pos in ipairs(entry.layout) do
            luaunit.assertNil(seen[pos.id])
            seen[pos.id] = true
            luaunit.assertEquals(layout[pos.id].x, pos.x)
            luaunit.assertEquals(layout[pos.id].y, pos.y)
        end
        luaunit.assertEquals(layout[resource], { x = 9, y = 9 })
        luaunit.assertEquals(layout[mark.nodeId], { x = 281, y = 17 })
        luaunit.assertEquals(layout[compare], { x = 581, y = 18 })
        luaunit.assertEquals(layout[branch], { x = 61, y = 238 })
        luaunit.assertEquals(layout[once], { x = 336, y = 238 })
        luaunit.assertEquals(layout[sound], { x = 615, y = 165 })
        luaunit.assertEquals(layout[flash], { x = 615, y = 314 })
        for _, id in ipairs({ resource, mark.nodeId, compare, branch, once, sound, flash }) do
            luaunit.assertEquals(seen[id], true)
        end
    end
end

-- Worked pool: max 1000 and divisor 4 meet at current 250.
-- 250 is still on the line, because the compare is <=. 251 recovers.
-- 0 <= 0, so an empty pool alarms. The first sample stays silent.
local function transmitVar(events, id)
    events:Push("VarTransmit", { var = { id = id, oldValue = -1, newValue = -2 } })
end

function TestStarterAlerts:testLowResourceAlarmsOnceUntilThePoolRecovers()
    local plays = {}
    audio = {
        AudioBus = { SFX = "sfx" },
        SoundPlaybackParams = { new = function() return {} end },
        Play = function(soundId)
            plays[#plays + 1] = soundId
        end,
    }
    local pool = { current = 249, max = 1000 }
    require("src/nodes/triggers/resource").SetReader(function()
        return pool.current, pool.max
    end)
    local runtime = Watchdog.editor.runtime

    for _, spec in ipairs(LOW_RESOURCES) do
        plays = {}
        pool.current = 249
        pool.max = 1000
        local preset = self.packs:GetAlertPreset("Watchdog", spec.authorId)
        local bucket = Store.Empty()
        local _, live = PresetCopy.InstantiateSnapshot(bucket, preset, self.registry, { 4 })
        runtime:SetGraph(live)
        local flash = onlyNode(live, "action.screen_flash")
        local soundId = spec.soundId

        transmitVar(self.events, spec.wake)
        luaunit.assertEquals(plays, {})
        luaunit.assertNil(live:GetState(flash).handle)

        pool.current = 100
        transmitVar(self.events, spec.other)
        luaunit.assertEquals(plays, {})

        transmitVar(self.events, spec.wake)
        luaunit.assertEquals(plays, { soundId })
        local shown = live:GetState(flash).handle
        luaunit.assertNotNil(shown)
        luaunit.assertEquals(shown.kind, "screen_flash")

        pool.current = 50
        transmitVar(self.events, spec.wake)
        luaunit.assertEquals(plays, { soundId })
        luaunit.assertEquals(live:GetState(flash).handle, shown)

        pool.current = 250
        transmitVar(self.events, spec.wake)
        luaunit.assertEquals(plays, { soundId })
        luaunit.assertEquals(live:GetState(flash).handle, shown)

        pool.current = 251
        transmitVar(self.events, spec.wake)
        luaunit.assertEquals(plays, { soundId })
        luaunit.assertEquals(live:GetState(flash).handle, shown)

        pool.current = 200
        transmitVar(self.events, spec.wake)
        luaunit.assertEquals(plays, { soundId, soundId })
        luaunit.assertNotEquals(live:GetState(flash).handle, shown)

        pool.current = 1000
        transmitVar(self.events, spec.wake)
        luaunit.assertEquals(plays, { soundId, soundId })

        pool.current = 0
        pool.max = 0
        transmitVar(self.events, spec.wake)
        luaunit.assertEquals(plays, { soundId, soundId, soundId })
    end
end
