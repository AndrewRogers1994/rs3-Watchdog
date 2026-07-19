-- Text.StripTags (#55): removes any `<…>` formatting tag from a client string so nodes
-- match and emit clean, what-you-see text. Cases are input/output tables asserting a single
-- tag, mid-string tags, multiple/adjacent tags, and the no-tag / empty-string pass-throughs.

local luaunit = require("luaunit")
local Text = require("text")

TestStripTags = {}

function TestStripTags:testStripsASingleLeadingTag()
    luaunit.assertEquals(Text.StripTags("<col=ff0000>hello"), "hello")
end

function TestStripTags:testStripsAMidStringTag()
    luaunit.assertEquals(Text.StripTags("hel<col=00ff00>lo"), "hello")
end

function TestStripTags:testStripsMultipleAndAdjacentTags()
    local cases = {
        { "<col=ff0000>hi</col> there", "hi there" },       -- open + close, separated
        { "<shad=0><col=ff0000>x</col></shad>", "x" },       -- adjacent tags, both ends
        { "a<br><br>b", "ab" },                              -- two adjacent tags mid-string
    }
    for _, c in ipairs(cases) do
        luaunit.assertEquals(Text.StripTags(c[1]), c[2])
    end
end

function TestStripTags:testReturnsPlainStringUnchanged()
    luaunit.assertEquals(Text.StripTags("no tags here"), "no tags here")
end

function TestStripTags:testReturnsEmptyStringUnchanged()
    luaunit.assertEquals(Text.StripTags(""), "")
end

function TestStripTags:testStripsWholeStringWhenItIsOneTag()
    luaunit.assertEquals(Text.StripTags("<col=ff0000>"), "")
end

return TestStripTags
