-- Exercises the Object Marker select-mode capture (ui/object_marker_capture.lua, #40): the
-- global-modal "Select object" mode that subscribes Event.MiniMenuEntrySelected while armed and
-- captures on an Examine of a LOC. The capture predicate (Examine + LOC) and the param
-- extraction are pure and tested directly; the arm/commit/disarm state machine is driven through
-- an injected fake event source (tests/fake_event_source.lua), the same seam runtime.lua uses,
-- so the real client Event global is never needed.

local luaunit = require("luaunit")
local newFakeEventSource = require("fake_event_source")
local ObjectMarkerCapture = require("ui/object_marker_capture")

-- Numeric enum values matching MiniMenuActionVerbType / MiniMenuEntryType (see minimenu stub).
local EXAMINE, OP = 1, 2
local LOC, NPC = 3, 4

local function locEntry(overrides)
    local e = {
        actionVerbType = EXAMINE,
        actionEntryType = LOC,
        subjectHash = 98765,
        coordGridX = 3200,
        coordGridZ = 3200,
        coordGridLevel = 1,
        locData = { config = { name = "Bank booth" } },
    }
    for k, v in pairs(overrides or {}) do e[k] = v end
    return e
end

--- Predicate --------------------------------------------------------------------------------

TestObjectMarkerCapturePredicate = {}

function TestObjectMarkerCapturePredicate:testCapturesExamineOfALoc()
    luaunit.assertTrue(ObjectMarkerCapture.ShouldCapture(locEntry()))
end

function TestObjectMarkerCapturePredicate:testIgnoresNonExamineVerbOnALoc()
    luaunit.assertFalse(ObjectMarkerCapture.ShouldCapture(locEntry({ actionVerbType = OP })))
end

function TestObjectMarkerCapturePredicate:testIgnoresExamineOfANonLoc()
    luaunit.assertFalse(ObjectMarkerCapture.ShouldCapture(locEntry({ actionEntryType = NPC })))
end

function TestObjectMarkerCapturePredicate:testIgnoresNilEntry()
    luaunit.assertFalse(ObjectMarkerCapture.ShouldCapture(nil))
end

-- BUILD-VERIFY shape tolerance: the docs example wraps the selected entry in `.entry`; the
-- predicate must accept the wrapper as well as a bare entry.
function TestObjectMarkerCapturePredicate:testCapturesWrappedEventPayload()
    luaunit.assertTrue(ObjectMarkerCapture.ShouldCapture({ entry = locEntry() }))
end

--- Extraction -------------------------------------------------------------------------------

TestObjectMarkerCaptureExtract = {}

function TestObjectMarkerCaptureExtract:testExtractsNameCoordAndSubjectHash()
    local o = ObjectMarkerCapture.Extract(locEntry())
    luaunit.assertNotNil(o)
    luaunit.assertEquals(o.name, "Bank booth")
    luaunit.assertEquals(o.coordGrid.x, 3200)
    luaunit.assertEquals(o.coordGrid.z, 3200)
    luaunit.assertEquals(o.coordGrid.level, 1)
    luaunit.assertEquals(o.subjectHash, 98765)
end

function TestObjectMarkerCaptureExtract:testDefaultsMissingLevelToZero()
    -- Built without coordGridLevel (a nil override can't remove a field from a Lua table).
    local o = ObjectMarkerCapture.Extract({
        actionVerbType = EXAMINE, actionEntryType = LOC, subjectHash = 1,
        coordGridX = 10, coordGridZ = 20, locData = { config = { name = "Door" } },
    })
    luaunit.assertEquals(o.coordGrid.level, 0)
end

function TestObjectMarkerCaptureExtract:testReturnsNilWhenLocDataMissing()
    luaunit.assertNil(ObjectMarkerCapture.Extract({
        actionVerbType = EXAMINE, actionEntryType = LOC, subjectHash = 1,
        coordGridX = 10, coordGridZ = 20,
    }))
end

function TestObjectMarkerCaptureExtract:testUnwrapsWrappedEventPayload()
    local o = ObjectMarkerCapture.Extract({ entry = locEntry() })
    luaunit.assertEquals(o.name, "Bank booth")
    luaunit.assertEquals(o.coordGrid.x, 3200)
    luaunit.assertEquals(o.subjectHash, 98765)
end

function TestObjectMarkerCaptureExtract:testReadsCoordNestedUnderLocData()
    -- If the live client nests the coord under locData rather than on the entry, Extract still
    -- finds it (build-verify tolerance).
    local o = ObjectMarkerCapture.Extract({
        actionVerbType = EXAMINE, actionEntryType = LOC, subjectHash = 7,
        locData = { config = { name = "Altar" }, coordGridX = 111, coordGridZ = 222, coordGridLevel = 2 },
    })
    luaunit.assertEquals(o.coordGrid.x, 111)
    luaunit.assertEquals(o.coordGrid.z, 222)
    luaunit.assertEquals(o.coordGrid.level, 2)
end

--- State machine (armed subscription + single-shot commit) ---------------------------------

TestObjectMarkerCaptureFlow = {}

-- Each test builds its capture + fake source as locals (never stored on `self`): the fake source's
-- lazy-channel metatable indexes with a nil key when luaunit's between-test prettystr walks it, so
-- keeping the object graph out of the persistent class table sidesteps that harness quirk entirely.
local function armed()
    local harness = newFakeEventSource()
    local capture = ObjectMarkerCapture.new(harness.source)
    local rec = { committed = nil, count = 0 }
    capture:Arm("node1", "object", function(o)
        rec.committed = o
        rec.count = rec.count + 1
    end)
    return capture, harness, rec
end

function TestObjectMarkerCaptureFlow:testArmSubscribesToMiniMenuEntrySelected()
    local capture, harness = armed()
    luaunit.assertTrue(capture:IsArmed())
    luaunit.assertEquals(harness:SubscribeCount("MiniMenuEntrySelected"), 1)
end

function TestObjectMarkerCaptureFlow:testCapturesAndCommitsOnExamineLoc()
    local _capture, harness, rec = armed()
    harness:Push("MiniMenuEntrySelected", locEntry())
    luaunit.assertEquals(rec.count, 1)
    luaunit.assertEquals(rec.committed.name, "Bank booth")
    luaunit.assertEquals(rec.committed.subjectHash, 98765)
end

function TestObjectMarkerCaptureFlow:testDisarmsAfterASuccessfulCapture()
    local capture, harness, rec = armed()
    harness:Push("MiniMenuEntrySelected", locEntry())
    luaunit.assertFalse(capture:IsArmed())
    -- A second entry after the single-shot capture is ignored (no double commit).
    harness:Push("MiniMenuEntrySelected", locEntry())
    luaunit.assertEquals(rec.count, 1)
end

function TestObjectMarkerCaptureFlow:testNonLocEntryIsIgnoredAndStaysArmed()
    local capture, harness, rec = armed()
    harness:Push("MiniMenuEntrySelected", locEntry({ actionEntryType = NPC }))
    luaunit.assertEquals(rec.count, 0)
    luaunit.assertTrue(capture:IsArmed())
end

function TestObjectMarkerCaptureFlow:testCancelDisarmsWithoutCommitting()
    local capture, harness, rec = armed()
    capture:Cancel()
    luaunit.assertFalse(capture:IsArmed())
    harness:Push("MiniMenuEntrySelected", locEntry())
    luaunit.assertEquals(rec.count, 0)
end

function TestObjectMarkerCaptureFlow:testEntryWhileDisarmedIsIgnored()
    -- No Arm at all: a stray MiniMenuEntrySelected must never reach a nil onCommit.
    local harness = newFakeEventSource()
    ObjectMarkerCapture.new(harness.source)
    local ok = pcall(function() harness:Push("MiniMenuEntrySelected", locEntry()) end)
    luaunit.assertTrue(ok)
end

return TestObjectMarkerCapturePredicate
