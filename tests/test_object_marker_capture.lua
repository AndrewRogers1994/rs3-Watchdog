-- Object Marker MiniMenu capture (ui/object_marker_capture.lua) via a fake Event source.

local luaunit = require("luaunit")
local newFakeEventSource = require("fake_event_source")
local ObjectMarkerCapture = require("ui/object_marker_capture")

local function locEntry(overrides)
    local e = {
        subjectHash = 98765,
        coordGridX = 3200,
        coordGridZ = 3200,
        coordGridLevel = 1,
        locData = { config = { name = "Bank booth" } },
    }
    for k, v in pairs(overrides or {}) do e[k] = v end
    return e
end

local function npcEntry()
    return { subjectHash = 1, npcData = { entity = {} } }
end

local function fakeMenu(entries)
    local menu = { entries = entries or {}, addCount = 0, swaps = {} }
    function menu:Add(name, fn)
        self.addCount = self.addCount + 1
        self.lastAddName = name
        self.lastAddFn = fn
        self.entries[#self.entries + 1] = { overrideText = name }
    end
    function menu:Swap(a, b)
        self.swaps[#self.swaps + 1] = { a, b }
        self.entries[a], self.entries[b] = self.entries[b], self.entries[a]
    end
    return menu
end

TestObjectMarkerCaptureFindLoc = {}

function TestObjectMarkerCaptureFindLoc:testPicksLastLocInReversedPriorityList()
    local under = locEntry({ locData = { config = { name = "Under" } }, subjectHash = 1 })
    local top = locEntry({ locData = { config = { name = "Top" } }, subjectHash = 2 })
    local found = ObjectMarkerCapture.FindLocEntry({ entries = { under, npcEntry(), top } })
    luaunit.assertEquals(found.locData.config.name, "Top")
    luaunit.assertEquals(found.subjectHash, 2)
end

function TestObjectMarkerCaptureFindLoc:testIgnoresNpcOnlyMenu()
    luaunit.assertNil(ObjectMarkerCapture.FindLocEntry({ entries = { npcEntry() } }))
end

function TestObjectMarkerCaptureFindLoc:testIgnoresNilMenu()
    luaunit.assertNil(ObjectMarkerCapture.FindLocEntry(nil))
end

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
    local o = ObjectMarkerCapture.Extract({
        subjectHash = 1,
        coordGridX = 10, coordGridZ = 20, locData = { config = { name = "Door" } },
    })
    luaunit.assertEquals(o.coordGrid.level, 0)
end

function TestObjectMarkerCaptureExtract:testReturnsNilWhenLocDataMissing()
    luaunit.assertNil(ObjectMarkerCapture.Extract({
        subjectHash = 1,
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
    local o = ObjectMarkerCapture.Extract({
        subjectHash = 7,
        locData = { config = { name = "Altar" }, coordGridX = 111, coordGridZ = 222, coordGridLevel = 2 },
    })
    luaunit.assertEquals(o.coordGrid.x, 111)
    luaunit.assertEquals(o.coordGrid.z, 222)
    luaunit.assertEquals(o.coordGrid.level, 2)
end

TestObjectMarkerCaptureFlow = {}

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

function TestObjectMarkerCaptureFlow:testArmSubscribesToMiniMenuReady()
    local capture, harness = armed()
    luaunit.assertTrue(capture:IsArmed())
    luaunit.assertEquals(harness:SubscribeCount("MiniMenuReady"), 1)
    luaunit.assertEquals(harness:SubscribeCount("MiniMenuEntrySelected"), 0)
end

function TestObjectMarkerCaptureFlow:testLocMenuAddsSelectObjectAndSwapsToIndex1()
    local _capture, harness = armed()
    local loc = locEntry()
    local menu = fakeMenu({ loc })
    harness:Push("MiniMenuReady", { miniMenu = menu })
    luaunit.assertEquals(menu.addCount, 1)
    luaunit.assertEquals(menu.lastAddName, "Select Object")
    luaunit.assertEquals(#menu.swaps, 1)
    luaunit.assertEquals(menu.swaps[1][1], 1)
    luaunit.assertEquals(menu.swaps[1][2], 2)
    luaunit.assertEquals(menu.entries[1].overrideText, "Select Object")
end

function TestObjectMarkerCaptureFlow:testReverseScanPicksTopLocForCallback()
    local _capture, harness, rec = armed()
    local under = locEntry({ locData = { config = { name = "Under" } }, subjectHash = 11 })
    local top = locEntry({ locData = { config = { name = "Top" } }, subjectHash = 22 })
    local menu = fakeMenu({ under, top })
    harness:Push("MiniMenuReady", { miniMenu = menu })
    menu.lastAddFn()
    luaunit.assertEquals(rec.count, 1)
    luaunit.assertEquals(rec.committed.name, "Top")
    luaunit.assertEquals(rec.committed.subjectHash, 22)
end

function TestObjectMarkerCaptureFlow:testNpcOnlyMenuDoesNotAdd()
    local _capture, harness = armed()
    local menu = fakeMenu({ npcEntry() })
    harness:Push("MiniMenuReady", { miniMenu = menu })
    luaunit.assertEquals(menu.addCount, 0)
    luaunit.assertEquals(#menu.swaps, 0)
end

function TestObjectMarkerCaptureFlow:testDisarmsAfterSuccessfulSelect()
    local capture, harness, rec = armed()
    local menu = fakeMenu({ locEntry() })
    harness:Push("MiniMenuReady", { miniMenu = menu })
    menu.lastAddFn()
    luaunit.assertFalse(capture:IsArmed())
    luaunit.assertEquals(rec.count, 1)
    menu.lastAddFn()
    luaunit.assertEquals(rec.count, 1)
end

function TestObjectMarkerCaptureFlow:testReadyAddsEveryTime()
    local _capture, harness = armed()
    local menu = fakeMenu({ locEntry() })
    harness:Push("MiniMenuReady", { miniMenu = menu })
    harness:Push("MiniMenuReady", { miniMenu = menu })
    luaunit.assertEquals(menu.addCount, 2)
end

function TestObjectMarkerCaptureFlow:testCancelDisarmsWithoutCommitting()
    local capture, harness, rec = armed()
    local menu = fakeMenu({ locEntry() })
    capture:Cancel()
    luaunit.assertFalse(capture:IsArmed())
    harness:Push("MiniMenuReady", { miniMenu = menu })
    luaunit.assertEquals(menu.addCount, 0)
    luaunit.assertEquals(rec.count, 0)
end

function TestObjectMarkerCaptureFlow:testCallbackWhileDisarmedIsIgnored()
    local capture, harness, rec = armed()
    local menu = fakeMenu({ locEntry() })
    harness:Push("MiniMenuReady", { miniMenu = menu })
    capture:Cancel()
    menu.lastAddFn()
    luaunit.assertEquals(rec.count, 0)
end

function TestObjectMarkerCaptureFlow:testReadyWhileDisarmedIsIgnored()
    local harness = newFakeEventSource()
    ObjectMarkerCapture.new(harness.source)
    local menu = fakeMenu({ locEntry() })
    local ok = pcall(function() harness:Push("MiniMenuReady", { miniMenu = menu }) end)
    luaunit.assertTrue(ok)
    luaunit.assertEquals(menu.addCount, 0)
end

function TestObjectMarkerCaptureFlow:testAcceptsBareMenuPayload()
    local _capture, harness = armed()
    local menu = fakeMenu({ locEntry() })
    harness:Push("MiniMenuReady", menu)
    luaunit.assertEquals(menu.addCount, 1)
end

return TestObjectMarkerCaptureFindLoc
