-- Object Marker MiniMenu capture (ui/object_marker_capture.lua) via a fake Event source.

local luaunit = require("luaunit")
local newFakeEventSource = require("fake_event_source")
local ObjectMarkerCapture = require("src/ui/object_marker_capture")

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
    local list = entries or {}
    local menu = {
        entries = list,
        entryCount = #list,
        addCount = 0,
        swaps = {},
        addNames = {},
        addFns = {},
    }
    function menu:Add(name, fn)
        self.addCount = self.addCount + 1
        self.lastAddName = name
        self.lastAddFn = fn
        self.addNames[#self.addNames + 1] = name
        self.addFns[#self.addFns + 1] = fn
        self.entries[#self.entries + 1] = { overrideText = name }
        self.entryCount = #self.entries
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

function TestObjectMarkerCaptureFindLoc:testFindLocEntriesDedupesProcessAndExamineOnSameLoc()
    local process = locEntry({
        subjectHash = 1,
        locData = { config = { id = 42, name = "Sawmill" } },
        subjectText = "<col=ffff00>Sawmill</col>",
    })
    local examine = locEntry({
        subjectHash = 2,
        locData = { config = { id = 42, name = "Sawmill" } },
        subjectText = "<col=ffff00>Sawmill</col>",
    })
    local locs = ObjectMarkerCapture.FindLocEntries({ entries = { process, examine } })
    luaunit.assertEquals(#locs, 1)
    luaunit.assertEquals(locs[1].subjectHash, 2)
end

function TestObjectMarkerCaptureFindLoc:testFindLocEntriesReturnsEveryLocInMenuOrder()
    local under = locEntry({ locData = { config = { name = "Under" } }, subjectHash = 1 })
    local top = locEntry({ locData = { config = { name = "Top" } }, subjectHash = 2 })
    local locs = ObjectMarkerCapture.FindLocEntries({ entries = { under, npcEntry(), top } })
    luaunit.assertEquals(#locs, 2)
    luaunit.assertEquals(locs[1].subjectHash, 1)
    luaunit.assertEquals(locs[2].subjectHash, 2)
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

-- Many LocType.name values are "" (Sawmill, Bank chest); MiniMenu subjectText is the label.
function TestObjectMarkerCaptureExtract:testEmptyConfigNameUsesSubjectText()
    local o = ObjectMarkerCapture.Extract({
        subjectHash = 1,
        subjectText = "Bank chest",
        locData = { config = { name = "" } },
    })
    luaunit.assertEquals(o.name, "Bank chest")
end

function TestObjectMarkerCaptureExtract:testPrefersSubjectTextOverConfigName()
    local o = ObjectMarkerCapture.Extract({
        subjectHash = 1,
        subjectText = "Sawmill",
        locData = { config = { name = "SAWMILL_INTERNAL" } },
    })
    luaunit.assertEquals(o.name, "Sawmill")
end

function TestObjectMarkerCaptureExtract:testFallsBackToConfigNameWhenDisplayBlank()
    local o = ObjectMarkerCapture.Extract({
        subjectHash = 1,
        subjectText = "",
        locData = { config = { name = "", configName = "WINCHLADDER1" } },
    })
    luaunit.assertEquals(o.name, "WINCHLADDER1")
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
    luaunit.assertEquals(menu.lastAddName, "Select Bank booth")
    luaunit.assertEquals(#menu.swaps, 1)
    luaunit.assertEquals(menu.swaps[1][1], 1)
    luaunit.assertEquals(menu.swaps[1][2], 2)
    luaunit.assertEquals(menu.entries[1].overrideText, "Select Bank booth")
end

function TestObjectMarkerCaptureFlow:testAddsSelectEntryPerLocKeepingTopFirst()
    local _capture, harness, rec = armed()
    local under = locEntry({
        locData = { config = { name = "Under" } }, subjectHash = 11, subjectText = "Under",
    })
    local top = locEntry({
        locData = { config = { name = "Top" } }, subjectHash = 22,
        subjectText = "<col=ffff00>Top</col>",
    })
    local menu = fakeMenu({ under, npcEntry(), top })
    harness:Push("MiniMenuReady", { miniMenu = menu })
    luaunit.assertEquals(menu.addCount, 2)
    luaunit.assertEquals(menu.addNames[1], "Select <col=ffff00>Top</col>")
    luaunit.assertEquals(menu.addNames[2], "Select Under")
    -- First Add is rotated via Swap(i,i+1); later Adds append after that Select.
    luaunit.assertEquals(menu.entries[3].overrideText, "Select <col=ffff00>Top</col>")
    luaunit.assertEquals(menu.entries[5].overrideText, "Select Under")
    menu.addFns[2]()
    luaunit.assertEquals(rec.committed.subjectHash, 11)
end

function TestObjectMarkerCaptureFlow:testOneSelectPerLocWhenMenuHasProcessAndExamine()
    local _capture, harness = armed()
    local process = locEntry({
        subjectHash = 1,
        locData = { config = { id = 99, name = "Sawmill" } },
        subjectText = "<col=ffff00>Sawmill</col>",
    })
    local examine = locEntry({
        subjectHash = 2,
        locData = { config = { id = 99, name = "Sawmill" } },
        subjectText = "<col=ffff00>Sawmill</col>",
    })
    local menu = fakeMenu({ process, examine })
    harness:Push("MiniMenuReady", { miniMenu = menu })
    luaunit.assertEquals(menu.addCount, 1)
    luaunit.assertEquals(menu.lastAddName, "Select <col=ffff00>Sawmill</col>")
    luaunit.assertEquals(menu.entries[2].overrideText, "Select <col=ffff00>Sawmill</col>")
end

function TestObjectMarkerCaptureFlow:testReverseScanPicksTopLocForCallback()
    local _capture, harness, rec = armed()
    local under = locEntry({ locData = { config = { name = "Under" } }, subjectHash = 11 })
    local top = locEntry({ locData = { config = { name = "Top" } }, subjectHash = 22 })
    local menu = fakeMenu({ under, top })
    harness:Push("MiniMenuReady", { miniMenu = menu })
    menu.addFns[1]()
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

-- Shell hide/restore (#14) is driven by armed transitions, not MiniMenu traffic.
function TestObjectMarkerCaptureFlow:testArmNotifiesOnArmedChangeTrue()
    local harness = newFakeEventSource()
    local capture = ObjectMarkerCapture.new(harness.source)
    local log = {}
    capture.onArmedChange = function(armed) log[#log + 1] = armed end
    capture:Arm("node1", "object", function() end)
    luaunit.assertEquals(log, { true })
end

function TestObjectMarkerCaptureFlow:testCancelNotifiesOnArmedChangeFalse()
    local capture = armed()
    local log = {}
    capture.onArmedChange = function(armed) log[#log + 1] = armed end
    capture:Cancel()
    luaunit.assertEquals(log, { false })
end

function TestObjectMarkerCaptureFlow:testSelectNotifiesDisarmBeforeCommit()
    local capture, harness, rec = armed()
    local log = {}
    capture.onArmedChange = function(armed)
        log[#log + 1] = armed
        -- Window must be restorable before the control write (editor still bound).
        luaunit.assertEquals(rec.count, 0)
    end
    local menu = fakeMenu({ locEntry() })
    harness:Push("MiniMenuReady", { miniMenu = menu })
    menu.lastAddFn()
    luaunit.assertEquals(log, { false })
    luaunit.assertEquals(rec.count, 1)
end

function TestObjectMarkerCaptureFlow:testReArmWhileArmedDoesNotRenotify()
    local capture = armed()
    local log = {}
    capture.onArmedChange = function(armed) log[#log + 1] = armed end
    capture:Arm("node1", "object", function() end)
    luaunit.assertEquals(#log, 0)
    luaunit.assertTrue(capture:IsArmed())
end

function TestObjectMarkerCaptureFlow:testCancelWhileDisarmedDoesNotNotify()
    local harness = newFakeEventSource()
    local capture = ObjectMarkerCapture.new(harness.source)
    local log = {}
    capture.onArmedChange = function(armed) log[#log + 1] = armed end
    capture:Cancel()
    luaunit.assertEquals(#log, 0)
end

return TestObjectMarkerCaptureFindLoc
