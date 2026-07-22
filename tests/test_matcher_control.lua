-- matcher Pin Control (ADR-0005 / #59) driven through the shared FAKE HOST. The matcher is a
-- composite BAND (needle text field + Substring/Pattern toggle) whose two sub-rects both bind to
-- the whole { needle, mode } table read-modify-write: editing the needle preserves the mode, and
-- toggling the mode preserves the needle. Both are driven here through the same press->commit seam
-- the in-client Editor uses; an empty needle is a valid value (matches anything), unlike a
-- coordgrid axis, so it commits verbatim.

local luaunit = require("luaunit")
local FakeHost = require("fake_control_host")
local Matcher = require("ui/controls/matcher")

local DEFAULT = { needle = "", mode = "substring" }

local function needleCtrl(value)
    return { kind = "needle", pinName = "contains", value = value, default = DEFAULT,
        x = 0, y = 0, w = 80, h = 16 }
end
local function toggleCtrl(value)
    return { kind = "toggle", pinName = "contains", value = value, default = DEFAULT,
        x = 0, y = 0, w = 64, h = 16 }
end

--- Editing the needle ---------------------------------------------------------------------

TestMatcherNeedle = {}

function TestMatcherNeedle:testEditingNeedlePreservesTheMode()
    local host = FakeHost.new({ needle = "", mode = "pattern" })
    Matcher.Press(host, needleCtrl({ needle = "", mode = "pattern" }))
    host:Type("%d+ gp", nil)
    luaunit.assertEquals(host.committed, { needle = "%d+ gp", mode = "pattern" })
end

function TestMatcherNeedle:testEmptyNeedleCommitsVerbatim()
    -- Unlike a coordgrid axis (empty = leave alone), an empty needle is a valid "match anything".
    local host = FakeHost.new({ needle = "zulrah", mode = "substring" })
    Matcher.Press(host, needleCtrl({ needle = "zulrah", mode = "substring" }))
    host:Type("", nil)
    luaunit.assertEquals(host.committed, { needle = "", mode = "substring" })
end

function TestMatcherNeedle:testEditingUnsetSeedsTheSubstringDefault()
    local host = FakeHost.new(nil)
    Matcher.Press(host, needleCtrl(nil))
    host:Type("boss", nil)
    luaunit.assertEquals(host.committed, { needle = "boss", mode = "substring" })
end

function TestMatcherNeedle:testFieldIsSeededFromTheCurrentNeedle()
    local host = FakeHost.new({ needle = "abc", mode = "substring" })
    Matcher.Press(host, needleCtrl({ needle = "abc", mode = "substring" }))
    luaunit.assertEquals(host.mounted.opts.initial, "abc")
    luaunit.assertEquals(host.mounted.opts.filter, "NONE")
end

--- Toggling the mode ----------------------------------------------------------------------

TestMatcherToggle = {}

function TestMatcherToggle:testToggleFlipsModePreservingNeedle()
    local host = FakeHost.new({ needle = "zulrah", mode = "substring" })
    Matcher.Press(host, toggleCtrl({ needle = "zulrah", mode = "substring" }))
    luaunit.assertEquals(host.committed, { needle = "zulrah", mode = "pattern" })
end

function TestMatcherToggle:testTogglePatternBackToSubstring()
    local host = FakeHost.new({ needle = "x", mode = "pattern" })
    Matcher.Press(host, toggleCtrl({ needle = "x", mode = "pattern" }))
    luaunit.assertEquals(host.committed.mode, "substring")
    luaunit.assertEquals(host.committed.needle, "x")  -- needle survives the flip
end

function TestMatcherToggle:testToggleFromDefaultOnlyMatcher()
    -- No stored value: the flip bases off the default (substring) shown in the geometry, landing on
    -- pattern rather than re-deriving nil.
    local host = FakeHost.new(nil)
    Matcher.Press(host, toggleCtrl(nil))
    luaunit.assertEquals(host.committed.mode, "pattern")
end

--- Display projection ---------------------------------------------------------------------

TestMatcherDisplay = {}

function TestMatcherDisplay:testNeedleShowsItsText()
    luaunit.assertEquals(
        Matcher.Display({ kind = "needle", value = { needle = "boss", mode = "substring" } }), "boss")
end

function TestMatcherDisplay:testEmptyNeedleShowsEmpty()
    luaunit.assertEquals(
        Matcher.Display({ kind = "needle", value = { needle = "", mode = "substring" } }), "")
end

function TestMatcherDisplay:testToggleShowsTheModeLabel()
    luaunit.assertEquals(
        Matcher.Display({ kind = "toggle", value = { needle = "x", mode = "pattern" } }), "Pattern")
    luaunit.assertEquals(Matcher.Display({ kind = "toggle", value = nil }), "Substring")
end

--- Geometry the Node delegates to ---------------------------------------------------------

TestMatcherLayout = {}

function TestMatcherLayout:testReservedHeightIsTheBandConstant()
    local Theme = require("ui/theme")
    luaunit.assertEquals(Matcher.ReservedHeight({}), Theme.MATCHER_BAND_H)
end

function TestMatcherLayout:testLayoutProducesANeedleAndAToggleWithinTheBand()
    local Theme = require("ui/theme")
    local band = { x = 10, y = 100, w = 170, h = Theme.MATCHER_BAND_H }
    local rects = Matcher.Layout(band)
    luaunit.assertEquals(#rects, 2)
    local byKind = {}
    for _, r in ipairs(rects) do
        byKind[r.kind] = r
        luaunit.assertTrue(r.x >= band.x - 1e-9)
        luaunit.assertTrue(r.x + r.w <= band.x + band.w + 1e-9)
    end
    luaunit.assertNotNil(byKind.needle)
    luaunit.assertNotNil(byKind.toggle)
    luaunit.assertEquals(byKind.needle.placeholder, "matches anything")
end

return {}
