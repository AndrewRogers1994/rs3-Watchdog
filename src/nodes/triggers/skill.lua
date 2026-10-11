local Controls = require("src/ui/controls")

local Skill = {}

---@class Watchdog.Payload.SkillTransmit
---@field skill integer     # SkillType id (0..28) of the skill that changed
---@field oldXP integer     # XP before the change
---@field newXP integer     # XP after the change
---@field oldLevel integer  # gameplay level before the change (event's oldGameplayLevel)
---@field newLevel integer  # gameplay level after the change (event's newGameplayLevel)

-- Literal ids so this module loads without client SkillType globals.
local SKILL_LABELS = {
    [0]  = "Attack",       [1]  = "Defence",      [2]  = "Strength",
    [3]  = "Hitpoints",    [4]  = "Ranged",       [5]  = "Prayer",
    [6]  = "Magic",        [7]  = "Cooking",      [8]  = "Woodcutting",
    [9]  = "Fletching",    [10] = "Fishing",      [11] = "Firemaking",
    [12] = "Crafting",     [13] = "Smithing",     [14] = "Mining",
    [15] = "Herblore",     [16] = "Agility",      [17] = "Thieving",
    [18] = "Slayer",       [19] = "Farming",      [20] = "Runecrafting",
    [21] = "Hunter",       [22] = "Construction", [23] = "Summoning",
    [24] = "Dungeoneering", [25] = "Divination",  [26] = "Invention",
    [27] = "Archaeology",  [28] = "Necromancy",
}

---@return { value: integer|string, label: string }[]
local function skillChoices()
    local choices = { { value = "any", label = "Any" } }
    for id = 0, 28 do
        choices[#choices + 1] = { value = id, label = SKILL_LABELS[id] }
    end
    return choices
end

Controls.Register("skill", {
    widget = "enum",
    choices = skillChoices(),
})

---@param raw table  # the raw client `SkillTransmit` event
---@return Watchdog.Payload.SkillTransmit
local function transform(raw)
    return {
        skill = raw.skill,
        oldXP = raw.oldXP,
        newXP = raw.newXP,
        oldLevel = raw.oldGameplayLevel,
        newLevel = raw.newGameplayLevel,
    }
end

---@param payload Watchdog.Payload.SkillTransmit
---@param node { GetControl: fun(pinName: string): any }
---@return boolean
local function skillMatches(payload, node)
    local sel = node.GetControl("skillFilter")
    return sel == nil or sel == "any" or sel == payload.skill
end

---@param registry LibNodeGraph.Registry
---@param runtime Watchdog.Runtime
function Skill.Register(registry, runtime)
    registry:RegisterNodeType("trigger.xp_drop", {
        category = "trigger",
        displayName = "XP Drop",
        description = "A skill gains XP",
        pins = {
            { name = "skillFilter", kind = "data", direction = "in", dataType = "skill", default = "any" },
            { name = "out", kind = "exec", direction = "out" },
            { name = "skill", kind = "data", direction = "out", dataType = "skill" },
            { name = "gained", kind = "data", direction = "out", dataType = "number" },
            { name = "newXP", kind = "data", direction = "out", dataType = "number" },
        },
        run = function(ctx)
            local p = ctx.payload
            ctx:Out("skill", p.skill)
            ctx:Out("gained", p.newXP - p.oldXP)
            ctx:Out("newXP", p.newXP)
            ctx:Fire("out")
        end,
    })

    registry:RegisterNodeType("trigger.stat_changed", {
        category = "trigger",
        displayName = "Stat Changed",
        description = "A skill's level/boost changes",
        pins = {
            { name = "skillFilter", kind = "data", direction = "in", dataType = "skill", default = "any" },
            { name = "out", kind = "exec", direction = "out" },
            { name = "skill", kind = "data", direction = "out", dataType = "skill" },
            { name = "levelDelta", kind = "data", direction = "out", dataType = "number" },
            { name = "newLevel", kind = "data", direction = "out", dataType = "number" },
            { name = "oldLevel", kind = "data", direction = "out", dataType = "number" },
        },
        run = function(ctx)
            local p = ctx.payload
            ctx:Out("skill", p.skill)
            ctx:Out("levelDelta", p.newLevel - p.oldLevel)
            ctx:Out("newLevel", p.newLevel)
            ctx:Out("oldLevel", p.oldLevel)
            ctx:Fire("out")
        end,
    })

    runtime:BindTrigger("trigger.xp_drop", {
        {
            event = "SkillTransmit",
            transform = transform,
            filter = function(payload, node)
                return skillMatches(payload, node) and payload.newXP > payload.oldXP
            end,
        },
    })

    runtime:BindTrigger("trigger.stat_changed", {
        {
            event = "SkillTransmit",
            transform = transform,
            filter = function(payload, node)
                return skillMatches(payload, node) and payload.newLevel ~= payload.oldLevel
            end,
        },
    })
end

return Skill
