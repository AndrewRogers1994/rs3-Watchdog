-- Exercises the two skill/XP triggers (#31) end-to-end through the real event dispatcher:
-- representative `SkillTransmit` events are pushed through a fake event source and the tests
-- assert which node fires (via a downstream counter wired to its `out` pin) and its data
-- outputs. Both nodes bind `Event.SkillTransmit` and share one `transform`, so a single event
-- can satisfy both discriminants at once (an XP gain that also changes gameplay level) - the
-- combined-fire test proves the shared dispatch feeds both.
--
-- Skill ids are the raw `SkillType` member values the client delivers on `SkillTransmit.skill`
-- (0..28, see runescape-api-stubs game/player.lua). The node keeps them as ids - the enum
-- Control (Controls.Register("skill", …)) supplies the human labels - so no `SkillType` global
-- stub is needed here; the tests reference ids by a small local alias for readability.

local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local Runtime = require("src/runtime")
local newFakeEventSource = require("fake_event_source")
local Skill = require("src/nodes/triggers/skill")

-- A few SkillType ids by name, just so the assertions read as skills rather than magic numbers.
local ATTACK, WOODCUTTING, FISHING = 0, 8, 10

TestSkill = {}

function TestSkill:setUp()
    self.registry = Registry.new()
    self.source = newFakeEventSource()
    self.runtime = Runtime.new(self.source.source)
    self.graph = Graph.new(self.registry)
    self.runtime:SetGraph(self.graph)

    Skill.Register(self.registry, self.runtime)

    -- One counter per node type's `out` pin, so a test can prove which node's exec propagated.
    self.counts = { xp = 0, stat = 0 }
    local counts = self.counts
    self.registry:RegisterNodeType("fixture.xp", {
        category = "action",
        pins = { { name = "in", kind = "exec", direction = "in" } },
        run = function() counts.xp = counts.xp + 1 end,
    })
    self.registry:RegisterNodeType("fixture.stat", {
        category = "action",
        pins = { { name = "in", kind = "exec", direction = "in" } },
        run = function() counts.stat = counts.stat + 1 end,
    })
end

function TestSkill:addXpDrop(skillFilter)
    local id = self.graph:AddNode("trigger.xp_drop", { skillFilter = skillFilter })
    self.graph:Connect(id, "out", self.graph:AddNode("fixture.xp"), "in")
    return id
end

function TestSkill:addStatChanged(skillFilter)
    local id = self.graph:AddNode("trigger.stat_changed", { skillFilter = skillFilter })
    self.graph:Connect(id, "out", self.graph:AddNode("fixture.stat"), "in")
    return id
end

-- Pushes one raw SkillTransmit event through the fake source, exactly like the client firing it.
-- `skill` is the SkillType id; the four numeric fields mirror the documented payload.
function TestSkill:transmit(skill, oldXP, newXP, oldGameplayLevel, newGameplayLevel)
    self.source:Push("SkillTransmit", {
        skill = skill,
        oldXP = oldXP,
        newXP = newXP,
        oldGameplayLevel = oldGameplayLevel,
        newGameplayLevel = newGameplayLevel,
    })
end

--- Shared dispatch ------------------------------------------------------------------------

function TestSkill:testBothNodesSubscribeSkillTransmitExactlyOnce()
    self:addXpDrop(nil)
    self:addStatChanged(nil)
    luaunit.assertEquals(self.source:SubscribeCount("SkillTransmit"), 1)
end

function TestSkill:testOneEventFeedsBothNodesThroughSharedTransform()
    self:addXpDrop(nil)
    self:addStatChanged(nil)
    self:transmit(WOODCUTTING, 100, 250, 4, 5)
    luaunit.assertEquals(self.counts.xp, 1)
    luaunit.assertEquals(self.counts.stat, 1)
end

--- XP Drop --------------------------------------------------------------------------------

function TestSkill:testXpDropFiresOnXpGain()
    self:addXpDrop(nil)
    self:transmit(ATTACK, 1000, 1083, 10, 10) -- +83 xp, no level change
    luaunit.assertEquals(self.counts.xp, 1)
end

function TestSkill:testXpDropDataOutputs()
    local id = self:addXpDrop(nil)
    self:transmit(ATTACK, 1000, 1083, 10, 10)
    luaunit.assertEquals(self.graph:GetLastValue(id, "skill"), ATTACK)
    luaunit.assertEquals(self.graph:GetLastValue(id, "gained"), 83)   -- Δxp
    luaunit.assertEquals(self.graph:GetLastValue(id, "newXP"), 1083)
end

function TestSkill:testXpDropDoesNotFireWhenXpUnchanged()
    self:addXpDrop(nil)
    self:transmit(ATTACK, 1000, 1000, 10, 10) -- equal XP (e.g. a bare stat re-transmit)
    luaunit.assertEquals(self.counts.xp, 0)
end

function TestSkill:testXpDropDoesNotFireWhenXpDecreases()
    self:addXpDrop(nil)
    self:transmit(ATTACK, 1000, 900, 10, 10)
    luaunit.assertEquals(self.counts.xp, 0)
end

--- Stat Changed ---------------------------------------------------------------------------

function TestSkill:testStatChangedFiresOnLevelUp()
    self:addStatChanged(nil)
    self:transmit(FISHING, 500, 600, 5, 6)
    luaunit.assertEquals(self.counts.stat, 1)
end

function TestSkill:testStatChangedDataOutputsSignedDeltaOnLevelUp()
    local id = self:addStatChanged(nil)
    self:transmit(FISHING, 500, 600, 5, 6)
    luaunit.assertEquals(self.graph:GetLastValue(id, "skill"), FISHING)
    luaunit.assertEquals(self.graph:GetLastValue(id, "levelDelta"), 1) -- signed
    luaunit.assertEquals(self.graph:GetLastValue(id, "newLevel"), 6)
    luaunit.assertEquals(self.graph:GetLastValue(id, "oldLevel"), 5)
end

function TestSkill:testStatChangedDeltaIsSignedOnLevelLoss()
    local id = self:addStatChanged(nil)
    self:transmit(FISHING, 600, 500, 6, 4) -- lost two levels (e.g. a drain)
    luaunit.assertEquals(self.counts.stat, 1)
    luaunit.assertEquals(self.graph:GetLastValue(id, "levelDelta"), -2)
    luaunit.assertEquals(self.graph:GetLastValue(id, "newLevel"), 4)
    luaunit.assertEquals(self.graph:GetLastValue(id, "oldLevel"), 6)
end

function TestSkill:testStatChangedDoesNotFireWhenLevelUnchanged()
    self:addStatChanged(nil)
    self:transmit(FISHING, 500, 600, 5, 5) -- XP moved but gameplay level held
    luaunit.assertEquals(self.counts.stat, 0)
end

--- Skill filter ---------------------------------------------------------------------------

function TestSkill:testFilterPassesOnlyTheSelectedSkill()
    self:addXpDrop(WOODCUTTING)
    self:transmit(ATTACK, 100, 200, 1, 1)      -- wrong skill: filtered out
    luaunit.assertEquals(self.counts.xp, 0)
    self:transmit(WOODCUTTING, 100, 200, 1, 1) -- matching skill: fires
    luaunit.assertEquals(self.counts.xp, 1)
end

function TestSkill:testAnyPassesEverySkillAndReportsWhichFired()
    local id = self:addXpDrop("any")
    self:transmit(ATTACK, 100, 200, 1, 1)
    luaunit.assertEquals(self.graph:GetLastValue(id, "skill"), ATTACK)
    self:transmit(FISHING, 100, 200, 1, 1)
    luaunit.assertEquals(self.graph:GetLastValue(id, "skill"), FISHING)
    luaunit.assertEquals(self.counts.xp, 2)
end

function TestSkill:testFilterAlsoAppliesToStatChanged()
    self:addStatChanged(FISHING)
    self:transmit(ATTACK, 1, 2, 1, 2)   -- level change on the wrong skill
    luaunit.assertEquals(self.counts.stat, 0)
    self:transmit(FISHING, 1, 2, 1, 2)  -- level change on the selected skill
    luaunit.assertEquals(self.counts.stat, 1)
end

return TestSkill
