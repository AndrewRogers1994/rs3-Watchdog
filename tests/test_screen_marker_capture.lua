-- Exercises the Screen Marker capture overlay's (ui/screen_marker_capture.lua, #39) pure
-- Arm/Cancel/BeginDrag/UpdateDrag/EndDrag state machine and its static Rect() normalizer in
-- isolation -- no client globals (ui.Button/Mouse) involved, the same way ui/color.lua's math
-- is tested without a client. Mount/Reposition/Unmount/Draw are client-only and intentionally
-- not asserted here (see the module's own header note).

local luaunit = require("luaunit")
local ScreenMarkerCapture = require("ui/screen_marker_capture")

TestScreenMarkerCaptureRect = {}

function TestScreenMarkerCaptureRect:testNormalizesTopLeftToBottomRightDrag()
    local r = ScreenMarkerCapture.Rect(10, 20, 110, 220)
    luaunit.assertEquals(r, { x = 10, y = 20, w = 100, h = 200 })
end

function TestScreenMarkerCaptureRect:testNormalizesBottomRightToTopLeftDrag()
    local r = ScreenMarkerCapture.Rect(110, 220, 10, 20)
    luaunit.assertEquals(r, { x = 10, y = 20, w = 100, h = 200 })
end

function TestScreenMarkerCaptureRect:testNormalizesMixedDirectionDrags()
    -- top-right to bottom-left, and bottom-left to top-right.
    luaunit.assertEquals(ScreenMarkerCapture.Rect(110, 20, 10, 220), { x = 10, y = 20, w = 100, h = 200 })
    luaunit.assertEquals(ScreenMarkerCapture.Rect(10, 220, 110, 20), { x = 10, y = 20, w = 100, h = 200 })
end

function TestScreenMarkerCaptureRect:testZeroSizeDragIsAValidDegenerateRect()
    luaunit.assertEquals(ScreenMarkerCapture.Rect(50, 50, 50, 50), { x = 50, y = 50, w = 0, h = 0 })
end

TestScreenMarkerCaptureStateMachine = {}

function TestScreenMarkerCaptureStateMachine:setUp()
    self.sm = ScreenMarkerCapture.new()
end

function TestScreenMarkerCaptureStateMachine:testStartsIdle()
    luaunit.assertFalse(self.sm:IsArmed())
    luaunit.assertFalse(self.sm:IsDragging())
end

function TestScreenMarkerCaptureStateMachine:testArmSetsArmedButNotDragging()
    self.sm:Arm("n1", "rect", function() end)
    luaunit.assertTrue(self.sm:IsArmed())
    luaunit.assertFalse(self.sm:IsDragging())
end

function TestScreenMarkerCaptureStateMachine:testBeginDragOnlyStartsWhenArmed()
    self.sm:BeginDrag(1, 1) -- not armed: no-op
    luaunit.assertFalse(self.sm:IsDragging())

    self.sm:Arm("n1", "rect", function() end)
    self.sm:BeginDrag(5, 6)
    luaunit.assertTrue(self.sm:IsDragging())
end

function TestScreenMarkerCaptureStateMachine:testBeginDragTwiceKeepsTheFirstStartPoint()
    self.sm:Arm("n1", "rect", function() end)
    self.sm:BeginDrag(5, 6)
    self.sm:BeginDrag(50, 60) -- already dragging: no-op, doesn't reset the start corner
    self.sm:UpdateDrag(15, 16)
    local committed
    self.sm.onCommit = function(rect) committed = rect end
    self.sm:EndDrag()
    luaunit.assertEquals(committed, { x = 5, y = 6, w = 10, h = 10 })
end

function TestScreenMarkerCaptureStateMachine:testUpdateDragNoopsWhenNotDragging()
    self.sm:UpdateDrag(99, 99) -- never armed/dragging
    luaunit.assertFalse(self.sm:IsDragging())
end

function TestScreenMarkerCaptureStateMachine:testEndDragCommitsNormalizedRectAndResetsToIdle()
    local committed, committedNode, committedPin
    self.sm:Arm("n1", "rect", function(rect) committed = rect end)
    self.sm:BeginDrag(100, 100)
    self.sm:UpdateDrag(20, 40)
    committedNode, committedPin = self.sm.nodeId, self.sm.pinName
    self.sm:EndDrag()

    luaunit.assertEquals(committed, { x = 20, y = 40, w = 80, h = 60 })
    luaunit.assertEquals(committedNode, "n1")
    luaunit.assertEquals(committedPin, "rect")
    luaunit.assertFalse(self.sm:IsArmed())
    luaunit.assertFalse(self.sm:IsDragging())
end

function TestScreenMarkerCaptureStateMachine:testEndDragNoopsWhenNotDragging()
    local calls = 0
    self.sm:Arm("n1", "rect", function() calls = calls + 1 end)
    self.sm:EndDrag() -- armed but never began a drag
    luaunit.assertEquals(calls, 0)
end

function TestScreenMarkerCaptureStateMachine:testCancelWhileArmedNotDraggingAbortsWithNoCommit()
    local calls = 0
    self.sm:Arm("n1", "rect", function() calls = calls + 1 end)
    self.sm:Cancel()
    luaunit.assertEquals(calls, 0)
    luaunit.assertFalse(self.sm:IsArmed())
end

function TestScreenMarkerCaptureStateMachine:testCancelMidDragAbortsWithNoCommit()
    local calls = 0
    self.sm:Arm("n1", "rect", function() calls = calls + 1 end)
    self.sm:BeginDrag(1, 1)
    self.sm:UpdateDrag(9, 9)
    self.sm:Cancel()
    luaunit.assertEquals(calls, 0)
    luaunit.assertFalse(self.sm:IsDragging())

    -- A stray EndDrag after Cancel is a no-op too (nothing left to commit).
    self.sm:EndDrag()
    luaunit.assertEquals(calls, 0)
end

function TestScreenMarkerCaptureStateMachine:testReArmingRetargetsWithoutFiringThePriorCommit()
    local firstCalls, secondCommitted = 0, nil
    self.sm:Arm("n1", "rectA", function() firstCalls = firstCalls + 1 end)
    self.sm:Arm("n2", "rectB", function(rect) secondCommitted = rect end)

    luaunit.assertEquals(self.sm.nodeId, "n2")
    luaunit.assertEquals(self.sm.pinName, "rectB")

    self.sm:BeginDrag(0, 0)
    self.sm:UpdateDrag(4, 8)
    self.sm:EndDrag()

    luaunit.assertEquals(firstCalls, 0)
    luaunit.assertEquals(secondCommitted, { x = 0, y = 0, w = 4, h = 8 })
end

--- DimRegions: snipping-tool hole (#71) ----------------------------------------------------

TestScreenMarkerCaptureDimRegions = {}

function TestScreenMarkerCaptureDimRegions:testNilHoleDimsTheWholeScreen()
    local regions = ScreenMarkerCapture.DimRegions(800, 600, nil)
    luaunit.assertEquals(regions, { { x = 0, y = 0, w = 800, h = 600 } })
end

function TestScreenMarkerCaptureDimRegions:testHoleSplitsIntoFourSurroundingRects()
    -- Selection at (100,50) size 200x100 inside 800x600.
    local regions = ScreenMarkerCapture.DimRegions(800, 600, { x = 100, y = 50, w = 200, h = 100 })
    luaunit.assertEquals(#regions, 4)
    -- top band
    luaunit.assertEquals(regions[1], { x = 0, y = 0, w = 800, h = 50 })
    -- left of hole
    luaunit.assertEquals(regions[2], { x = 0, y = 50, w = 100, h = 100 })
    -- right of hole
    luaunit.assertEquals(regions[3], { x = 300, y = 50, w = 500, h = 100 })
    -- bottom band
    luaunit.assertEquals(regions[4], { x = 0, y = 150, w = 800, h = 450 })
end

function TestScreenMarkerCaptureDimRegions:testZeroSizeHoleStillDimsWholeScreenAsFourBands()
    local regions = ScreenMarkerCapture.DimRegions(100, 100, { x = 40, y = 40, w = 0, h = 0 })
    luaunit.assertEquals(#regions, 4)
    luaunit.assertEquals(regions[1], { x = 0, y = 0, w = 100, h = 40 })
    luaunit.assertEquals(regions[2], { x = 0, y = 40, w = 40, h = 0 })
    luaunit.assertEquals(regions[3], { x = 40, y = 40, w = 60, h = 0 })
    luaunit.assertEquals(regions[4], { x = 0, y = 40, w = 100, h = 60 })
end

return TestScreenMarkerCaptureRect
