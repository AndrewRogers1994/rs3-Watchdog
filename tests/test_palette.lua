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

-- The scrollbar is only drawn (and its rect recorded) when the row list overflows the
-- visible area. A short list that fits leaves no scrollbar behind.
function TestPalette:testScrollbarOnlyWhenListOverflows()
    self.palette:Open(self.registry, nil, { screenX = 10, screenY = 10, anchorGX = 0, anchorGY = 0 })

    -- Tall draw rect: all 12 rows (2 headers + 10 items) fit, so no scrollbar.
    self.palette:Draw(mockCanvas(), 0, 0, 800, 600, -1, -1)
    luaunit.assertIsNil(self.palette.rect.scrollbar)
    luaunit.assertEquals(self.palette.maxScroll, 0)

    -- Short draw rect forces only a few visible rows -> overflow -> scrollbar present.
    self.palette:Draw(mockCanvas(), 0, 0, 800, 80, -1, -1)
    local sb = self.palette.rect.scrollbar
    luaunit.assertNotNil(sb)
    luaunit.assertTrue(self.palette.maxScroll > 0)
    -- Thumb is proportional but floored to the grabbable minimum, and never taller than the track.
    luaunit.assertTrue(sb.thumbH >= math.min(Theme.PALETTE_SCROLLBAR_MIN_THUMB, sb.h))
    luaunit.assertTrue(sb.thumbH <= sb.h)
end

-- Reserving the gutter narrows the clickable row width: a press in the scrollbar column
-- returns no row even at a row's own Y, while the same row is still hittable to its left.
function TestPalette:testRowAtExcludesScrollbarGutter()
    self.palette:Open(self.registry, nil, { screenX = 10, screenY = 10, anchorGX = 0, anchorGY = 0 })
    self.palette:Draw(mockCanvas(), 0, 0, 800, 80, -1, -1)   -- overflow -> gutter reserved

    local r = self.palette.rect
    local sb = r.scrollbar
    -- Alarm is the first item row (row 2, after the trigger header at row 1) and, unscrolled,
    -- it's the first visible non-header row.
    local rowY = r.y + r.pad + 1 * r.rowH + math.floor(r.rowH / 2)

    -- Left of the gutter: the row is live and hittable.
    luaunit.assertNotNil(self.palette:RowAt(r.x + 4, rowY))
    -- Inside the gutter column at the same Y: no row (it's the scrollbar's space).
    luaunit.assertIsNil(self.palette:RowAt(sb.x + 1, rowY))
end

-- Press-anywhere jump-to-cursor mapping: clicking at (or above) the track top pins scroll to
-- 0; clicking at (or below) the track bottom pins it to maxScroll. Centered-thumb math, so the
-- endpoints saturate rather than leaving the thumb half-hanging off the ends.
function TestPalette:testScrollToYMapsEndpoints()
    self.palette:Open(self.registry, nil, { screenX = 10, screenY = 10, anchorGX = 0, anchorGY = 0 })
    self.palette:Draw(mockCanvas(), 0, 0, 800, 80, -1, -1)   -- overflow
    local sb = self.palette.rect.scrollbar

    self.palette:ScrollToY(sb.y)
    luaunit.assertEquals(self.palette.scroll, 0)

    self.palette:ScrollToY(sb.y + sb.h)
    luaunit.assertEquals(self.palette.scroll, self.palette.maxScroll)

    -- Well above the track saturates at 0 too (clamped, not negative).
    self.palette:ScrollToY(sb.y - 100)
    luaunit.assertEquals(self.palette.scroll, 0)
end

-- ScrollbarAt reports a press within the gutter column (used by the Editor to start a drag),
-- and rejects a press out over the rows or entirely outside the panel.
function TestPalette:testScrollbarAtHitTest()
    self.palette:Open(self.registry, nil, { screenX = 10, screenY = 10, anchorGX = 0, anchorGY = 0 })
    self.palette:Draw(mockCanvas(), 0, 0, 800, 80, -1, -1)
    local sb = self.palette.rect.scrollbar

    luaunit.assertTrue(self.palette:ScrollbarAt(sb.x + 1, sb.y + 5))
    luaunit.assertFalse(self.palette:ScrollbarAt(self.palette.rect.x + 4, sb.y + 5))  -- over a row
    luaunit.assertFalse(self.palette:ScrollbarAt(-50, -50))                            -- off-panel
end

-- With no scrollbar (short list) ScrollbarAt is always false and ScrollToY is inert.
function TestPalette:testScrollbarInertWhenNoOverflow()
    self.palette:Open(self.registry, nil, { screenX = 10, screenY = 10, anchorGX = 0, anchorGY = 0 })
    self.palette:Draw(mockCanvas(), 0, 0, 800, 600, -1, -1)   -- everything fits
    luaunit.assertFalse(self.palette:ScrollbarAt(self.palette.rect.x + 1, self.palette.rect.y + 1))
    self.palette:ScrollToY(9999)
    luaunit.assertEquals(self.palette.scroll, 0)
end

function TestPalette:testDrawClampsPanelWidthToViewport()
    self.registry.nodeTypes["live.trigger.long"] = {
        key = "live.trigger.long", category = "trigger", displayName = string.rep("A", 45),
    }
    self.palette:Open(self.registry, nil, { screenX = 10, screenY = 10, anchorGX = 0, anchorGY = 0 })
    self.palette:Draw(mockCanvas(), 0, 0, 100, 600, -1, -1)   -- viewport narrower than content

    luaunit.assertEquals(self.palette.rect.w, 100)
end

function TestPalette:testFilteredOpenCarriesTargetMode()
    self.registry.nodeTypes["live.modes"] = {
        key = "live.modes", category = "pure", displayName = "Modey",
    }
    local filterFn = function() return "n", "count" end
    self.palette:Open(self.registry, filterFn, { screenX = 10, screenY = 10, anchorGX = 0, anchorGY = 0 })

    local found
    for _, r in ipairs(itemRows(self.palette.rows)) do
        if r.typeKey == "live.modes" then found = r end
        luaunit.assertNil(r.unavailable)
    end
    luaunit.assertNotNil(found)
    luaunit.assertEquals(found.targetPin, "n")
    luaunit.assertEquals(found.targetMode, "count")
end

return TestPalette
