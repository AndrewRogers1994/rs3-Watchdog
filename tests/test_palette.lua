-- Palette is drawn via the client's Canvas; Theme.Vec4/Theme.Font defer their Vector4/id
-- dependency to draw time specifically so tests can stub them (see ui/theme.lua). Stubbed
-- before requiring Palette so any module-load-time color/font building would also be safe.
_G.Vector4 = { new = function(r, g, b, a) return { r, g, b, a } end }
_G.id = { Font = setmetatable({}, { __index = function() return 1 end }) }
-- Theme.TextWidth measures via config.Font[name]:GetStringWidth; stub a deterministic
-- (if unrealistic) metric — 7px/byte — so panel-width tests can assert exact numbers.
_G.config = { Font = setmetatable({}, { __index = function()
    return { GetStringWidth = function(_, text) return #text * 7 end }
end }) }

local luaunit = require("luaunit")
local Palette = require("ui/palette")
local Theme = require("ui/theme")

TestPalette = {}

-- Two live Node Types per category, alphabetically bracketing the unavailable entries
-- ("Alarm"/"Zebra Trigger" bracket the trigger unavailable entries; "Alert Action"
-- brackets low, nothing brackets high in action since "Zap" isn't used here).
local function fakeRegistry()
    return {
        nodeTypes = {
            ["live.trigger.a"] = { key = "live.trigger.a", category = "trigger", displayName = "Alarm" },
            ["live.trigger.z"] = { key = "live.trigger.z", category = "trigger", displayName = "Zebra Trigger" },
            ["live.action.a"]  = { key = "live.action.a",  category = "action",  displayName = "Alert Action" },
        },
    }
end

local function mockCanvas()
    local canvas = { textCalls = {} }
    function canvas:AddRectangle() end
    function canvas:AddOutline() end
    function canvas:AddText(x, y, text, font, color)
        table.insert(self.textCalls, { x = x, y = y, text = text, color = color })
    end
    return canvas
end

function TestPalette:setUp()
    self.palette = Palette.new()
    self.registry = fakeRegistry()
end

-- Filters out non-header rows for easier sequence assertions.
local function itemRows(rows)
    local out = {}
    for _, r in ipairs(rows) do
        if not r.header then out[#out + 1] = r end
    end
    return out
end

function TestPalette:testUnfilteredOpenInterleavesUnavailableAlphabeticallyPerCategory()
    self.palette:Open(self.registry, nil, { screenX = 10, screenY = 10, anchorGX = 0, anchorGY = 0 })

    local items = itemRows(self.palette.rows)
    local names = {}
    for _, r in ipairs(items) do names[#names + 1] = r.displayName end

    luaunit.assertEquals(names, {
        "Alarm", "Inventory", "Overhead Text", "Sound Fired", "Zebra Trigger",
        "Alert Action", "Game Message", "Overhead", "Request Focus", "Text to Speech",
    })
end

function TestPalette:testUnavailableRowsCarryNoTypeKeyOrTargetPin()
    self.palette:Open(self.registry, nil, { screenX = 10, screenY = 10, anchorGX = 0, anchorGY = 0 })
    local liveNames = { Alarm = true, ["Zebra Trigger"] = true, ["Alert Action"] = true }
    for _, r in ipairs(itemRows(self.palette.rows)) do
        if liveNames[r.displayName] then
            luaunit.assertIsNil(r.unavailable)
            luaunit.assertNotNil(r.typeKey)
        else
            luaunit.assertTrue(r.unavailable)
            luaunit.assertIsNil(r.typeKey)
            luaunit.assertIsNil(r.targetPin)
            luaunit.assertNotNil(r.description)
        end
    end
    -- Spot-check one concrete description string against nodes/unavailable.lua.
    for _, r in ipairs(itemRows(self.palette.rows)) do
        if r.displayName == "Inventory" then
            luaunit.assertEquals(r.description, "no inventory-read API")
        end
    end
end

function TestPalette:testFilteredOpenExcludesUnavailableRows()
    local filterFn = function() return "in" end   -- accept every live type
    self.palette:Open(self.registry, filterFn, { screenX = 10, screenY = 10, anchorGX = 0, anchorGY = 0 })

    local items = itemRows(self.palette.rows)
    luaunit.assertEquals(#items, 3)   -- only the 3 live fake Node Types
    for _, r in ipairs(items) do
        luaunit.assertNil(r.unavailable)
        luaunit.assertNotNil(r.typeKey)
    end
end

function TestPalette:testUnavailableRowIsInertUnderRowAt()
    self.palette:Open(self.registry, nil, { screenX = 10, screenY = 10, anchorGX = 0, anchorGY = 0 })
    self.palette:Draw(mockCanvas(), 0, 0, 800, 600, -1, -1)

    -- Row order (see interleave test): 1 header, 2 Alarm, 3 Inventory (unavailable), ...
    local rowH, pad, px, py = Theme.PALETTE_ROW_H, Theme.PALETTE_PAD, 10, 10
    local function midY(rowIndex) return py + pad + (rowIndex - 1) * rowH + math.floor(rowH / 2) end
    local mx = px + 50

    luaunit.assertIsNil(self.palette:RowAt(mx, midY(3)))   -- Inventory: click does nothing

    local live = self.palette:RowAt(mx, midY(2))            -- Alarm: still clickable
    luaunit.assertNotNil(live)
    luaunit.assertEquals(live.typeKey, "live.trigger.a")
end

function TestPalette:testDrawShowsDimmedReasonOnUnavailableRowsOnly()
    self.palette:Open(self.registry, nil, { screenX = 10, screenY = 10, anchorGX = 0, anchorGY = 0 })
    local canvas = mockCanvas()
    self.palette:Draw(canvas, 0, 0, 800, 600, -1, -1)

    local byText = {}
    for _, c in ipairs(canvas.textCalls) do byText[c.text] = c end

    -- Live row: plain display name, normal (non-dimmed) text color.
    luaunit.assertNotNil(byText["Alarm"])
    luaunit.assertEquals(byText["Alarm"].color, Theme.Vec4(Theme.COL_PALETTE_TEXT))

    -- Unavailable row: name and description are drawn as separate calls, both dimmed.
    luaunit.assertNotNil(byText["Inventory"])
    luaunit.assertEquals(byText["Inventory"].color, Theme.Vec4(Theme.COL_PALETTE_TEXT_DIM))
    local inventoryDesc = " - no inventory-read API"
    luaunit.assertNotNil(byText[inventoryDesc],
        "expected an inline description drawn for the unavailable Inventory row")
    luaunit.assertEquals(byText[inventoryDesc].color, Theme.Vec4(Theme.COL_PALETTE_TEXT_DIM))
end

-- A live Node Type carrying a `description` (#52, e.g. Client Tick's "Fires 50x/sec") renders
-- an inline description suffix the same way an unavailable row does: the name in the normal
-- (non-dimmed) text color since it's a real, clickable type, but the description suffix always
-- dimmed so it reads as a secondary blurb.
function TestPalette:testDrawShowsInlineDescriptionOnLiveNodeType()
    self.registry.nodeTypes["live.trigger.tick"] = {
        key = "live.trigger.tick", category = "trigger",
        displayName = "Client Tick", description = "Fires 50x/sec",
    }
    self.palette:Open(self.registry, nil, { screenX = 10, screenY = 10, anchorGX = 0, anchorGY = 0 })
    local canvas = mockCanvas()
    self.palette:Draw(canvas, 0, 0, 800, 600, -1, -1)

    local byText = {}
    for _, c in ipairs(canvas.textCalls) do byText[c.text] = c end

    -- Name in normal color; the description suffix drawn separately and dimmed.
    luaunit.assertNotNil(byText["Client Tick"])
    luaunit.assertEquals(byText["Client Tick"].color, Theme.Vec4(Theme.COL_PALETTE_TEXT))
    local tickDesc = " - Fires 50x/sec"
    luaunit.assertNotNil(byText[tickDesc],
        "expected an inline description drawn for the live Client Tick row")
    luaunit.assertEquals(byText[tickDesc].color, Theme.Vec4(Theme.COL_PALETTE_TEXT_DIM))

    -- And it's a real, clickable row (unlike an unavailable one): RowAt returns it.
    local rowH, pad, px, py = Theme.PALETTE_ROW_H, Theme.PALETTE_PAD, 10, 10
    -- Row order within the trigger group is alphabetical by displayName; "Client Tick" sorts
    -- after "Alarm" (row 2) and the interleaved unavailable "Inventory"/"Overhead Text"/
    -- "Sound Fired" — but we don't need its exact index: assert the drawn call carried a
    -- typeKey-bearing item row by finding it back through the rows list.
    local found
    for _, r in ipairs(self.palette.rows) do
        if r.typeKey == "live.trigger.tick" then found = r break end
    end
    luaunit.assertNotNil(found)
    luaunit.assertIsNil(found.unavailable)
end

function TestPalette:testDrawWidensPanelToFitLongestRowText()
    self.registry.nodeTypes["live.trigger.long"] = {
        key = "live.trigger.long", category = "trigger", displayName = string.rep("A", 45),
    }
    self.palette:Open(self.registry, nil, { screenX = 10, screenY = 10, anchorGX = 0, anchorGY = 0 })
    self.palette:Draw(mockCanvas(), 0, 0, 800, 600, -1, -1)

    -- The item-row text inset (14, see ui/palette.lua's ITEM_INSET), mirrored on both
    -- sides, + 45 chars * the stub's 7px/byte comfortably beats every other row,
    -- including the fixed Theme.PALETTE_W this panel used to be capped at (which
    -- clipped long reason text).
    luaunit.assertEquals(self.palette.rect.w, 14 * 2 + 45 * 7)
    luaunit.assertTrue(self.palette.rect.w > Theme.PALETTE_W)
end

function TestPalette:testDrawClampsPanelWidthToViewport()
    self.registry.nodeTypes["live.trigger.long"] = {
        key = "live.trigger.long", category = "trigger", displayName = string.rep("A", 45),
    }
    self.palette:Open(self.registry, nil, { screenX = 10, screenY = 10, anchorGX = 0, anchorGY = 0 })
    self.palette:Draw(mockCanvas(), 0, 0, 100, 600, -1, -1)   -- viewport narrower than content

    luaunit.assertEquals(self.palette.rect.w, 100)
end

return TestPalette
