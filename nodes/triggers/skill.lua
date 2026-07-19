-- skill.lua — the two skill/XP triggers (#31): **XP Drop** (`trigger.xp_drop`) and
-- **Stat Changed** (`trigger.stat_changed`). Both bind the client's `Event.SkillTransmit`
-- channel and share one `transform`, so the second node is ~free on the shared dispatch: the
-- runtime subscribes `SkillTransmit` exactly once and fans each shaped payload out to every
-- node of either type (see runtime.lua's `_dispatch`/`_fireBinding`).
--
-- Pipeline split (why the work lives where it does):
--   * transform (shared) — shapes the raw `SkillTransmit` event into `Watchdog.Payload.SkillTransmit`,
--     renaming `old/newGameplayLevel` to `old/newLevel`. One function object, referenced by both
--     bindings, so "shared transform" is literal.
--   * filter (per node) — ALL gating lives here: the skill match (`skillFilter == "any"` or it
--     equals the fired skill id) AND the node's own discriminant (XP Drop: `newXP > oldXP`;
--     Stat Changed: `newLevel ~= oldLevel`). A node whose discriminant fails is never Fired, so
--     `run` only ever shapes outputs for a genuine hit.
--   * run — surfaces the data outputs and fires `out`. It never re-checks the discriminant; the
--     filter already decided this is a real fire.
--
-- The skill Control (`Controls.Register("skill", …)`, registered at require-time below) is the
-- enum this node depends on: the 29 `SkillType` members keyed by their raw id (the value the
-- client delivers on `SkillTransmit.skill`) plus an **Any** default. Keeping the Control values
-- as ids means the `skillFilter` input and the `skill` output round-trip against the payload with
-- no `SkillType.FromID` name lookup; the enum widget supplies the human labels for display.
--
-- Registered from main.lua with one `require("nodes/triggers/skill").Register(registry, runtime)`
-- line: both node types, both `SkillTransmit` bindings, and the skill Control are declared here,
-- so no dispatcher or main.lua edits are needed beyond that require (the #24 self-contained-trigger
-- architecture). RunEnergy/RunWeight are deliberately out of this node set — skill-only.

local Controls = require("ui/controls")

local Skill = {}

-- The raw `SkillTransmit` payload, shaped by `transform`. `skill` is the SkillType id (0..28);
-- `oldLevel`/`newLevel` are the event's `old/newGameplayLevel` (the gameplay — buffed/drained —
-- level, matching what the discriminant and outputs report).
---@class Watchdog.Payload.SkillTransmit
---@field skill integer     # SkillType id (0..28) of the skill that changed
---@field oldXP integer     # XP before the change
---@field newXP integer     # XP after the change
---@field oldLevel integer  # gameplay level before the change (event's oldGameplayLevel)
---@field newLevel integer  # gameplay level after the change (event's newGameplayLevel)

-- The 29 SkillType members (game/player.lua), ordered by id so the dropdown reads Attack →
-- Necromancy. Declared as literal id/label pairs (not `SkillType.*` lookups) so this module
-- loads under the bare test interpreter with no client globals, same tack as controls.lua's
-- toastIcon spec.
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

-- Builds the enum `choices`: Any first (its `value == "any"` is the sentinel `filter` treats as
-- "match every skill"), then each SkillType id in order.
---@return { value: integer|string, label: string }[]
local function skillChoices()
    local choices = { { value = "any", label = "Any" } }
    for id = 0, 28 do
        choices[#choices + 1] = { value = id, label = SKILL_LABELS[id] }
    end
    return choices
end

-- The skill enum Control (#31): reuses the existing enum widget; both the `skillFilter` input and
-- the `skill` output pins carry `dataType = "skill"`, so this spec renders both. Registered at
-- require-time (like every other Controls.Register call) so merely requiring this file — as the
-- controls test and main.lua both do — makes the Control available.
Controls.Register("skill", {
    widget = "enum",
    choices = skillChoices(),
})

-- Shared transform: one function object, handed to both bindings below. Renames the event's
-- verbose `*GameplayLevel` fields to `old/newLevel`; everything else passes through.
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

-- The skill-match half of every filter: the node's `skillFilter` Control passes when it's the
-- Any sentinel (or unset) or equals the fired skill's id. The per-node discriminant is AND-ed on
-- top of this by each binding's own filter. Arg order mirrors `filter(payload, node)`.
---@param payload Watchdog.Payload.SkillTransmit
---@param node { GetControl: fun(pinName: string): any }
---@return boolean
local function skillMatches(payload, node)
    local sel = node.GetControl("skillFilter")
    return sel == nil or sel == "any" or sel == payload.skill
end

---@param registry LibNodeGraph.Registry
function Skill.Register(registry, runtime)
    registry:RegisterNodeType("trigger.xp_drop", {
        category = "trigger",
        displayName = "XP Drop",
        description = "A skill gains XP",
        pins = {
            -- Which skill to watch; Any (the default) fires for every skill.
            { name = "skillFilter", kind = "data", direction = "in", dataType = "skill", default = "any" },
            { name = "out", kind = "exec", direction = "out" },
            -- The skill that fired (typed as the skill enum, so it's meaningful when Any is set).
            { name = "skill", kind = "data", direction = "out", dataType = "skill" },
            -- The XP gained this event (Δxp), and the resulting XP total.
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
            -- Signed change in gameplay level (positive on level-up, negative on drain), plus the
            -- new and previous levels.
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

    -- Both bindings share the one `transform`; each adds its own discriminant on top of the shared
    -- skill match. `SkillTransmit` is subscribed once no matter how many nodes of either type exist.
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
