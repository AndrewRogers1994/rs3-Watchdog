-- Palette gates (#116). Game Message and Shortest Path each appear once. A closed
-- gate is an Unavailable row and cannot be placed, including from a filtered open.
-- Opening the gate makes that same row placeable. The permanent list is unchanged.

_G.Vector4 = _G.Vector4 or { new = function(r, g, b, a) return { r, g, b, a } end }
_G.id = _G.id or { Font = setmetatable({}, { __index = function() return 1 end }) }
_G.config = _G.config or { Font = setmetatable({}, { __index = function()
    return { GetStringWidth = function(_, text) return #text * 7 end }
end }) }

local luaunit = require("luaunit")
local Palette = require("src/ui/palette")
local Registry = require("registry")
local GameMessage = require("src/nodes/actions/game_message")
local ShortestPath = require("src/nodes/actions/shortest_path")

local CHAT = "chatAccess"
local OPTS = { screenX = 10, screenY = 10, anchorGX = 0, anchorGY = 0 }

TestPaletteGates = {}

local function itemRows(rows)
    local out = {}
    for _, r in ipairs(rows) do
        if not r.header then out[#out + 1] = r end
    end
    return out
end

local function mockCanvas()
    local canvas = {}
    function canvas:AddRectangle() end
    function canvas:AddOutline() end
    function canvas:AddText() end
    return canvas
end

function TestPaletteGates:setUp()
    self.saved = {
        Plugin = _G.Plugin,
        PluginPermissions = _G.PluginPermissions,
        Event = _G.Event,
        shortestpath = _G.shortestpath,
    }
    self.chatGranted = false
    _G.PluginPermissions = { chatAccess = CHAT }
    _G.Plugin = {
        HasPermission = function(permission)
            return permission == CHAT and self.chatGranted == true
        end,
    }
    _G.shortestpath = nil
    self.onPermission = nil
    self.onDependency = nil
    _G.Event = {
        OptionalPermissionChanged = {
            Subscribe = function(_, fn) self.onPermission = fn end,
        },
        OptionalDependencyChanged = {
            Subscribe = function(_, fn) self.onDependency = fn end,
        },
    }
    self.registry = Registry.new()
    GameMessage.Register(self.registry)
    ShortestPath.Register(self.registry)
    self.palette = Palette.new()
end

function TestPaletteGates:tearDown()
    _G.Plugin = self.saved.Plugin
    _G.PluginPermissions = self.saved.PluginPermissions
    _G.Event = self.saved.Event
    _G.shortestpath = self.saved.shortestpath
end

function TestPaletteGates:rowNamed(name)
    for _, row in ipairs(itemRows(self.palette.rows)) do
        if row.displayName == name then return row end
    end
    return nil
end

function TestPaletteGates:countNamed(name)
    local n = 0
    for _, row in ipairs(itemRows(self.palette.rows)) do
        if row.displayName == name then n = n + 1 end
    end
    return n
end

function TestPaletteGates:rowAtName(name)
    self.palette:Draw(mockCanvas(), 0, 0, 800, 600, -1, -1)
    local r = self.palette.rect
    for i, row in ipairs(self.palette.rows) do
        if row.displayName == name then
            local y = r.y + r.pad + (i - 1) * r.rowH + math.floor(r.rowH / 2)
            return self.palette:RowAt(r.x + 20, y)
        end
    end
    return nil
end

function TestPaletteGates:testClosedGatesAreUnavailableOnceAndCannotBePlaced()
    self.palette:Open(self.registry, nil, OPTS)

    luaunit.assertEquals(self:countNamed("Game Message"), 1)
    luaunit.assertEquals(self:countNamed("Shortest Path"), 1)

    local game = self:rowNamed("Game Message")
    local path = self:rowNamed("Shortest Path")
    luaunit.assertTrue(game.unavailable)
    luaunit.assertEquals(game.description, "needs chat permission")
    luaunit.assertIsNil(game.typeKey)
    luaunit.assertTrue(path.unavailable)
    luaunit.assertEquals(path.description, "needs Shortest Path")
    luaunit.assertIsNil(path.typeKey)

    -- The type stays registered, so a node already on a graph still has a type.
    luaunit.assertNotNil(self.registry:GetNodeType("action.game_message"))
    luaunit.assertNotNil(self.registry:GetNodeType("action.shortest_path"))

    luaunit.assertIsNil(self:rowAtName("Game Message"))
    luaunit.assertIsNil(self:rowAtName("Shortest Path"))

    self.palette:Open(self.registry, function() return "in" end, OPTS)
    luaunit.assertEquals(self:countNamed("Game Message"), 0)
    luaunit.assertEquals(self:countNamed("Shortest Path"), 0)

    -- Permanent rows stay on the unfiltered list only, and the old chat-injection row is gone.
    self.palette:Open(self.registry, nil, OPTS)
    luaunit.assertEquals(self:rowNamed("Overhead Text").description, "no overhead-text event")
    luaunit.assertEquals(self:rowNamed("Sound Fired").description, "no sound-played event")
    luaunit.assertEquals(self:rowNamed("Overhead").description, "no overhead-text API")
    luaunit.assertEquals(self:rowNamed("Request Focus").description, "no focus-request API")
    luaunit.assertEquals(self:rowNamed("Text to Speech").description, "needs file write")
    for _, row in ipairs(itemRows(self.palette.rows)) do
        luaunit.assertNotEquals(row.description, "no chat-injection API")
    end
end

function TestPaletteGates:testOpeningTheGatesMakesTheSameRowsPlaceable()
    self.onPermission({ permission = CHAT, enabled = true })
    self.onDependency({ pluginIdentifier = "shortestpath", enabled = true })

    self.palette:Open(self.registry, nil, OPTS)
    luaunit.assertEquals(self:countNamed("Game Message"), 1)
    luaunit.assertEquals(self:countNamed("Shortest Path"), 1)

    local game = self:rowNamed("Game Message")
    local path = self:rowNamed("Shortest Path")
    luaunit.assertNil(game.unavailable)
    luaunit.assertEquals(game.typeKey, "action.game_message")
    luaunit.assertNil(path.unavailable)
    luaunit.assertEquals(path.typeKey, "action.shortest_path")

    local hitGame = self:rowAtName("Game Message")
    luaunit.assertNotNil(hitGame)
    luaunit.assertEquals(hitGame.typeKey, "action.game_message")
    local hitPath = self:rowAtName("Shortest Path")
    luaunit.assertNotNil(hitPath)
    luaunit.assertEquals(hitPath.typeKey, "action.shortest_path")

    self.palette:Open(self.registry, function() return "in" end, OPTS)
    luaunit.assertEquals(self:rowNamed("Game Message").typeKey, "action.game_message")
    luaunit.assertEquals(self:rowNamed("Shortest Path").typeKey, "action.shortest_path")
    luaunit.assertEquals(self:countNamed("Overhead Text"), 0)
end

return TestPaletteGates
