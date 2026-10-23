-- Pack sound effects on the Sound Effect node. Rows, closed text, and which
-- row matches a stored pack sound effect are the row builder. The test passes
-- the registry it built. Play resolution stays on the Pack registry.
-- What a Sound Effect Control stores is tested on SoundEffectValue.
-- No PrettyUI, and no peeking at the registry's tables.

local luaunit = require("luaunit")
local Packs = require("src/packs")
local PackRows = require("src/pack_rows")
local Theme = require("src/ui/theme")

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
    local rows = PackRows.SoundEffectRows(self.packs)
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
    luaunit.assertEquals(labelsOf(PackRows.SoundEffectRows(self.packs)), {
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
    luaunit.assertEquals(labelsOf(PackRows.SoundEffectRows(self.packs)), {
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
    luaunit.assertEquals(PackRows.SoundEffectClosedLabel(self.packs, stored), "VoicePack / Hello")
end

function TestPackSoundClosedLabel:testARepeatedLabelUsesTheOpenRowText()
    self.packs:RegisterDataPack("VoicePack", {
        soundEffects = {
            { authorId = "greet_01", label = "Hello", soundId = 1 },
            { authorId = "greet_02", label = "Hello", soundId = 2 },
        },
    })
    luaunit.assertEquals(
        PackRows.SoundEffectClosedLabel(self.packs, { pack = "VoicePack", authorId = "greet_01", soundId = 1 }),
        "VoicePack / Hello (greet_01)")
    luaunit.assertEquals(
        PackRows.SoundEffectClosedLabel(self.packs, { pack = "VoicePack", authorId = "greet_02", soundId = 9 }),
        "VoicePack / Hello (greet_02) (outdated)")
end

function TestPackSoundClosedLabel:testOutdatedBuiltinSoundIdMarksTheLiveLabel()
    self.packs:RegisterDataPack("VoicePack", {
        soundEffects = {
            { authorId = "greet_01", label = "Hello", soundId = 999 },
        },
    })
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    luaunit.assertEquals(PackRows.SoundEffectClosedLabel(self.packs, stored), "VoicePack / Hello (outdated)")
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
    luaunit.assertEquals(PackRows.SoundEffectClosedLabel(self.packs, stored), "VoicePack / Welcome (outdated)")
end

function TestPackSoundClosedLabel:testMissingOfferShowsSoundIdPackAndAuthorId()
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    luaunit.assertEquals(PackRows.SoundEffectClosedLabel(self.packs, stored), "12345 (VoicePack / greet_01)")
end

function TestPackSoundClosedLabel:testMissingAuthorIdShowsTheSameMissingText()
    self.packs:RegisterDataPack("VoicePack", {
        soundEffects = {
            { authorId = "other", label = "Hello", soundId = 12345 },
        },
    })
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    luaunit.assertEquals(PackRows.SoundEffectClosedLabel(self.packs, stored), "12345 (VoicePack / greet_01)")
end

function TestPackSoundClosedLabel:testRawBuiltinSoundIdShowsTheNumberAlone()
    self.packs:RegisterDataPack("VoicePack", {
        soundEffects = {
            { authorId = "greet_01", label = "Hello", soundId = 12345 },
        },
    })
    luaunit.assertEquals(PackRows.SoundEffectClosedLabel(self.packs, 12345), "12345")
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
    local opened = PackRows.SoundEffectRows(self.packs)
    self.packs:Clear(token)
    self.packs:RegisterDataPack("VoicePack", {
        soundEffects = {
            { authorId = "greet_01", label = "Welcome", soundId = 999 },
        },
    })
    luaunit.assertEquals(opened[1].label, "VoicePack / Hello")
    luaunit.assertEquals(opened[1].soundId, 12345)
    local again = PackRows.SoundEffectRows(self.packs)
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
    local rows = PackRows.SoundEffectRows(self.packs)
    local stored = { pack = "VoicePack", authorId = "greet_02", soundId = 1 }
    local index = PackRows.SoundEffectSelectedRow(rows, stored)
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
    luaunit.assertNil(PackRows.SoundEffectSelectedRow(PackRows.SoundEffectRows(self.packs), 12345))
end

function TestPackSoundOpenList:testAStoredPackAndAuthorIdWithNoOfferSelectsNothing()
    self.packs:RegisterDataPack("VoicePack", {
        soundEffects = {
            { authorId = "other", label = "Hello", soundId = 12345 },
        },
    })
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    luaunit.assertNil(PackRows.SoundEffectSelectedRow(PackRows.SoundEffectRows(self.packs), stored))
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
    _G.id = _G.id or {}
    _G.id.Sound = _G.id.Sound or { TOWN_CRIER_BELL_RING_1 = 2608 }
    require("src/nodes/actions/sound")
    self.packs = Packs.new()
    Packs.install(self.packs)
    self.token = self.packs:RegisterDataPack("VoicePack", {
        soundEffects = {
            { authorId = "greet_01", label = "Hello", soundId = 12345 },
        },
    })
    local Controls = require("src/ui/controls")
    self.control = Controls.PinControlForPin("action.sound", {
        name = "soundId", dataType = "number",
    })
    self.FakeHost = require("fake_control_host")
end

function TestPackSoundControl:tearDown()
    Packs.install(nil)
end

function TestPackSoundControl:testNumberLineShowsTheBuiltinId()
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    luaunit.assertEquals(self.control.Display({ kind = "number", value = stored }), "12345")
    luaunit.assertEquals(self.control.Display({ kind = "number", value = 50 }), "50")
end

function TestPackSoundControl:testPackLineShowsTheLiveLabel()
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    luaunit.assertEquals(
        self.control.Display({ kind = "pack", value = stored }), "VoicePack / Hello")
end

function TestPackSoundControl:testPackLineIsEmptyForARawNumber()
    luaunit.assertEquals(self.control.Display({ kind = "pack", value = 12345 }), "")
end

function TestPackSoundControl:testAnEmptyPackListKeepsTheRowAndDoesNotOpen()
    self.packs:Clear(self.token)
    luaunit.assertFalse(self.control.HasPackRows())
    luaunit.assertEquals(self.control.ReservedHeight(), Theme.SOUND_BAND_H)
    local rects = self.control.Layout({ x = 0, y = 0, w = 100, h = Theme.SOUND_BAND_H })
    luaunit.assertEquals(rects[2].placeholder, self.control.EMPTY_PACK)
    luaunit.assertEquals(self.control.Display({ kind = "pack", value = 12345 }), "")
    local host = self.FakeHost.new(12345)
    self.control.Press(host, { kind = "pack", value = 12345 })
    luaunit.assertNil(host.mounted)
    luaunit.assertEquals(host.commitCount, 0)
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    luaunit.assertEquals(
        self.control.Display({ kind = "pack", value = stored }),
        "12345 (VoicePack / greet_01)")
end

function TestPackSoundControl:testOpeningThePackLinePassesTheSnapshot()
    local host = self.FakeHost.new(12345)
    self.control.Press(host, { kind = "pack", pinName = "soundId", value = 12345 })
    luaunit.assertEquals(host.mounted.kind, "dropdown")
    luaunit.assertEquals(host.mounted.opts.labels, { "VoicePack / Hello" })
    luaunit.assertNil(host.mounted.opts.initial)
    luaunit.assertNil(host.mounted.opts.number)
    luaunit.assertNil(host.mounted.opts.openLayout)
    luaunit.assertEquals(host.commitCount, 0)
end

function TestPackSoundControl:testChoosingARowStoresTheSnapshotRecord()
    local stored = { pack = "Gone", authorId = "old", soundId = 1 }
    local host = self.FakeHost.new(stored)
    self.control.Press(host, { kind = "pack", pinName = "soundId", value = stored })
    self.packs:Clear(self.token)
    host:Pick("VoicePack / Hello")
    luaunit.assertEquals(host.committed, {
        pack = "VoicePack", authorId = "greet_01", soundId = 12345,
    })
end

function TestPackSoundControl:testAPlainNumberPinKeepsTheScalarControl()
    local Controls = require("src/ui/controls")
    local Node = require("src/ui/node")
    local Theme = require("src/ui/theme")
    local number = Controls.PinControlFor("number")
    local host = self.FakeHost.new(5)
    number.Press(host, { value = 5 })
    luaunit.assertEquals(host.mounted.kind, "field")
    local pins = {
        { name = "soundId", kind = "data", direction = "in", dataType = "number" },
    }
    local plain = Node.BuildGeometry(pins, 0, 0, Theme.NODE_WIDTH)
    local keyed = Node.BuildGeometry(pins, 0, 0, Theme.NODE_WIDTH, { typeKey = "action.sound" })
    luaunit.assertEquals(plain.controls[1].pinControl, number)
    luaunit.assertEquals(keyed.controls[1].pinControl, self.control)
    luaunit.assertEquals(keyed.controls[1].kind, "number")
    luaunit.assertEquals(keyed.controls[2].kind, "pack")
    luaunit.assertEquals(keyed.controls[2].placeholder, "None")
    luaunit.assertTrue(keyed.controls[2].y > keyed.controls[1].y + keyed.controls[1].h - 1)
    luaunit.assertTrue(keyed.h > plain.h)
end

function TestPackSoundControl:testLayoutStacksTheNumberAboveThePackList()
    local bandH = self.control.ReservedHeight()
    luaunit.assertEquals(bandH, Theme.SOUND_BAND_H)
    local rects = self.control.Layout({ x = 10, y = 20, w = 200, h = bandH })
    luaunit.assertEquals(rects[1].kind, "number")
    luaunit.assertEquals(rects[2].kind, "pack")
    luaunit.assertEquals(rects[1].x, 10)
    luaunit.assertEquals(rects[2].x, 10)
    luaunit.assertEquals(rects[1].w, 200)
    luaunit.assertEquals(rects[2].y, rects[1].y + rects[1].h + Theme.SOUND_ROW_GAP)
end

function TestPackSoundControl:testSubmittingADifferentNumberClearsThePackRecord()
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    local host = self.FakeHost.new(stored)
    self.control.Press(host, { kind = "number", pinName = "soundId", value = stored })
    luaunit.assertEquals(host.mounted.kind, "field")
    luaunit.assertTrue(host.mounted.opts.spinner)
    luaunit.assertEquals(host.mounted.opts.initial, "12345")
    host:Type("99", 99)
    luaunit.assertEquals(host.committed, 99)
end

return {}
