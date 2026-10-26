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


-- Transmit old/new are not the pool. FromID is userdata in the client and a function in tests.
local function readVar(varId)
    if var == nil or var.VarPlayer == nil or var.VarPlayer.FromID == nil then
        return nil
    end
    local def = var.VarPlayer.FromID(varId)
    if type(def) ~= "userdata" and type(def) ~= "table" then
        return nil
    end
    if type(def.value) ~= "number" then
        return nil
    end
    return def.value
end

-- Prayer is SkillType 5 and Summoning is 23, the same ids Skill Changed uses.
local function gameplayTimes10(skillName, fallback)
    if Player == nil or Player.GetLevelGameplay == nil then
        return nil
    end
    local skill = fallback
    local skills = SkillType
    local kind = type(skills)
    if (kind == "table" or kind == "userdata") and type(skills[skillName]) == "number" then
        skill = skills[skillName]
    end
    local level = Player.GetLevelGameplay(skill)
    if type(level) ~= "number" then
        return nil
    end
    return level * 10
end

-- Life is the raw pool. Prayer, summoning, and adrenaline vars are tenths.
-- Adrenaline max is 100, plus 10 when Heightened Senses is 100, plus 20 for four Vestments of Havoc pieces.
-- A missing bonus var adds nothing. Run energy is already a percentage.
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
        local bonus = readVar(SENSES_BOOST) or 0
        local max = ADREN_BASE + bonus / 10
        if readVar(ZAM_MELEE_SET) == 4 then
            max = max + 20
        end
        return raw / 10, max
    end
    if resource == "run-energy" then
        if Player == nil or Player.GetRunEnergy == nil then
            return nil
        end
        local current = Player.GetRunEnergy()
        if type(current) ~= "number" then
            return nil
        end
        return current, ADREN_BASE
    end
    return nil
end

-- Weak-keyed by graph. The first successful read stays silent. A new dropdown value drops that sample.
local function samplesOf(runtime)
    if runtime._resourceSamples == nil then
        runtime._resourceSamples = setmetatable({}, { __mode = "k" })
    end
    return runtime._resourceSamples
end

local reader = productionRead

--- Tests install `(resource) -> current, max`. Nil current is a failed read. Nil restores production.
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

-- Later bindings on this event still see the original payload.
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
    -- Life has no parent var. Either transmit is the pool.
    if resource == "life" then
        return id == LIFEPOINTS or id == MAXLIFEPOINTS
    end
    if resource == "prayer" then
        return id == PRAYER_BASE
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
