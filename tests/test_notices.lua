-- Seen-set, catalog diff, and the show/hold policy.

local luaunit = require("luaunit")
local Notices = require("src/notices")
local Multiplexer = require("src/ui/multiplexer")

local Json = require("json")
if LibNodeGraph == nil then
    LibNodeGraph = { Json = Json }
elseif LibNodeGraph.Json == nil then
    LibNodeGraph.Json = Json
end

TestNotices = {}

function TestNotices:setUp()
    self._log = log
    self.savedPersistentDB = PersistentDB
    self.db = { data = {}, failSet = false }
    function self.db:GetString(key)
        return self.data[key]
    end
    function self.db:SetString(key, value)
        if self.failSet then error("set failed") end
        self.data[key] = value
    end
    PersistentDB = self.db
    self.catalog = {
        { version = "1.0.0", paragraphs = { "First note." } },
        { version = "1.1.0", paragraphs = { "Second note.", "Still the second." } },
    }
end

function TestNotices:tearDown()
    _G.log = self._log
    PersistentDB = self.savedPersistentDB
end

---@param catalog Watchdog.ReleaseNote[]|nil
---@return Watchdog.Notices
function TestNotices:open(catalog)
    return Notices.new({ catalog = catalog or {} })
end

function TestNotices:testUnseenVersionsAreNewestFirst()
    local releases = Notices.UnseenReleases(self.catalog, {})
    luaunit.assertEquals(#releases, 2)
    luaunit.assertEquals(releases[1].id, "release:1.1.0")
    luaunit.assertEquals(releases[1].version, "1.1.0")
    luaunit.assertEquals(releases[1].paragraphs, { "Second note.", "Still the second." })
    luaunit.assertEquals(releases[2].id, "release:1.0.0")
end

function TestNotices:testDismissRecordsShownIdsAndLeavesAlreadySeen()
    self.db.data[Notices.KEY] = Json.Default.encode({ "release:1.0.0", "release:0.9.0" })
    local n = self:open(self.catalog)
    local offer = n:OnWindowOpen({ editorTop = false, dialogOpen = false })
    luaunit.assertEquals(offer.kind, "whats-new")
    luaunit.assertEquals(offer.ids, { "release:1.1.0" })
    luaunit.assertTrue(n:MarkSeen(offer.ids))

    luaunit.assertEquals(#Notices.UnseenReleases(self.catalog, n.seen), 0)
    luaunit.assertTrue(n.seen["release:1.0.0"])
    luaunit.assertTrue(n.seen["release:0.9.0"])
    luaunit.assertTrue(n.seen["release:1.1.0"])
    luaunit.assertNil(n.seen[Notices.TIPS_ID])

    local reloaded = self:open(self.catalog)
    luaunit.assertNil(reloaded:OnWindowOpen({ editorTop = false, dialogOpen = false }))
    luaunit.assertTrue(reloaded.seen["release:0.9.0"])
    luaunit.assertTrue(reloaded.seen["release:1.0.0"])
    luaunit.assertTrue(reloaded.seen["release:1.1.0"])
    luaunit.assertNil(reloaded.seen[Notices.TIPS_ID])
end

function TestNotices:testVersionAbsentFromCatalogIsNotDue()
    local seen = { ["release:9.9.9"] = true }
    local releases = Notices.UnseenReleases(self.catalog, seen)
    luaunit.assertEquals(#releases, 2)
    for _, entry in ipairs(releases) do
        luaunit.assertNotEquals(entry.version, "9.9.9")
    end
    local onlyOld = Notices.UnseenReleases({
        { version = "1.0.0", paragraphs = { "First note." } },
    }, seen)
    luaunit.assertEquals(onlyOld[1].version, "1.0.0")
    luaunit.assertNil(onlyOld[2])
end

function TestNotices:testEditorTipsAreIndependentOfReleaseIds()
    local n = self:open(self.catalog)
    luaunit.assertTrue(n:MarkSeen({ "release:1.0.0", "release:1.1.0" }))
    luaunit.assertNil(n.seen[Notices.TIPS_ID])
    local tips = n:OnWindowOpen({ editorTop = true, dialogOpen = false })
    luaunit.assertEquals(tips.kind, "getting-started")
    luaunit.assertEquals(tips.ids, { Notices.TIPS_ID })

    local fresh = self:open({
        { version = "1.0.0", paragraphs = { "First note." } },
        { version = "1.2.0", paragraphs = { "Later." } },
    })
    luaunit.assertTrue(fresh:MarkSeen({ Notices.TIPS_ID }))
    local notes = fresh:OnWindowOpen({ editorTop = true, dialogOpen = false })
    luaunit.assertEquals(notes.kind, "whats-new")
    luaunit.assertEquals(notes.ids, { "release:1.2.0" })
    luaunit.assertTrue(fresh.seen[Notices.TIPS_ID])
end

function TestNotices:testEmptyCatalogMeansReleaseIsNotDue()
    luaunit.assertEquals(#Notices.UnseenReleases({}, {}), 0)
    local n = self:open({})
    luaunit.assertNil(n:OnWindowOpen({ editorTop = false, dialogOpen = false }))
end

function TestNotices:testWindowOpenBothDueEditorTopShowsReleaseAndHolds()
    local n = self:open(self.catalog)
    local offer = n:OnWindowOpen({ editorTop = true, dialogOpen = false })
    luaunit.assertEquals(offer.kind, "whats-new")
    luaunit.assertEquals(offer.ids, { "release:1.1.0", "release:1.0.0" })
    luaunit.assertTrue(n.hold)
    luaunit.assertNil(n.seen[Notices.TIPS_ID])
end

function TestNotices:testWindowOpenEditorTopNoReleaseShowsTips()
    local n = self:open({})
    luaunit.assertFalse(n.hold)
    local offer = n:OnWindowOpen({ editorTop = true, dialogOpen = false })
    luaunit.assertEquals(offer.kind, "getting-started")
    luaunit.assertEquals(offer.ids, { Notices.TIPS_ID })
end

function TestNotices:testWindowOpenEditorTopWhileHeldShowsNothing()
    local n = self:open(self.catalog)
    local first = n:OnWindowOpen({ editorTop = true, dialogOpen = false })
    luaunit.assertTrue(n:MarkSeen(first.ids))
    luaunit.assertTrue(n.hold)
    luaunit.assertNil(n:OnWindowOpen({ editorTop = true, dialogOpen = false }))
    luaunit.assertTrue(n.hold)
    luaunit.assertNil(n.seen[Notices.TIPS_ID])
end

function TestNotices:testDismissingReleaseDoesNotOfferTips()
    local n = self:open(self.catalog)
    local offer = n:OnWindowOpen({ editorTop = true, dialogOpen = false })
    luaunit.assertEquals(offer.kind, "whats-new")
    luaunit.assertTrue(n:MarkSeen(offer.ids))
    luaunit.assertNil(n:OnWindowOpen({ editorTop = true, dialogOpen = false }))
end

function TestNotices:testEditorEntryWhileShellOpenShowsTips()
    local n = self:open({})
    local offer = n:OnOpenAlert(true, { dialogOpen = false })
    luaunit.assertEquals(offer.kind, "getting-started")
    luaunit.assertEquals(offer.ids, { Notices.TIPS_ID })
end

function TestNotices:testEditorEntryWhileNoticeOpenShowsNothing()
    local n = self:open({})
    luaunit.assertNil(n:OnOpenAlert(true, { dialogOpen = true }))
    luaunit.assertNil(n.seen[Notices.TIPS_ID])
end

function TestNotices:testEditorEntryDoesNotShowReleaseNotes()
    local n = self:open(self.catalog)
    local offer = n:OnOpenAlert(true, { dialogOpen = false })
    luaunit.assertEquals(offer.kind, "getting-started")
end

function TestNotices:testOpenAlertWhileShellHiddenIsNotAnEditorEntry()
    local n = self:open(self.catalog)
    luaunit.assertNil(n:OnOpenAlert(false, { dialogOpen = false }))
    luaunit.assertFalse(n.hold)
    local offer = n:OnWindowOpen({ editorTop = true, dialogOpen = false })
    luaunit.assertEquals(offer.kind, "whats-new")
    luaunit.assertTrue(n.hold)
end

function TestNotices:testWindowOpenOnAlertsListClearsHold()
    local n = self:open(self.catalog)
    n:OnWindowOpen({ editorTop = true, dialogOpen = false })
    luaunit.assertTrue(n:MarkSeen({ "release:1.0.0", "release:1.1.0" }))
    luaunit.assertTrue(n.hold)
    luaunit.assertNil(n:OnWindowOpen({ editorTop = false, dialogOpen = false }))
    luaunit.assertFalse(n.hold)
end

function TestNotices:testNavBackClearsHold()
    local n = self:open(self.catalog)
    n:OnWindowOpen({ editorTop = true, dialogOpen = false })
    luaunit.assertTrue(n.hold)
    n:OnNavBack()
    luaunit.assertFalse(n.hold)
end

function TestNotices:testWindowOpenWhileDialogOpenWaitsAndDoesNotHold()
    local n = self:open(self.catalog)
    luaunit.assertNil(n:OnWindowOpen({ editorTop = true, dialogOpen = true }))
    luaunit.assertFalse(n.hold)
    luaunit.assertNil(n.seen["release:1.1.0"])
end

function TestNotices:testFailedSaveSuppressesUntilReload()
    local logged = {}
    local previous = log
    _G.log = function(message) logged[#logged + 1] = message end
    local n = Notices.new({ catalog = {} })
    self.db.failSet = true
    luaunit.assertFalse(n:MarkSeen({ Notices.TIPS_ID }))
    luaunit.assertTrue(n.seen[Notices.TIPS_ID] == true)
    luaunit.assertNil(self.db.data[Notices.KEY])
    luaunit.assertNil(n:OnWindowOpen({ editorTop = true, dialogOpen = false }))
    luaunit.assertTrue(#logged >= 1)

    self.db.failSet = false
    local reloaded = self:open({})
    local offer = reloaded:OnWindowOpen({ editorTop = true, dialogOpen = false })
    luaunit.assertEquals(offer.kind, "getting-started")
end

function TestNotices:testResetWritesEmptyListBeforeAnyOpen()
    self.db.data[Notices.KEY] = Json.Default.encode({ "release:1.0.0", Notices.TIPS_ID })
    local n = self:open(self.catalog)
    n:ResetAllPopups()
    luaunit.assertNil(n.seen["release:1.0.0"])
    luaunit.assertNil(n.seen[Notices.TIPS_ID])
    luaunit.assertEquals(self.db.data[Notices.KEY], "[]")
    local offer = n:OnWindowOpen({ editorTop = false, dialogOpen = false })
    luaunit.assertEquals(offer.kind, "whats-new")
    luaunit.assertEquals(offer.ids, { "release:1.1.0", "release:1.0.0" })
end

function TestNotices:testSharedUsesTheShippedCatalog()
    luaunit.assertEquals(Notices.shared.catalog, require("src/release_notes"))
    luaunit.assertTrue(Notices.shared ~= self:open(self.catalog))
end

function TestNotices:testUnreadableSeenListIsNotOverwritten()
    self.db.data[Notices.KEY] = "{not-json"
    local n = self:open({})
    luaunit.assertFalse(n:MarkSeen({ Notices.TIPS_ID }))
    luaunit.assertEquals(self.db.data[Notices.KEY], "{not-json")
    luaunit.assertTrue(n.seen[Notices.TIPS_ID] == true)
    luaunit.assertNil(n:OnWindowOpen({ editorTop = true, dialogOpen = false }))
end

function TestNotices:testImageParagraphsPassThrough()
    local image = { image = "releases/tutorial", width = 893, height = 554 }
    local releases = Notices.UnseenReleases({
        { version = "1.0.0", paragraphs = { "Hello.", image } },
    }, {})
    luaunit.assertEquals(releases[1].paragraphs[2], image)
end

function TestNotices:testGettingStartedParagraphs()
    local tips = require("src/ui/editor_tips")
    luaunit.assertEquals(tips.paragraphs, {
        "An alert is a trigger wired to an action.",
        "Double-click empty space, or click +, to add a node.",
        "The alert runs only while it is enabled in the alert list.",
        "The info button opens the full Tutorial.",
    })
end

-- Capture restore must not look like a window open. The policy has no capture
-- event; Multiplexer:RestoreFromCapture skips onShow.
function TestNotices:testCaptureRestoreDoesNotCallOnShow()
    local shows = 0
    local win = {
        Show = function() end,
        Close = function(self)
            if self.onClose ~= nil then self.onClose(self) end
        end,
        SetTitle = function() end,
        Destroy = function() end,
        MoveToFront = function() end,
        onClose = nil,
    }
    local mux = Multiplexer.new({
        window = win,
        overlay = {},
        onShow = function() shows = shows + 1 end,
    })
    mux:Push({
        id = "editor",
        title = "Editor",
        SetVisible = function() end,
    })
    mux:SetVisible(true)
    luaunit.assertEquals(shows, 1)
    mux:HideForCapture()
    luaunit.assertEquals(shows, 1)
    mux:RestoreFromCapture()
    luaunit.assertEquals(shows, 1)
    luaunit.assertTrue(mux:IsVisible())
    mux:SetVisible(false)
    mux:SetVisible(true)
    luaunit.assertEquals(shows, 2)
end
