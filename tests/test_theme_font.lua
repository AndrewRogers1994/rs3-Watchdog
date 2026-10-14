-- Theme.Font / FontObject / TextWidth weight selection. The shared suite may already
-- have required theme.lua (and filled its regular cache), so each case loads a fresh
-- copy against its own id.Font / config.Font and restores the previous module.

local luaunit = require("luaunit")

local THEME = "src/ui/theme"

local function withFonts(idFont, configFont, fn)
    local prevLoaded = package.loaded[THEME]
    local prevId = _G.id
    local prevConfig = _G.config
    package.loaded[THEME] = nil
    _G.id = { Font = idFont }
    _G.config = { Font = configFont }
    local ok, err = pcall(function()
        fn(require(THEME))
    end)
    package.loaded[THEME] = prevLoaded
    _G.id = prevId
    _G.config = prevConfig
    if not ok then error(err, 2) end
end

TestThemeFont = {}

function TestThemeFont:testBoldAndRegularAreDifferentFaces()
    withFonts({
        MUSEO_SANS_15PT_REGULAR = 30,
        MUSEO_SANS_15PT_BOLD = 31,
    }, nil, function(Theme)
        luaunit.assertEquals(Theme.Font(15), 30)
        luaunit.assertEquals(Theme.Font(15, true), 31)
        luaunit.assertEquals(Theme.Font(15, false), 30)
    end)
end

function TestThemeFont:testMissingBoldSnapsToNearestBoldNotRegular()
    -- 11pt is regular-only in the client enum; 13pt is the nearest bold bucket.
    withFonts({
        MUSEO_SANS_11PT_REGULAR = 26,
        MUSEO_SANS_13PT_BOLD = 29,
        MUSEO_SANS_15PT_BOLD = 31,
    }, nil, function(Theme)
        luaunit.assertEquals(Theme.Font(11), 26)
        luaunit.assertEquals(Theme.Font(11, true), 29)
        luaunit.assertEquals(Theme.Font(12, true), 29)
    end)
end

function TestThemeFont:testBoldSkipsInvalidSentinel()
    withFonts({
        MUSEO_SANS_15PT_BOLD = 0,
        MUSEO_SANS_13PT_BOLD = 29,
    }, nil, function(Theme)
        luaunit.assertEquals(Theme.Font(15, true), 29)
    end)
end

function TestThemeFont:testBoldMissReturnsNil()
    withFonts({
        MUSEO_SANS_15PT_REGULAR = 30,
    }, nil, function(Theme)
        luaunit.assertNil(Theme.Font(15, true))
        luaunit.assertEquals(Theme.Font(15), 30)
    end)
end

function TestThemeFont:testFontObjectAndTextWidthUseBoldFace()
    local regular = { GetStringWidth = function() return 10 end }
    local bold = { GetStringWidth = function() return 14 end }
    withFonts(nil, {
        MUSEO_SANS_15PT_REGULAR = regular,
        MUSEO_SANS_15PT_BOLD = bold,
    }, function(Theme)
        luaunit.assertEquals(Theme.FontObject(15), regular)
        luaunit.assertEquals(Theme.FontObject(15, true), bold)
        luaunit.assertEquals(Theme.TextWidth(15, "Hi"), 10)
        luaunit.assertEquals(Theme.TextWidth(15, "Hi", true), 14)
    end)
end

return TestThemeFont
