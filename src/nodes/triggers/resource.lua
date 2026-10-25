local Controls = require("src/ui/controls")

local Resource = {}

local PRAYER_BASE = id.VarPlayer.PRAYER_POINTS_VAR
local PRAYER_POINTS = id.VarPlayer.PRAYER_POINTS
local SUMMONING_POINTS_BASE = id.VarPlayer.LORE_POINTS_VAR
local SUMMONING_POINTS = id.VarPlayer.LORE_POINTS
local ADRENALINE_VAR = id.VarPlayer.SA_ENERGY
local SENSES_BOOST = id.VarPlayer.ARCH_RELIC_HEIGHTENED_SENSES_BOOST
local ZAM_MELEE_SET = id.VarPlayer.COMBAT_SET_EGWD_ZAM_MELEE
local LIFEPOINTS = id.VarPlayer.LIFEPOINTS
local MAXLIFEPOINTS = id.VarPlayer.MAXLIFEPOINTS
local ADREN_BASE = 100


-- Re-read `.value`. The event's old/new fields are not the pool.
-- FromID is userdata in the client and a function in tests. The definition is the same split.
local function lookupVar(varId)
    if var == nil or var.VarPlayer == nil then
        return nil
    end
    local fromId = var.VarPlayer.FromID
    local kind = type(fromId)
    if kind ~= "function" and kind ~= "userdata" then
        return nil
    end
    local ok, def = pcall(fromId, varId)
    if not ok or (type(def) ~= "userdata" and type(def) ~= "table") then
        return nil
    end
    return def
end

local function readVar(varId)
    local def = lookupVar(varId)
    if def == nil or type(def.value) ~= "number" then
        return nil
    end
    return def.value
end

-- Client API objects and callables are userdata. Tests build tables and functions.
local function isApiValue(value)
    local kind = type(value)
    return kind == "userdata" or kind == "table"
end

local function isCallable(value)
    local kind = type(value)
    return kind == "function" or kind == "userdata"
end

-- Prayer is SkillType 5 and Summoning is 23, the same ids Stat Changed uses.
local function gameplayTimes10(skillName, fallback)
    if Player == nil or not isCallable(Player.GetLevelGameplay) then
        return nil
    end
    local skill = fallback
    if isApiValue(SkillType) and type(SkillType[skillName]) == "number" then
        skill = SkillType[skillName]
    end
    local ok, level = pcall(Player.GetLevelGameplay, skill)
    if not ok or type(level) ~= "number" then
        return nil
    end
    return level * 10
end

-- Production pools. Tests replace this; the trigger is the only caller.
-- Life max is MAXLIFEPOINTS, which already includes gear and bonfires.
-- Prayer's base var 3274 is masked 0x7FFF inside the PRAYER_POINTS varbit, so
-- this reads that varbit instead of masking the base. That var counts tenths:
-- 29688 is 2,968 points on the action bar, and the bar drops by 1 after ten
-- ticks. Adrenaline is the same kind of tenth on SA_ENERGY, already divided by
-- 10. Heightened Senses stores 100 for a 10% cap, and a full Vestments of
-- Havoc set stores 4 for another 20%. Summoning points are tenths too:
-- 28700 on LORE_POINTS is 2,870 on the cyan bar. Run energy is
-- Player.GetRunEnergy, already the percentage, with no divide. Life matches
-- the UI with no scale.
local function productionRead(resource)
    if resource == "life" then
        local current = readVar(LIFEPOINTS)
        local max = readVar(MAXLIFEPOINTS)
        if current == nil or max == nil then return nil end
        return current, max
    end
    if resource == "prayer" then
        local raw = readVar(PRAYER_POINTS)
        local max = gameplayTimes10("PRAYER", 5)
        if raw == nil or max == nil then return nil end
        return math.floor(raw / 10), max
    end
    if resource == "summoning" then
        local raw = readVar(SUMMONING_POINTS)
        local max = gameplayTimes10("SUMMONING", 23)
        if raw == nil or max == nil then return nil end
        return math.floor(raw / 10), max
    end
    if resource == "adrenaline" then
        local raw = readVar(ADRENALINE_VAR)
        if raw == nil then return nil end
        -- 100 on the relic var is +10. Four pieces of the Zamorak melee set is +20.
        -- A missing var is no bonus, not a failed read.
        local bonus = readVar(SENSES_BOOST) or 0
        local max = ADREN_BASE + bonus / 10
        if readVar(ZAM_MELEE_SET) == 4 then
            max = max + 20
        end
        return raw / 10, max
    end
    if resource == "run-energy" then
        if Player == nil or not isCallable(Player.GetRunEnergy) then
            return nil
        end
        local ok, current = pcall(Player.GetRunEnergy)
        if not ok or type(current) ~= "number" then
            return nil
        end
        return current, ADREN_BASE
    end
    return nil
end

-- Last successful current, on the runtime and weak-keyed by graph. A new graph has
-- no row, so its first successful read stays silent. The slot also stores which
-- resource was sampled. A different dropdown drops that slot on the next read,
-- before the new value is kept, so the new pool's first success stays silent.
-- Both event filters call `observe`; neither filter holds the sample.
local function samplesOf(runtime)
    if runtime._resourceSamples == nil then
        runtime._resourceSamples = setmetatable({}, { __mode = "k" })
    end
    return runtime._resourceSamples
end

local reader = productionRead

--- Tests install `(resource) -> current, max`. Nil current is a failed read.
--- Passing nil restores the production reader. The trigger is the only production caller.
---@param fn (fun(resource: string): number|nil, number|nil)|nil
function Resource.SetReader(fn)
    reader = fn or productionRead
end

local function callReader(resource)
    local ok, current, max = pcall(reader, resource)
    if not ok or type(current) ~= "number" or type(max) ~= "number" then
        return nil
    end
    return current, max
end

--- Returns current, max, previous when this read should fire. Nil when it should not.
---@param runtime Watchdog.Runtime
---@param graph LibNodeGraph.Graph
---@param nodeId integer
---@param resource string
---@return number|nil current
---@return number|nil max
---@return number|nil previous
local function observe(runtime, graph, nodeId, resource)
    if graph == nil then
        return nil
    end
    local samples = samplesOf(runtime)
    local byNode = samples[graph]
    local slot = byNode and byNode[nodeId]
    if slot ~= nil and slot.resource ~= resource then
        byNode[nodeId] = nil
        slot = nil
    end
    local current, max = callReader(resource)
    if current == nil then
        return nil
    end
    if slot == nil then
        if byNode == nil then
            byNode = {}
            samples[graph] = byNode
        end
        byNode[nodeId] = { resource = resource, current = current }
        return nil
    end
    -- same value, skip
    if current == slot.current then
        return nil
    end
    local previous = slot.current
    slot.current = current
    return current, max, previous
end

local function selected(node)
    local value = node.GetControl("resource")
    if value == nil or value == "" then
        return "life"
    end
    return value
end

local function varId(payload)
    local eventVar = payload.var
    if eventVar == nil or type(eventVar.id) ~= "number" then
        return nil
    end
    return eventVar.id
end

-- A new table. The event is shared with every later binding on this channel.
local function publish(current, max, previous)
    if current == nil then
        return false
    end
    return { current = current, max = max, previous = previous }
end

---@param resource string
---@param payload VarTransmit
local function varApplies(resource, payload)
    local id = varId(payload)
    -- LIFEPOINTS and MAXLIFEPOINTS each arrive as their own transmit. There is no parent.
    if resource == "life" then
        return id == LIFEPOINTS or id == MAXLIFEPOINTS
    end
    if resource == "prayer" then
        return varId(payload) == PRAYER_BASE
    end
    if resource == "adrenaline" then
        return id == ADRENALINE_VAR or id == SENSES_BOOST or id == ZAM_MELEE_SET
    end
    if resource == "summoning" then
        return id == SUMMONING_POINTS_BASE
    end
    return false
end

Controls.Register("resource", {
    widget = "enum",
    choices = {
        { value = "life", label = "Life points" },
        { value = "prayer", label = "Prayer points" },
        { value = "summoning", label = "Summoning points" },
        { value = "adrenaline", label = "Adrenaline" },
        { value = "run-energy", label = "Run energy" },
    },
})

---@param registry LibNodeGraph.Registry
---@param runtime Watchdog.Runtime
function Resource.Register(registry, runtime)
    registry:RegisterNodeType("trigger.resource_changed", {
        category = "trigger",
        displayName = "Resource Changed",
        description = "A life, prayer, summoning, adrenaline, or run energy pool changes",
        pins = {
            { name = "resource", kind = "data", direction = "in", dataType = "resource", default = "life" },
            { name = "out", kind = "exec", direction = "out" },
            { name = "current", kind = "data", direction = "out", dataType = "number" },
            { name = "max", kind = "data", direction = "out", dataType = "number" },
            { name = "previous", kind = "data", direction = "out", dataType = "number" },
        },
        run = function(ctx)
            local p = ctx.payload
            ctx:Out("current", p.current)
            ctx:Out("max", p.max)
            ctx:Out("previous", p.previous)
            ctx:Fire("out")
        end,
    })

    runtime:BindTrigger("trigger.resource_changed", {
        {
            event = "VarTransmit",
            filter = function(payload, node, graph)
                local resource = selected(node)
                if resource == "run-energy" or not varApplies(resource, payload) then
                    return false
                end
                local current, max, previous = observe(runtime, graph, node.id, resource)
                return publish(current, max, previous)
            end,
        },
        {
            event = "RunEnergyTransmit",
            filter = function(payload, node, graph)
                if selected(node) ~= "run-energy" then
                    return false
                end
                local current, max, previous = observe(runtime, graph, node.id, "run-energy")
                return publish(current, max, previous)
            end,
        },
    })
end

return Resource
