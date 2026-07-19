local luaunit = require("luaunit")
local Controls = require("ui/controls")

TestCommitAxis = {}

function TestCommitAxis:testSetsAxisOnFreshTable()
    local value, changed = Controls.CommitAxis(nil, "x", "50", nil)
    luaunit.assertTrue(changed)
    luaunit.assertEquals(value, { x = 50 })
end

function TestCommitAxis:testReadModifyWritePreservesSiblingAxes()
    local current = { x = 10, z = 20, level = 0 }
    local value, changed = Controls.CommitAxis(current, "z", "99", nil)
    luaunit.assertTrue(changed)
    luaunit.assertEquals(value, { x = 10, z = 99, level = 0 })
    -- The original table is untouched (a fresh copy was returned).
    luaunit.assertEquals(current, { x = 10, z = 20, level = 0 })
end

function TestCommitAxis:testEmptyRawGuardsAgainstClobber()
    local current = { x = 10, z = 20, level = 0 }
    local value, changed = Controls.CommitAxis(current, "z", "", nil)
    luaunit.assertFalse(changed)
    luaunit.assertEquals(value, current)
end

function TestCommitAxis:testWhitespaceOnlyRawGuardsAgainstClobber()
    local current = { x = 10, z = 20, level = 0 }
    local value, changed = Controls.CommitAxis(current, "x", "   ", nil)
    luaunit.assertFalse(changed)
    luaunit.assertEquals(value, current)
end

function TestCommitAxis:testUnparsableRawGuardsAgainstClobber()
    local current = { x = 10 }
    local value, changed = Controls.CommitAxis(current, "x", "not-a-number", nil)
    luaunit.assertFalse(changed)
    luaunit.assertEquals(value, current)
end

function TestCommitAxis:testQuantityPreferredOverRaw()
    -- Mirrors InputField.contentQuantity honoring suffixes like "1K" that tonumber(raw) can't.
    local value, changed = Controls.CommitAxis(nil, "level", "ignored", 1000)
    luaunit.assertTrue(changed)
    luaunit.assertEquals(value, { level = 1000 })
end

TestCoordgridSpec = {}

function TestCoordgridSpec:setUp()
    self.spec = Controls.For("coordgrid")
end

function TestCoordgridSpec:testRegisteredAsCompositeWidget()
    luaunit.assertNotNil(self.spec)
    luaunit.assertEquals(self.spec.widget, "composite")
end

function TestCoordgridSpec:testLayoutProducesThreeFieldsAndOneAction()
    local band = { x = 10, y = 100, w = 170, h = self.spec.extraH({}) }
    local rects = self.spec.Layout(band)
    luaunit.assertEquals(#rects, 4)

    local axes = {}
    local actionCount = 0
    for _, r in ipairs(rects) do
        if r.kind == "field" then
            axes[r.axis] = true
        elseif r.kind == "action" then
            actionCount = actionCount + 1
        end
    end
    luaunit.assertTrue(axes.x and axes.z and axes.level)
    luaunit.assertEquals(actionCount, 1)
end

function TestCoordgridSpec:testFieldsAndActionStayWithinTheBand()
    local band = { x = 10, y = 100, w = 170, h = self.spec.extraH({}) }
    local rects = self.spec.Layout(band)
    for _, r in ipairs(rects) do
        luaunit.assertTrue(r.x >= band.x - 1e-9)
        luaunit.assertTrue(r.x + r.w <= band.x + band.w + 1e-9)
        luaunit.assertTrue(r.y >= band.y - 1e-9)
        luaunit.assertTrue(r.y + r.h <= band.y + band.h + 1e-9)
    end
end

-- The skill enum control (#31): the 29 SkillType members plus an Any default, reusing the
-- existing enum widget. Registered by requiring the skill trigger node file (Register wires
-- it up), mirroring how each domain enum spec is declared alongside the node that needs it.
TestSkillControlSpec = {}

function TestSkillControlSpec:setUp()
    require("nodes/triggers/skill")
    self.spec = Controls.For("skill")
end

function TestSkillControlSpec:testRegisteredAsEnumWidget()
    luaunit.assertNotNil(self.spec)
    luaunit.assertEquals(self.spec.widget, "enum")
end

function TestSkillControlSpec:testOffersAllTwentyNineSkillsPlusAny()
    -- 29 SkillType members + one Any entry.
    luaunit.assertEquals(#self.spec.choices, 30)
    local any = self.spec.choices[1]
    luaunit.assertEquals(any.value, "any")
    luaunit.assertEquals(any.label, "Any")
end

function TestSkillControlSpec:testSkillChoicesAreIdKeyedAndFormatToLabels()
    -- Values are the raw SkillType ids the client delivers on SkillTransmit.skill, so the
    -- Control round-trips against the payload with no name lookup.
    luaunit.assertEquals(Controls.Format(self.spec, 0), "Attack")
    luaunit.assertEquals(Controls.Format(self.spec, 28), "Necromancy")
    luaunit.assertEquals(Controls.Format(self.spec, "any"), "Any")
end
