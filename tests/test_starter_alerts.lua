-- Starter Alert Presets on the Pack Watchdog registers at startup.
-- Loaded the way the timing tests load main.lua. No PrettyUI, and no New alert widget tree.
-- A copy is checked through PresetCopy, the same seam as the Pack alert tests.

local luaunit = require("luaunit")
local newFakeEventSource = require("fake_event_source")

local Packs = require("src/packs")
local PackRows = require("src/pack_rows")
local PresetCopy = require("src/preset_copy")
local Store = require("src/store")
local Theme = require("src/ui/theme")
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
        Sound = { TOWN_CRIER_BELL_RING_1 = 2608 },
    }
    config = { Inv = { INV = { id = 93 }, BANK = { id = 95 } } }
    Mouse, LibPluginMenu, shortestpath = nil, nil, nil
    Player = { IsAvailable = function() return false end }
    log, print = function() end, function() end
    ui = { Interfaces = { GetComponent = function() return nil end } }
    Vector4 = { new = function(r, g, b, a) return { r, g, b, a } end }

    -- Missing global Bucket, so startup still creates the disabled Tick Counter example.
    -- The Preset library string is a sentinel. Registration must not rewrite it.
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

-- Node bodies are Theme.NODE_WIDTH wide. A smaller gap on both axes stacks them.
local function assertSeparatedIntegers(layoutArray)
    luaunit.assertTrue(#layoutArray >= 2)
    for i, pos in ipairs(layoutArray) do
        luaunit.assertEquals(type(pos.x), "number")
        luaunit.assertEquals(type(pos.y), "number")
        luaunit.assertEquals(pos.x, math.floor(pos.x))
        luaunit.assertEquals(pos.y, math.floor(pos.y))
        for j = i + 1, #layoutArray do
            local other = layoutArray[j]
            local apart = math.abs(pos.x - other.x) >= Theme.NODE_WIDTH
                or math.abs(pos.y - other.y) >= Theme.NODE_WIDTH
            luaunit.assertTrue(apart)
        end
    end
end

local function loginGroup(key)
    for _, group in ipairs(ChatTypes.GAME_MESSAGE) do
        if group.key == key then return group end
    end
    return nil
end

-- Startup registers Pack Watchdog. Friend login copies as an ordinary Alert:
-- Login/Logout (chat type id 5), an empty substring Matcher, the chat line on
-- the Toast, and builtin sound 885. The copy drops the author id. Nothing is
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

    luaunit.assertEquals(#Watchdog.document.entries, 1)
    luaunit.assertEquals(Watchdog.document.entries[1].name, "Tick Counter (Example alert)")
    luaunit.assertEquals(Watchdog.document.entries[1].enabled, false)
    luaunit.assertEquals(PersistentDB.data.presets, self.presetsSentinel)

    local bucket = Store.Empty()
    local entry, live, layout, err = PresetCopy.InstantiateSnapshot(bucket, friend, self.registry)
    luaunit.assertNil(err)
    luaunit.assertNotNil(entry)
    luaunit.assertEquals(entry.name, "Friend login")
    luaunit.assertEquals(entry.kind, "alert")
    luaunit.assertEquals(entry.enabled, true)
    luaunit.assertEquals(entryKeys(entry), { "enabled", "graph", "id", "kind", "layout", "name" })
    luaunit.assertEquals(#Watchdog.document.entries, 1)
    luaunit.assertEquals(Watchdog.document.entries[1].name, "Tick Counter (Example alert)")
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
    luaunit.assertEquals(live:GetControl(sound, "soundId"), 885)
    local expectedWires = {
        string.format("%d.message->%d.text", message, toast),
        string.format("%d.out->%d.in", message, sound),
        string.format("%d.out->%d.show", message, toast),
    }
    table.sort(expectedWires)
    luaunit.assertEquals(sortedWires(live), expectedWires)

    luaunit.assertEquals(#entry.layout, 3)
    assertSeparatedIntegers(entry.layout)
    local seen = {}
    for _, pos in ipairs(entry.layout) do
        luaunit.assertNil(seen[pos.id])
        seen[pos.id] = true
        luaunit.assertEquals(layout[pos.id].x, pos.x)
        luaunit.assertEquals(layout[pos.id].y, pos.y)
    end
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

-- Idle XP copies as an ordinary Alert. Client Tick interval 5 steps a Counter.
-- At least 50 plays sound 885 and resets that Counter. XP Drop on any skill
-- resets it and does not reach the sound, because reset terminates. No toast,
-- no screen flash, and no Variable. The count of 50 is the Compare input.
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
    luaunit.assertEquals(authorIds, { "friend-login", "idle-xp", "low-life-points", "low-prayer" })

    local idle = self.packs:GetAlertPreset("Watchdog", "idle-xp")
    luaunit.assertNotNil(idle)
    luaunit.assertEquals(idle.name, "Idle XP")
    luaunit.assertEquals(idle.authorId, "idle-xp")
    luaunit.assertEquals(idle.variables, {})

    local bucket = Store.Empty()
    local entry, live, layout, err = PresetCopy.InstantiateSnapshot(bucket, idle, self.registry)
    luaunit.assertNil(err)
    luaunit.assertNotNil(entry)
    luaunit.assertEquals(entry.name, "Idle XP")
    luaunit.assertEquals(entry.kind, "alert")
    luaunit.assertEquals(entry.enabled, true)
    luaunit.assertEquals(entryKeys(entry), { "enabled", "graph", "id", "kind", "layout", "name" })
    luaunit.assertEquals(#Watchdog.document.entries, 1)
    luaunit.assertEquals(Watchdog.document.entries[1].name, "Tick Counter (Example alert)")
    luaunit.assertEquals(Watchdog.document.entries[1].enabled, false)
    luaunit.assertEquals(PersistentDB.data.presets, self.presetsSentinel)

    luaunit.assertEquals(sortedTypeKeys(live), {
        "action.sound",
        "std.branch",
        "std.compare",
        "std.counter",
        "trigger.logic",
        "trigger.xp_drop",
    })
    local logic = onlyNode(live, "trigger.logic")
    local counter = onlyNode(live, "std.counter")
    local compare = onlyNode(live, "std.compare")
    local branch = onlyNode(live, "std.branch")
    local sound = onlyNode(live, "action.sound")
    local xp = onlyNode(live, "trigger.xp_drop")

    luaunit.assertEquals(live:GetControl(logic, "interval"), 5)
    luaunit.assertEquals(live:GetControl(counter, "step"), 1)
    luaunit.assertEquals(live:GetControl(counter, "start"), 0)
    luaunit.assertEquals(live:GetControl(compare, "operation"), ">=")
    luaunit.assertEquals(live:GetControl(compare, "b"), 50)
    luaunit.assertEquals(live:GetControl(sound, "soundId"), 885)
    luaunit.assertEquals(live:GetControl(xp, "skillFilter"), "any")
    luaunit.assertTrue(pinTerminates(live, counter, "reset"))

    local expectedWires = {
        string.format("%d.out->%d.in", logic, counter),
        string.format("%d.count->%d.a", counter, compare),
        string.format("%d.out->%d.in", counter, branch),
        string.format("%d.result->%d.condition", compare, branch),
        string.format("%d.true->%d.in", branch, sound),
        string.format("%d.true->%d.reset", branch, counter),
        string.format("%d.out->%d.reset", xp, counter),
    }
    table.sort(expectedWires)
    luaunit.assertEquals(sortedWires(live), expectedWires)

    luaunit.assertEquals(#entry.layout, 6)
    assertSeparatedIntegers(entry.layout)
    local seen = {}
    for _, pos in ipairs(entry.layout) do
        luaunit.assertNil(seen[pos.id])
        seen[pos.id] = true
        luaunit.assertEquals(layout[pos.id].x, pos.x)
        luaunit.assertEquals(layout[pos.id].y, pos.y)
    end
    for _, id in ipairs({ logic, counter, compare, branch, sound, xp }) do
        luaunit.assertEquals(seen[id], true)
    end
end

local LOW_RESOURCES = {
    -- Life wakes on LIFEPOINTS. Prayer wakes on base var 3274.
    { authorId = "low-life-points", name = "Low life points", resource = "life", wake = -1669, other = 3274 },
    { authorId = "low-prayer", name = "Low prayer", resource = "prayer", wake = 3274, other = -1669 },
}

local function nodeIdsOfType(graph, typeKey)
    local ids = {}
    for _, node in ipairs(graph:GetNodes()) do
        if node.typeKey == typeKey then
            ids[#ids + 1] = node.id
        end
    end
    table.sort(ids)
    return ids
end

local function serializedNode(graph, id)
    for _, node in ipairs(graph.nodes) do
        if node.id == id then return node end
    end
    return nil
end

-- Low life points and Low prayer copy as ordinary Alerts. Resource Changed is
-- life or prayer. current * 100 is compared, strictly less-than, with max *
-- the threshold. That threshold pin defaults to 25 and is the only Variable.
-- True goes through Do Once (startClosed false) to sound 885 and Screen Flash.
-- False resets Do Once and stops there. Flash color and shapes stay the node
-- defaults, and dismissOn is both.
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
        luaunit.assertEquals(marked.controls.operation, "*")
        luaunit.assertEquals(marked.controls.b, 25)

        local bucket = Store.Empty()
        local entry, live, layout, err = PresetCopy.InstantiateSnapshot(
            bucket, preset, self.registry, { 25 })
        luaunit.assertNil(err)
        luaunit.assertNotNil(entry)
        luaunit.assertEquals(entry.name, spec.name)
        luaunit.assertEquals(entry.kind, "alert")
        luaunit.assertEquals(entry.enabled, true)
        luaunit.assertEquals(entryKeys(entry), { "enabled", "graph", "id", "kind", "layout", "name" })
        luaunit.assertEquals(#Watchdog.document.entries, 1)
        luaunit.assertEquals(Watchdog.document.entries[1].name, "Tick Counter (Example alert)")
        luaunit.assertEquals(PersistentDB.data.presets, self.presetsSentinel)

        luaunit.assertEquals(sortedTypeKeys(live), {
            "action.screen_flash",
            "action.sound",
            "std.branch",
            "std.compare",
            "std.doonce",
            "std.math",
            "std.math",
            "trigger.resource_changed",
        })
        local resource = onlyNode(live, "trigger.resource_changed")
        local compare = onlyNode(live, "std.compare")
        local branch = onlyNode(live, "std.branch")
        local once = onlyNode(live, "std.doonce")
        local sound = onlyNode(live, "action.sound")
        local flash = onlyNode(live, "action.screen_flash")
        local mathIds = nodeIdsOfType(live, "std.math")
        luaunit.assertEquals(#mathIds, 2)
        local times100 = mathIds[1] == mark.nodeId and mathIds[2] or mathIds[1]
        luaunit.assertNotEquals(times100, mark.nodeId)

        luaunit.assertEquals(live:GetControl(resource, "resource"), spec.resource)
        luaunit.assertEquals(live:GetControl(mark.nodeId, "operation"), "*")
        luaunit.assertEquals(live:GetControl(mark.nodeId, "b"), 25)
        luaunit.assertEquals(live:GetControl(times100, "operation"), "*")
        luaunit.assertEquals(live:GetControl(times100, "b"), 100)
        luaunit.assertEquals(live:GetControl(compare, "operation"), "<")
        luaunit.assertEquals(live:GetControl(once, "startClosed"), false)
        luaunit.assertEquals(live:GetControl(sound, "soundId"), 885)
        local flashPins = self.registry:GetNodeType("action.screen_flash").pins
        luaunit.assertEquals(flashPins.dismissOn.default, "both")
        luaunit.assertEquals(live:GetControl(flash, "dismissOn"), "both")
        luaunit.assertEquals(live:GetControl(flash, "color"), flashPins.color.default)
        luaunit.assertEquals(live:GetControl(flash, "inShape"), flashPins.inShape.default)
        luaunit.assertEquals(live:GetControl(flash, "outShape"), flashPins.outShape.default)
        luaunit.assertTrue(pinTerminates(live, once, "reset"))

        local expectedWires = {
            string.format("%d.current->%d.a", resource, times100),
            string.format("%d.max->%d.a", resource, mark.nodeId),
            string.format("%d.result->%d.a", times100, compare),
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

        luaunit.assertEquals(#entry.layout, 8)
        assertSeparatedIntegers(entry.layout)
        local seen = {}
        for _, pos in ipairs(entry.layout) do
            luaunit.assertNil(seen[pos.id])
            seen[pos.id] = true
            luaunit.assertEquals(layout[pos.id].x, pos.x)
            luaunit.assertEquals(layout[pos.id].y, pos.y)
        end
        for _, id in ipairs({ resource, times100, mark.nodeId, compare, branch, once, sound, flash }) do
            luaunit.assertEquals(seen[id], true)
        end
    end
end

-- Worked pool: max 1000 and threshold 25 meet at current 250.
-- 249 is below that line. 250 is equal, so it recovers and stays quiet.
-- 1000 is above it. A max of 0 with current 0 is not below the line.
-- The first successful sample is silent even when 249 is already below.
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
        local _, live = PresetCopy.InstantiateSnapshot(bucket, preset, self.registry, { 25 })
        runtime:SetGraph(live)
        local flash = onlyNode(live, "action.screen_flash")

        transmitVar(self.events, spec.wake)
        luaunit.assertEquals(plays, {})
        luaunit.assertNil(live:GetState(flash).handle)

        pool.current = 100
        transmitVar(self.events, spec.other)
        luaunit.assertEquals(plays, {})

        transmitVar(self.events, spec.wake)
        luaunit.assertEquals(plays, { 885 })
        local shown = live:GetState(flash).handle
        luaunit.assertNotNil(shown)
        luaunit.assertEquals(shown.kind, "screen_flash")

        pool.current = 50
        transmitVar(self.events, spec.wake)
        luaunit.assertEquals(plays, { 885 })
        luaunit.assertEquals(live:GetState(flash).handle, shown)

        pool.current = 250
        transmitVar(self.events, spec.wake)
        luaunit.assertEquals(plays, { 885 })
        luaunit.assertEquals(live:GetState(flash).handle, shown)

        pool.current = 200
        transmitVar(self.events, spec.wake)
        luaunit.assertEquals(plays, { 885, 885 })
        luaunit.assertNotEquals(live:GetState(flash).handle, shown)

        pool.current = 1000
        transmitVar(self.events, spec.wake)
        luaunit.assertEquals(plays, { 885, 885 })

        pool.current = 0
        pool.max = 0
        transmitVar(self.events, spec.wake)
        luaunit.assertEquals(plays, { 885, 885 })
    end
end
