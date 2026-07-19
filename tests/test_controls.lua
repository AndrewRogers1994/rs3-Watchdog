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

-- The matcher Control Band spec (#56): a composite band whose Layout yields a "needle" text
-- field and a "toggle" mode button on one row. Exercising extraH + Layout here evaluates the
-- Theme.MATCHER_* constants, so a missing one surfaces as a red test, not an in-client crash.
TestMatcherControlSpec = {}

function TestMatcherControlSpec:setUp()
    self.spec = Controls.For("matcher")
end

function TestMatcherControlSpec:testRegisteredAsCompositeWidget()
    luaunit.assertNotNil(self.spec)
    luaunit.assertEquals(self.spec.widget, "composite")
end

function TestMatcherControlSpec:testLayoutProducesOneNeedleAndOneToggle()
    local band = { x = 10, y = 100, w = 170, h = self.spec.extraH({}) }
    local rects = self.spec.Layout(band)
    luaunit.assertEquals(#rects, 2)
    local kinds = {}
    for _, r in ipairs(rects) do kinds[r.kind] = r end
    luaunit.assertNotNil(kinds.needle)
    luaunit.assertNotNil(kinds.toggle)
    -- The toggle sits after the needle field on the same row.
    luaunit.assertTrue(kinds.toggle.x > kinds.needle.x)
    luaunit.assertEquals(kinds.needle.y, kinds.toggle.y)
end

function TestMatcherControlSpec:testNeedleCarriesTheGenericPlaceholder()
    local band = { x = 10, y = 100, w = 170, h = self.spec.extraH({}) }
    for _, r in ipairs(self.spec.Layout(band)) do
        if r.kind == "needle" then
            luaunit.assertEquals(r.placeholder, "matches anything")
        end
    end
end

function TestMatcherControlSpec:testSubRectsStayWithinTheBand()
    local band = { x = 10, y = 100, w = 170, h = self.spec.extraH({}) }
    for _, r in ipairs(self.spec.Layout(band)) do
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

-- object_marker mode multi-select spec (#40): a composite band of one checkbox row per mode.
-- Exercising extraH + Layout here evaluates the Theme.MODE_* band constants, so a missing one
-- (e.g. an edit that landed in the wrong checkout) surfaces as a red test, not an in-client crash.
local ObjectMarker = require("nodes/actions/object_marker")

TestObjectMarkerModeSpec = {}

function TestObjectMarkerModeSpec:setUp()
    ObjectMarker.Register({ RegisterNodeType = function() end }, { effects = {} })
    self.spec = Controls.For("object_marker.mode")
end

function TestObjectMarkerModeSpec:testRegisteredAsCompositeWithFourModes()
    luaunit.assertNotNil(self.spec)
    luaunit.assertEquals(self.spec.widget, "composite")
    luaunit.assertEquals(#self.spec.modes, 4)
    luaunit.assertTrue(self.spec.modes[1].enabled)          -- Tile
    luaunit.assertFalse(self.spec.modes[2].enabled)         -- Hull (needs render API)
end

function TestObjectMarkerModeSpec:testLayoutProducesOneModeRowPerMode()
    local band = { x = 10, y = 100, w = 170, h = self.spec.extraH({}) }
    local rects = self.spec.Layout(band)
    luaunit.assertEquals(#rects, 4)
    local axes = {}
    for _, r in ipairs(rects) do
        luaunit.assertEquals(r.kind, "mode")
        axes[r.axis] = true
        -- Each row stays within the reserved band.
        luaunit.assertTrue(r.y >= band.y - 1e-9)
        luaunit.assertTrue(r.y + r.h <= band.y + band.h + 1e-9)
    end
    luaunit.assertTrue(axes.tile and axes.hull and axes.outline and axes.clickbox)
end
