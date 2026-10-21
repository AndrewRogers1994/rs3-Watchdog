-- Pack sound effects on the Sound Effect node. The registry is the seam:
-- row labels, closed labels, commit results, the open-list snapshot, and
-- play resolution. No PrettyUI, and no peeking at the registry's tables.

local luaunit = require("luaunit")
local Packs = require("src/packs")

local function labelsOf(rows)
    local labels = {}
    for _, row in ipairs(rows) do
        labels[#labels + 1] = row.label
    end
    table.sort(labels)
    return labels
end

TestPackSoundRows = {}

function TestPackSoundRows:setUp()
    self.packs = Packs.new()
end

function TestPackSoundRows:testRowLabelIsPackNameThenLabel()
    self.packs:RegisterDataPack("VoicePack", {
        soundEffects = {
            { authorId = "greet_01", label = "Hello", soundId = 12345 },
        },
    })
    local rows = self.packs:SoundEffectRows()
    luaunit.assertEquals(#rows, 1)
    luaunit.assertEquals(rows[1].label, "VoicePack / Hello")
    luaunit.assertEquals(rows[1].pack, "VoicePack")
    luaunit.assertEquals(rows[1].authorId, "greet_01")
    luaunit.assertEquals(rows[1].soundId, 12345)
end

function TestPackSoundRows:testRepeatedLabelInsideOnePackShowsTheAuthorId()
    self.packs:RegisterDataPack("VoicePack", {
        soundEffects = {
            { authorId = "greet_01", label = "Hello", soundId = 1 },
            { authorId = "greet_02", label = "Hello", soundId = 2 },
            { authorId = "bye", label = "Bye", soundId = 3 },
        },
    })
    luaunit.assertEquals(labelsOf(self.packs:SoundEffectRows()), {
        "VoicePack / Bye",
        "VoicePack / Hello (greet_01)",
        "VoicePack / Hello (greet_02)",
    })
end

function TestPackSoundRows:testSameLabelInTwoPacksStaysPackNameThenLabel()
    self.packs:RegisterDataPack("Voice", {
        soundEffects = { { authorId = "bell", label = "Bell", soundId = 1 } },
    })
    self.packs:RegisterDataPack("Other", {
        soundEffects = { { authorId = "bell", label = "Bell", soundId = 2 } },
    })
    luaunit.assertEquals(labelsOf(self.packs:SoundEffectRows()), {
        "Other / Bell",
        "Voice / Bell",
    })
end

TestPackSoundClosedLabel = {}

function TestPackSoundClosedLabel:setUp()
    self.packs = Packs.new()
end

function TestPackSoundClosedLabel:testLiveOfferShowsTheLiveLabel()
    self.packs:RegisterDataPack("VoicePack", {
        soundEffects = {
            { authorId = "greet_01", label = "Hello", soundId = 12345 },
        },
    })
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    luaunit.assertEquals(self.packs:SoundEffectClosedLabel(stored), "Hello")
end

function TestPackSoundClosedLabel:testOutdatedBuiltinSoundIdMarksTheLiveLabel()
    self.packs:RegisterDataPack("VoicePack", {
        soundEffects = {
            { authorId = "greet_01", label = "Hello", soundId = 999 },
        },
    })
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    luaunit.assertEquals(self.packs:SoundEffectClosedLabel(stored), "Hello (outdated)")
end

function TestPackSoundClosedLabel:testADifferentPackHoldingTheNameCanBeOutdated()
    local token = self.packs:RegisterDataPack("VoicePack", {
        soundEffects = {
            { authorId = "greet_01", label = "Hello", soundId = 12345 },
        },
    })
    self.packs:Clear(token)
    self.packs:RegisterDataPack("VoicePack", {
        soundEffects = {
            { authorId = "greet_01", label = "Welcome", soundId = 999 },
        },
    })
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    luaunit.assertEquals(self.packs:SoundEffectClosedLabel(stored), "Welcome (outdated)")
end

function TestPackSoundClosedLabel:testMissingOfferShowsSoundIdPackAndAuthorId()
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    luaunit.assertEquals(self.packs:SoundEffectClosedLabel(stored), "12345 (VoicePack / greet_01)")
end

function TestPackSoundClosedLabel:testMissingAuthorIdShowsTheSameMissingText()
    self.packs:RegisterDataPack("VoicePack", {
        soundEffects = {
            { authorId = "other", label = "Hello", soundId = 12345 },
        },
    })
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    luaunit.assertEquals(self.packs:SoundEffectClosedLabel(stored), "12345 (VoicePack / greet_01)")
end

function TestPackSoundClosedLabel:testRawBuiltinSoundIdShowsTheNumberAlone()
    self.packs:RegisterDataPack("VoicePack", {
        soundEffects = {
            { authorId = "greet_01", label = "Hello", soundId = 12345 },
        },
    })
    luaunit.assertEquals(self.packs:SoundEffectClosedLabel(12345), "12345")
end

TestPackSoundCommit = {}

function TestPackSoundCommit:setUp()
    self.packs = Packs.new()
end

function TestPackSoundCommit:testCommittingARowStoresThatRowsPackRecordAfterThePackClears()
    local token = self.packs:RegisterDataPack("VoicePack", {
        soundEffects = {
            { authorId = "greet_01", label = "Hello", soundId = 12345 },
        },
    })
    local rows = self.packs:SoundEffectRows()
    self.packs:Clear(token)
    local stored = self.packs:CommitSoundEffect(nil, "row", rows[1])
    luaunit.assertEquals(stored, { pack = "VoicePack", authorId = "greet_01", soundId = 12345 })
end

function TestPackSoundCommit:testADifferentNumberClearsThePackRecord()
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    luaunit.assertEquals(self.packs:CommitSoundEffect(stored, "number", 99), 99)
end

function TestPackSoundCommit:testTheSameNumberLeavesThePackRecordInPlace()
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    luaunit.assertIs(self.packs:CommitSoundEffect(stored, "number", 12345), stored)
end

function TestPackSoundCommit:testHighlightIsNotACommit()
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    local row = { pack = "Other", authorId = "bell", soundId = 7, label = "Other / Bell" }
    luaunit.assertIs(self.packs:CommitSoundEffect(stored, "highlight", row), stored)
end

function TestPackSoundCommit:testDismissingLeavesTheStoredValueUnchanged()
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    luaunit.assertIs(self.packs:CommitSoundEffect(stored, "dismiss", nil), stored)
end

function TestPackSoundCommit:testAStoredIdentityWithNoMatchingRowStaysUntilARealCommit()
    self.packs:RegisterDataPack("VoicePack", {
        soundEffects = {
            { authorId = "other", label = "Hello", soundId = 12345 },
        },
    })
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    local rows = self.packs:SoundEffectRows()
    luaunit.assertNil(self.packs:SoundEffectSelectedRow(rows, stored))
    luaunit.assertIs(self.packs:CommitSoundEffect(stored, "dismiss", nil), stored)
    luaunit.assertIs(self.packs:CommitSoundEffect(stored, "number", 12345), stored)
    luaunit.assertEquals(self.packs:CommitSoundEffect(stored, "number", 50), 50)
    luaunit.assertEquals(self.packs:CommitSoundEffect(stored, "row", rows[1]), {
        pack = "VoicePack", authorId = "other", soundId = 12345,
    })
end

TestPackSoundOpenList = {}

function TestPackSoundOpenList:setUp()
    self.packs = Packs.new()
end

function TestPackSoundOpenList:testTheOpenListKeepsItsRowsUntilTheNextOpen()
    local token = self.packs:RegisterDataPack("VoicePack", {
        soundEffects = {
            { authorId = "greet_01", label = "Hello", soundId = 12345 },
        },
    })
    local opened = self.packs:SoundEffectRows()
    self.packs:Clear(token)
    self.packs:RegisterDataPack("VoicePack", {
        soundEffects = {
            { authorId = "greet_01", label = "Welcome", soundId = 999 },
        },
    })
    luaunit.assertEquals(opened[1].label, "VoicePack / Hello")
    luaunit.assertEquals(opened[1].soundId, 12345)
    local again = self.packs:SoundEffectRows()
    luaunit.assertEquals(#again, 1)
    luaunit.assertEquals(again[1].label, "VoicePack / Welcome")
    luaunit.assertEquals(again[1].soundId, 999)
end

function TestPackSoundOpenList:testTheSelectedRowIsTheStoredPackAndAuthorId()
    self.packs:RegisterDataPack("VoicePack", {
        soundEffects = {
            { authorId = "greet_01", label = "Hello", soundId = 12345 },
            { authorId = "greet_02", label = "Hello", soundId = 12345 },
        },
    })
    local rows = self.packs:SoundEffectRows()
    local stored = { pack = "VoicePack", authorId = "greet_02", soundId = 1 }
    local index = self.packs:SoundEffectSelectedRow(rows, stored)
    luaunit.assertNotNil(index)
    luaunit.assertEquals(rows[index].pack, "VoicePack")
    luaunit.assertEquals(rows[index].authorId, "greet_02")
end

function TestPackSoundOpenList:testARawNumberDoesNotSelectARowWithTheSameSoundId()
    self.packs:RegisterDataPack("VoicePack", {
        soundEffects = {
            { authorId = "greet_01", label = "Hello", soundId = 12345 },
        },
    })
    luaunit.assertNil(self.packs:SoundEffectSelectedRow(self.packs:SoundEffectRows(), 12345))
end

function TestPackSoundOpenList:testChoosingTheOfferAgainStoresTheSoundIdItOffersNow()
    self.packs:RegisterDataPack("VoicePack", {
        soundEffects = {
            { authorId = "greet_01", label = "Hello", soundId = 999 },
        },
    })
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    local rows = self.packs:SoundEffectRows()
    local index = self.packs:SoundEffectSelectedRow(rows, stored)
    local committed = self.packs:CommitSoundEffect(stored, "row", rows[index])
    luaunit.assertEquals(committed, { pack = "VoicePack", authorId = "greet_01", soundId = 999 })
    luaunit.assertEquals(self.packs:SoundEffectClosedLabel(committed), "Hello")
end

TestPackSoundPlay = {}

function TestPackSoundPlay:setUp()
    self.packs = Packs.new()
end

function TestPackSoundPlay:testARawNumberSavedBeforeThisContractResolvesToThatNumber()
    luaunit.assertEquals(self.packs:ResolveSoundEffect(2608), 2608)
end

function TestPackSoundPlay:testAPackRecordResolvesToItsStoredBuiltinSoundId()
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    luaunit.assertEquals(self.packs:ResolveSoundEffect(stored), 12345)
end

function TestPackSoundPlay:testAMissingPackStillResolvesToTheStoredBuiltinSoundId()
    local token = self.packs:RegisterDataPack("VoicePack", {
        soundEffects = {
            { authorId = "greet_01", label = "Hello", soundId = 12345 },
        },
    })
    self.packs:Clear(token)
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    luaunit.assertNil(self.packs:GetSoundEffect("VoicePack", "greet_01"))
    luaunit.assertEquals(self.packs:ResolveSoundEffect(stored), 12345)
end

function TestPackSoundPlay:testAnOutdatedBuiltinSoundIdStillResolvesToTheStoredOne()
    self.packs:RegisterDataPack("VoicePack", {
        soundEffects = {
            { authorId = "greet_01", label = "Hello", soundId = 999 },
        },
    })
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    luaunit.assertEquals(self.packs:ResolveSoundEffect(stored), 12345)
end

function TestPackSoundPlay:testAValueThatIsNeitherANumberNorAPackRecordIsSilent()
    luaunit.assertNil(self.packs:ResolveSoundEffect("nope"))
    luaunit.assertNil(self.packs:ResolveSoundEffect(nil))
    luaunit.assertNil(self.packs:ResolveSoundEffect({ soundId = 12345 }))
    luaunit.assertNil(self.packs:ResolveSoundEffect({ pack = "VoicePack", authorId = "greet_01" }))
end

-- PersistentDB stores the serialized graph as JSON. Serialize/Deserialize alone
-- would keep the same table; the JSON step is what an old Alert actually survives.
TestPackSoundRoundTrip = {}

function TestPackSoundRoundTrip:setUp()
    _G.id = _G.id or {}
    _G.id.Sound = _G.id.Sound or { TOWN_CRIER_BELL_RING_1 = 2608 }
    local Registry = require("registry")
    local Sound = require("src/nodes/actions/sound")
    self.registry = Registry.new()
    Sound.Register(self.registry)
    self.Graph = require("graph")
    self.Serialize = require("serialize")
    self.Json = require("json")
end

function TestPackSoundRoundTrip:restore(soundId)
    local graph = self.Graph.new(self.registry)
    local id = graph:AddNode("action.sound", { soundId = soundId })
    local encoded = self.Json.Default.encode(self.Serialize.Serialize(graph))
    local restored = self.Serialize.Deserialize(self.Json.Default.decode(encoded), self.registry)
    return restored:GetControl(id, "soundId")
end

function TestPackSoundRoundTrip:testARawNumberRoundTrips()
    luaunit.assertEquals(self:restore(2608), 2608)
end

function TestPackSoundRoundTrip:testAPackRecordRoundTrips()
    luaunit.assertEquals(self:restore({
        pack = "VoicePack", authorId = "greet_01", soundId = 12345,
    }), {
        pack = "VoicePack", authorId = "greet_01", soundId = 12345,
    })
end

TestPackSoundControl = {}

function TestPackSoundControl:setUp()
    self.packs = Packs.new()
    Packs.install(self.packs)
    self.token = self.packs:RegisterDataPack("VoicePack", {
        soundEffects = {
            { authorId = "greet_01", label = "Hello", soundId = 12345 },
        },
    })
    local Controls = require("src/ui/controls")
    self.control = Controls.PinControlFor("number")
    self.FakeHost = require("fake_control_host")
end

function TestPackSoundControl:tearDown()
    Packs.install(nil)
end

function TestPackSoundControl:testClosedControlShowsTheLiveLabel()
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    local text = self.control.Display({ pinName = "soundId", value = stored })
    luaunit.assertEquals(text, "Hello")
end

function TestPackSoundControl:testOpenPassesTheSnapshotAndTheStoredSoundId()
    local host = self.FakeHost.new(12345)
    self.control.Press(host, { pinName = "soundId", value = 12345 })
    luaunit.assertEquals(host.mounted.kind, "dropdown")
    luaunit.assertEquals(host.mounted.opts.labels, { "VoicePack / Hello" })
    luaunit.assertNil(host.mounted.opts.initial)
    luaunit.assertEquals(host.mounted.opts.number, 12345)
    luaunit.assertEquals(host.commitCount, 0)
end

function TestPackSoundControl:testChoosingARowStoresTheSnapshotRecord()
    local stored = { pack = "Gone", authorId = "old", soundId = 1 }
    local host = self.FakeHost.new(stored)
    self.control.Press(host, { pinName = "soundId", value = stored })
    self.packs:Clear(self.token)
    host:Pick("VoicePack / Hello")
    luaunit.assertEquals(host.committed, {
        pack = "VoicePack", authorId = "greet_01", soundId = 12345,
    })
end

function TestPackSoundControl:testSubmittingADifferentNumberClearsThePackRecord()
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    local host = self.FakeHost.new(stored)
    self.control.Press(host, { pinName = "soundId", value = stored })
    host.mounted.opts.onNumber("99", 99)
    luaunit.assertEquals(host.committed, 99)
end

return {}
