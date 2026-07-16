-- Exercises infobox.lua's InfoBox Area through its pure logic seam: the ordered box set
-- (insert / rewrite-in-place / remove-and-reflow), the horizontal-flow-with-wrap Layout,
-- hit-testing (BoxAt / TooltipAt), the overall Bounds, and drag-as-unit anchor moves. Canvas
-- drawing (ui.Canvas AddRectangle/AddSprite/AddText) is a client primitive and is not asserted
-- here, exactly like test_effects — only the geometry/state the node and draw loop depend on
-- is (#41 AC).

-- InfoBox.Draw resolves colors through Vector4 at draw time; stub it so requiring the module
-- (and any incidental color math) works under the bare Lua runtime, same as test_color does.
_G.Vector4 = _G.Vector4 or { new = function(r, g, b, a) return { r, g, b, a } end }

local luaunit = require("luaunit")
local InfoBox = require("ui/infobox")
local Theme = require("ui/theme")

--- Ordered box set -------------------------------------------------------------------------

TestBoxSet = {}

function TestBoxSet:setUp()
    self.area = InfoBox.new()
end

function TestBoxSet:testSetAddsABox()
    self.area:Set("a", { text = "1" })
    luaunit.assertTrue(self.area:Has("a"))
    luaunit.assertEquals(self.area:Count(), 1)
    luaunit.assertEquals(self.area:Get("a").text, "1")
end

function TestBoxSet:testSetStoresAllFields()
    self.area:Set("a", { text = "hp", color = { r = 1, g = 2, b = 3, a = 4 }, icon = 77, title = "Health" })
    local box = self.area:Get("a")
    luaunit.assertEquals(box.text, "hp")
    luaunit.assertEquals(box.color, { r = 1, g = 2, b = 3, a = 4 })
    luaunit.assertEquals(box.icon, 77)
    luaunit.assertEquals(box.title, "Health")
end

function TestBoxSet:testSetSameOwnerRewritesInPlaceKeepingOrder()
    self.area:Set("a", { text = "1" })
    self.area:Set("b", { text = "2" })
    self.area:Set("a", { text = "99" })  -- rewrite, must not move to the end
    luaunit.assertEquals(self.area:Count(), 2)
    luaunit.assertEquals(self.area:Order(), { "a", "b" })
    luaunit.assertEquals(self.area:Get("a").text, "99")
end

function TestBoxSet:testInsertionOrderPreserved()
    self.area:Set("x", { text = "1" })
    self.area:Set("y", { text = "2" })
    self.area:Set("z", { text = "3" })
    luaunit.assertEquals(self.area:Order(), { "x", "y", "z" })
end

function TestBoxSet:testRemoveDropsBoxAndReflows()
    self.area:Set("a", { text = "1" })
    self.area:Set("b", { text = "2" })
    self.area:Set("c", { text = "3" })
    luaunit.assertTrue(self.area:Remove("b"))
    luaunit.assertFalse(self.area:Has("b"))
    luaunit.assertEquals(self.area:Order(), { "a", "c" })  -- compacted, order otherwise intact
    luaunit.assertEquals(self.area:Count(), 2)
end

function TestBoxSet:testRemoveMissingIsFalseNoop()
    self.area:Set("a", { text = "1" })
    luaunit.assertFalse(self.area:Remove("nope"))
    luaunit.assertEquals(self.area:Count(), 1)
end

function TestBoxSet:testClearEmptiesEverything()
    self.area:Set("a", { text = "1" })
    self.area:Set("b", { text = "2" })
    self.area:Clear()
    luaunit.assertEquals(self.area:Count(), 0)
    luaunit.assertEquals(self.area:Order(), {})
end

--- Layout: horizontal flow + wrap ----------------------------------------------------------

TestLayout = {}

function TestLayout:setUp()
    self.area = InfoBox.new()
    self.area:SetAnchor(100, 50)
    -- A wrap width that fits exactly 3 fixed-square boxes per row, for deterministic wrap math.
    local size, gap = Theme.INFOBOX_BOX_SIZE, Theme.INFOBOX_GAP
    self.area:SetWrapWidth(size * 3 + gap * 2)
end

function TestLayout:testSingleBoxSitsAtAnchor()
    self.area:Set("a", { text = "1" })
    local rects = self.area:Layout()
    luaunit.assertEquals(#rects, 1)
    luaunit.assertEquals(rects[1].owner, "a")
    luaunit.assertEquals(rects[1].x, 100)
    luaunit.assertEquals(rects[1].y, 50)
    luaunit.assertEquals(rects[1].w, Theme.INFOBOX_BOX_SIZE)
    luaunit.assertEquals(rects[1].h, Theme.INFOBOX_BOX_SIZE)
end

function TestLayout:testHorizontalFlowWithinARow()
    self.area:Set("a", { text = "1" })
    self.area:Set("b", { text = "2" })
    local rects = self.area:Layout()
    local step = Theme.INFOBOX_BOX_SIZE + Theme.INFOBOX_GAP
    luaunit.assertEquals(rects[2].x, 100 + step)
    luaunit.assertEquals(rects[2].y, 50)  -- same row
end

function TestLayout:testWrapsToNextRowPastTheWrapWidth()
    for _, k in ipairs({ "a", "b", "c", "d" }) do
        self.area:Set(k, { text = k })
    end
    local rects = self.area:Layout()
    local step = Theme.INFOBOX_BOX_SIZE + Theme.INFOBOX_GAP
    -- 3 per row, so the 4th wraps back to column 0 on the second row.
    luaunit.assertEquals(rects[4].x, 100)
    luaunit.assertEquals(rects[4].y, 50 + step)
end

function TestLayout:testReflowAfterRemovePullsLaterBoxesUp()
    for _, k in ipairs({ "a", "b", "c", "d" }) do
        self.area:Set(k, { text = k })
    end
    self.area:Remove("a")  -- "d" was on row 2; removing one from row 1 pulls it back up
    local rects = self.area:Layout()
    local d = rects[#rects]
    luaunit.assertEquals(d.owner, "d")
    luaunit.assertEquals(d.y, 50)  -- reflowed onto the first row
end

--- Hit-testing -----------------------------------------------------------------------------

TestHitTest = {}

function TestHitTest:setUp()
    self.area = InfoBox.new()
    self.area:SetAnchor(0, 0)
    self.area:SetWrapWidth(1000)  -- one long row, no wrap
    self.area:Set("a", { text = "1", title = "Alpha" })
    self.area:Set("b", { text = "2" })  -- no title
end

function TestHitTest:testBoxAtInsideFirstBox()
    luaunit.assertEquals(self.area:BoxAt(5, 5), "a")
end

function TestHitTest:testBoxAtInsideSecondBox()
    local step = Theme.INFOBOX_BOX_SIZE + Theme.INFOBOX_GAP
    luaunit.assertEquals(self.area:BoxAt(step + 5, 5), "b")
end

function TestHitTest:testBoxAtOutsideIsNil()
    luaunit.assertNil(self.area:BoxAt(-5, -5))
    luaunit.assertNil(self.area:BoxAt(5, Theme.INFOBOX_BOX_SIZE + 100))
end

function TestHitTest:testTooltipReturnsTitleOverTitledBox()
    luaunit.assertEquals(self.area:TooltipAt(5, 5), "Alpha")
end

function TestHitTest:testTooltipNilOverUntitledBox()
    local step = Theme.INFOBOX_BOX_SIZE + Theme.INFOBOX_GAP
    luaunit.assertNil(self.area:TooltipAt(step + 5, 5))
end

function TestHitTest:testTooltipNilOutsideAnyBox()
    luaunit.assertNil(self.area:TooltipAt(-5, -5))
end

function TestHitTest:testEmptyTitleIsNoTooltip()
    self.area:Set("a", { text = "1", title = "" })
    luaunit.assertNil(self.area:TooltipAt(5, 5))
end

--- Bounds ----------------------------------------------------------------------------------

TestBounds = {}

function TestBounds:testBoundsNilWhenEmpty()
    local area = InfoBox.new()
    luaunit.assertNil(area:Bounds())
end

function TestBounds:testBoundsSpansAllBoxes()
    local area = InfoBox.new()
    area:SetAnchor(10, 20)
    area:SetWrapWidth(1000)
    area:Set("a", { text = "1" })
    area:Set("b", { text = "2" })
    local b = area:Bounds()
    local step = Theme.INFOBOX_BOX_SIZE + Theme.INFOBOX_GAP
    luaunit.assertEquals(b.x, 10)
    luaunit.assertEquals(b.y, 20)
    luaunit.assertEquals(b.w, step + Theme.INFOBOX_BOX_SIZE)
    luaunit.assertEquals(b.h, Theme.INFOBOX_BOX_SIZE)
end

--- Drag-as-unit ----------------------------------------------------------------------------

TestDrag = {}

function TestDrag:setUp()
    self.area = InfoBox.new()
    self.area:SetAnchor(100, 100)
    self.area:SetWrapWidth(1000)
    self.area:Set("a", { text = "1" })
end

function TestDrag:testBeginDragInsideBoundsGrabs()
    luaunit.assertTrue(self.area:BeginDrag(105, 105))
end

function TestDrag:testBeginDragOutsideBoundsDoesNotGrab()
    luaunit.assertFalse(self.area:BeginDrag(500, 500))
end

function TestDrag:testDragMovesAnchorByDelta()
    self.area:BeginDrag(105, 105)   -- grabbed 5px into the box
    self.area:Drag(155, 205)        -- moved the cursor +50,+100
    local ax, ay = self.area:GetAnchor()
    luaunit.assertEquals(ax, 150)   -- anchor tracks the cursor keeping the grab offset
    luaunit.assertEquals(ay, 200)
    -- The box itself follows the anchor.
    local rects = self.area:Layout()
    luaunit.assertEquals(rects[1].x, 150)
    luaunit.assertEquals(rects[1].y, 200)
end

function TestDrag:testDragIgnoredWithoutBeginDrag()
    self.area:Drag(300, 300)
    local ax, ay = self.area:GetAnchor()
    luaunit.assertEquals(ax, 100)
    luaunit.assertEquals(ay, 100)
end

function TestDrag:testEndDragPersistsAnchorThroughHook()
    local saved = {}
    self.area:SetPersistence({ SaveAnchor = function(x, y) saved.x, saved.y = x, y end })
    self.area:BeginDrag(105, 105)
    self.area:Drag(155, 205)
    self.area:EndDrag()
    luaunit.assertEquals(saved.x, 150)
    luaunit.assertEquals(saved.y, 200)
end

--- Node-facing helpers ---------------------------------------------------------------------

TestHelpers = {}

function TestHelpers:testResolveTextTostringsAnyValue()
    luaunit.assertEquals(InfoBox.ResolveText(5), "5")
    luaunit.assertEquals(InfoBox.ResolveText("hi"), "hi")
    luaunit.assertEquals(InfoBox.ResolveText(true), "true")
end

function TestHelpers:testResolveTextNilIsEmptyString()
    luaunit.assertEquals(InfoBox.ResolveText(nil), "")
end

function TestHelpers:testIsEmptyForNilZeroAndEmptyString()
    luaunit.assertTrue(InfoBox.IsEmpty(nil))
    luaunit.assertTrue(InfoBox.IsEmpty(0))
    luaunit.assertTrue(InfoBox.IsEmpty(""))
end

function TestHelpers:testIsNotEmptyForRealValues()
    luaunit.assertFalse(InfoBox.IsEmpty("0"))   -- the string "0" is a real value
    luaunit.assertFalse(InfoBox.IsEmpty(1))
    luaunit.assertFalse(InfoBox.IsEmpty("x"))
end
