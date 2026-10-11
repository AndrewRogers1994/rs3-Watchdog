-- Matcher.Test (#55): empty/nil needle matches all; substring is literal and case-insensitive.

local luaunit = require("luaunit")
local Matcher = require("src/matcher")

local function sub(needle) return { needle = needle, mode = "substring" } end
local function pat(needle) return { needle = needle, mode = "pattern" } end

TestMatcherSubstring = {}

function TestMatcherSubstring:testCaseInsensitive()
    luaunit.assertTrue(Matcher.Test(sub("zulrah"), "You defeated Zulrah"))
    luaunit.assertTrue(Matcher.Test(sub("ZULRAH"), "you defeated zulrah"))
end

function TestMatcherSubstring:testLiteralSpecialCharacters()
    -- "." and "%" are magic in a pattern but must be taken literally in substring mode.
    luaunit.assertTrue(Matcher.Test(sub("a.b"), "x a.b y"))
    luaunit.assertFalse(Matcher.Test(sub("a.b"), "x axb y")) -- "." did NOT act as any-char
    luaunit.assertTrue(Matcher.Test(sub("50%"), "loot is 50% off"))
end

function TestMatcherSubstring:testNonMatchIsFalse()
    luaunit.assertFalse(Matcher.Test(sub("zulrah"), "You defeated Vorago"))
end

TestMatcherPattern = {}

function TestMatcherPattern:testCaseSensitive()
    luaunit.assertTrue(Matcher.Test(pat("Zulrah"), "You defeated Zulrah"))
    luaunit.assertFalse(Matcher.Test(pat("Zulrah"), "you defeated zulrah"))
end

function TestMatcherPattern:testMagicCharactersActive()
    luaunit.assertTrue(Matcher.Test(pat("a.b"), "x aXb y"))    -- "." matches any char
    luaunit.assertTrue(Matcher.Test(pat("^You"), "You win"))   -- anchored
    luaunit.assertFalse(Matcher.Test(pat("^You"), "and You win"))
    luaunit.assertTrue(Matcher.Test(pat("%d+ gp"), "got 250 gp"))
end

TestMatcherEmptyNeedle = {}

function TestMatcherEmptyNeedle:testEmptyNeedleMatchesEverything()
    luaunit.assertTrue(Matcher.Test(sub(""), "anything at all"))
    luaunit.assertTrue(Matcher.Test(pat(""), "anything at all"))
    luaunit.assertTrue(Matcher.Test(sub(""), ""))
end

function TestMatcherEmptyNeedle:testNilNeedleMatchesEverything()
    luaunit.assertTrue(Matcher.Test({ mode = "substring" }, "anything at all"))
end

function TestMatcherEmptyNeedle:testNilValueMatchesEverything()
    luaunit.assertTrue(Matcher.Test(nil, "anything at all"))
end

function TestMatcherEmptyNeedle:testMissingModeDefaultsToSubstring()
    luaunit.assertTrue(Matcher.Test({ needle = "zulrah" }, "Zulrah here"))
    luaunit.assertTrue(Matcher.Test({ needle = "a.b" }, "a.b"))
    luaunit.assertFalse(Matcher.Test({ needle = "a.b" }, "axb"))
end

return TestMatcherEmptyNeedle
