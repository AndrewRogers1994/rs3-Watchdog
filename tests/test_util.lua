-- Exercises util.lua's shared helpers. Today: NormalizePlayerName (#89), the folding a
-- character display name goes through before it becomes a Bucket key, so a cosmetic
-- case/whitespace difference in what the client returns can't silently orphan a bucket.

local luaunit = require("luaunit")
local Util = require("util")

TestUtil = {}

function TestUtil:testNormalizeLowercases()
    luaunit.assertEquals(Util.NormalizePlayerName("Zezima"), "zezima")
end

function TestUtil:testNormalizeFoldsWhitespaceRuns()
    -- Internal runs of whitespace collapse to a single plain space.
    luaunit.assertEquals(Util.NormalizePlayerName("Ze  Zima"), "ze zima")
end

function TestUtil:testNormalizeTrimsEnds()
    luaunit.assertEquals(Util.NormalizePlayerName("  Zezima  "), "zezima")
end

function TestUtil:testNormalizeFoldsLatin1NonBreakingSpace()
    -- A non-breaking space as the single Latin-1 byte 0xA0 must fold, so the "Ze<nbsp>Zima" the
    -- client returns keys the same bucket as "Ze Zima".
    luaunit.assertEquals(Util.NormalizePlayerName("Ze\160Zima"), "ze zima")
end

function TestUtil:testNormalizeFoldsUtf8NonBreakingSpace()
    -- The same non-breaking space encoded as the UTF-8 two-byte sequence 0xC2 0xA0 must fold whole
    -- - folding only 0xA0 would leave a stray 0xC2 and a *different* key (the orphan we prevent).
    luaunit.assertEquals(Util.NormalizePlayerName("Ze\194\160Zima"), "ze zima")
    luaunit.assertEquals(Util.NormalizePlayerName("Ze\194\160Zima"), Util.NormalizePlayerName("Ze Zima"))
end

function TestUtil:testCosmeticVariantsNormalizeEqual()
    luaunit.assertEquals(
        Util.NormalizePlayerName("Ze Zima"),
        Util.NormalizePlayerName("ze  ZIMA "))
end

function TestUtil:testNormalizeNonStringIsEmpty()
    luaunit.assertEquals(Util.NormalizePlayerName(nil), "")
    luaunit.assertEquals(Util.NormalizePlayerName(42), "")
end

return TestUtil
