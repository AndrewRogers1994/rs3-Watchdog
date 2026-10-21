-- Pack audio files on the Custom Sound choice list.
-- Loaded directly, the way the Preset library tests load that library. No PrettyUI.

local luaunit = require("luaunit")
local Packs = require("src/packs")
local Registry = require("registry")
local Graph = require("graph")
local Serialize = require("serialize")
local CustomSound = require("src/nodes/actions/custom_sound")

local function labelsOf(rows)
    local labels = {}
    for i, row in ipairs(rows) do
        labels[i] = row.label
    end
    return labels
end

TestPackAudioRows = {}

function TestPackAudioRows:setUp()
    self.packs = Packs.new()
end

function TestPackAudioRows:testRowsAreNoneThenWatchdogFilesThenPackAudioFiles()
    self.packs:RegisterDataPack("Voice", {
        audioFiles = {
            { authorId = "bell", label = "Bell", audio = { loaded = true } },
        },
    })
    local rows = self.packs:OpenAudioChoices({ "boop", "None", "beep" }, nil):Rows()
    luaunit.assertEquals(labelsOf(rows), { "None", "beep", "boop", "Voice / Bell" })
    luaunit.assertNil(rows[1].value)
    luaunit.assertEquals(rows[2].value, "beep")
    luaunit.assertEquals(rows[3].value, "boop")
    luaunit.assertEquals(rows[4].value, { pack = "Voice", authorId = "bell" })
end

function TestPackAudioRows:testARepeatedLabelInsideOnePackShowsTheAuthorId()
    self.packs:RegisterDataPack("Voice", {
        audioFiles = {
            { authorId = "chime", label = "Bell", audio = { loaded = true } },
            { authorId = "bell", label = "Bell", audio = { loaded = true } },
            { authorId = "horn", label = "Horn", audio = { loaded = true } },
        },
    })
    local rows = self.packs:OpenAudioChoices({}, nil):Rows()
    luaunit.assertEquals(labelsOf(rows), {
        "None",
        "Voice / Bell (bell)",
        "Voice / Bell (chime)",
        "Voice / Horn",
    })
end

function TestPackAudioRows:testTheSameLabelInTwoPacksKeepsThePackNameOnly()
    self.packs:RegisterDataPack("Voice", {
        audioFiles = {
            { authorId = "bell", label = "Bell", audio = { loaded = true } },
        },
    })
    self.packs:RegisterDataPack("Horns", {
        audioFiles = {
            { authorId = "bell", label = "Bell", audio = { loaded = true } },
        },
    })
    local rows = self.packs:OpenAudioChoices({}, nil):Rows()
    luaunit.assertEquals(labelsOf(rows), { "None", "Horns / Bell", "Voice / Bell" })
end

TestPackAudioClosedLabel = {}

function TestPackAudioClosedLabel:setUp()
    self.packs = Packs.new()
end

function TestPackAudioClosedLabel:testALivePackAudioFileShowsItsLiveLabel()
    self.packs:RegisterDataPack("Voice", {
        audioFiles = {
            { authorId = "bell", label = "Bell", audio = { loaded = true } },
        },
    })
    local stored = { pack = "Voice", authorId = "bell" }
    luaunit.assertEquals(self.packs:AudioClosedLabel(stored), "Bell")
end

function TestPackAudioClosedLabel:testASharedLabelStaysTheLiveLabelWhenClosed()
    self.packs:RegisterDataPack("Voice", {
        audioFiles = {
            { authorId = "bell", label = "Bell", audio = { loaded = true } },
            { authorId = "chime", label = "Bell", audio = { loaded = true } },
        },
    })
    luaunit.assertEquals(self.packs:AudioClosedLabel({ pack = "Voice", authorId = "bell" }), "Bell")
    luaunit.assertEquals(self.packs:AudioClosedLabel({ pack = "Voice", authorId = "chime" }), "Bell")
end

function TestPackAudioClosedLabel:testAMissingPackAudioFileNamesThePackAndAuthorId()
    luaunit.assertEquals(
        self.packs:AudioClosedLabel({ pack = "Voice", authorId = "bell" }),
        "Voice / bell (missing)"
    )
end

function TestPackAudioClosedLabel:testNoneAndAWatchdogFileKeepTheirClosedLabels()
    luaunit.assertEquals(self.packs:AudioClosedLabel(nil), "None")
    luaunit.assertEquals(self.packs:AudioClosedLabel("alarm"), "alarm")
end

function TestPackAudioClosedLabel:testAChangedLabelShowsTheLiveLabel()
    local token = self.packs:RegisterDataPack("Voice", {
        audioFiles = {
            { authorId = "bell", label = "Bell", audio = { loaded = true } },
        },
    })
    self.packs:Clear(token)
    self.packs:RegisterDataPack("Voice", {
        audioFiles = {
            { authorId = "bell", label = "Chime", audio = { loaded = true } },
        },
    })
    luaunit.assertEquals(self.packs:AudioClosedLabel({ pack = "Voice", authorId = "bell" }), "Chime")
end

TestPackAudioCommit = {}

function TestPackAudioCommit:setUp()
    self.packs = Packs.new()
    self.token = self.packs:RegisterDataPack("Voice", {
        audioFiles = {
            { authorId = "bell", label = "Bell", audio = { loaded = true, id = "resource" } },
        },
    })
end

function TestPackAudioCommit:testChoosingNoneStoresNil()
    local list = self.packs:OpenAudioChoices({ "beep" }, { pack = "Voice", authorId = "bell" })
    local value, found = list:Commit("None")
    luaunit.assertTrue(found)
    luaunit.assertNil(value)
end

function TestPackAudioCommit:testChoosingAWatchdogFileStoresThatFileName()
    local list = self.packs:OpenAudioChoices({ "beep" }, { pack = "Voice", authorId = "bell" })
    luaunit.assertEquals(list:Commit("beep"), "beep")
end

function TestPackAudioCommit:testChoosingAPackFileStoresPackAndAuthorId()
    local list = self.packs:OpenAudioChoices({ "beep" }, "beep")
    local value = list:Commit("Voice / Bell")
    luaunit.assertEquals(value, { pack = "Voice", authorId = "bell" })
    luaunit.assertNil(value.audio)
end

function TestPackAudioCommit:testCommitKeepsTheCapturedIdentityAfterClear()
    local list = self.packs:OpenAudioChoices({}, nil)
    self.packs:Clear(self.token)
    luaunit.assertEquals(list:Commit("Voice / Bell"), { pack = "Voice", authorId = "bell" })
end

function TestPackAudioCommit:testTheNextOpenReadsTheLiveRegistry()
    local open = self.packs:OpenAudioChoices({}, nil)
    self.packs:Clear(self.token)
    self.packs:RegisterDataPack("Voice", {
        audioFiles = {
            { authorId = "horn", label = "Horn", audio = { loaded = true } },
        },
    })
    local again = self.packs:OpenAudioChoices({}, nil)
    luaunit.assertEquals(labelsOf(open:Rows()), { "None", "Voice / Bell" })
    luaunit.assertEquals(labelsOf(again:Rows()), { "None", "Voice / Horn" })
end

function TestPackAudioCommit:testAHighlightIsNotACommit()
    local stored = { pack = "Voice", authorId = "bell" }
    local list = self.packs:OpenAudioChoices({ "beep" }, stored)
    luaunit.assertEquals(list:HighlightedLabel(), "Voice / Bell")
    list:Highlight("beep")
    luaunit.assertEquals(list:HighlightedLabel(), "beep")
    local still = list:Stored()
    luaunit.assertEquals(still.pack, "Voice")
    luaunit.assertEquals(still.authorId, "bell")
end

function TestPackAudioCommit:testAStoredIdentityWithNoMatchingRowStaysStored()
    local stored = { pack = "Gone", authorId = "old" }
    local list = self.packs:OpenAudioChoices({ "beep" }, stored)
    luaunit.assertEquals(list:HighlightedLabel(), "None")
    luaunit.assertEquals(list:Stored().pack, "Gone")
    luaunit.assertEquals(list:Stored().authorId, "old")
    luaunit.assertEquals(list:Commit("beep"), "beep")
    local cleared, found = list:Commit("None")
    luaunit.assertTrue(found)
    luaunit.assertNil(cleared)
end

function TestPackAudioCommit:testNilStringAndPackRecordRoundTrip()
    local registry = Registry.new()
    CustomSound.Register(registry)
    local graph = Graph.new(registry)
    local id = graph:AddNode("action.custom_sound")
    local sentinel = "pack-audio-resource-sentinel"

    graph:SetControl(id, "resource", nil)
    graph = Serialize.ImportJSON(Serialize.ExportJSON(graph), registry)
    luaunit.assertNil(graph:GetControl(id, "resource"))

    graph:SetControl(id, "resource", "alarm")
    graph = Serialize.ImportJSON(Serialize.ExportJSON(graph), registry)
    luaunit.assertEquals(graph:GetControl(id, "resource"), "alarm")

    self.packs:Clear(self.token)
    self.packs:RegisterDataPack("Voice", {
        audioFiles = {
            { authorId = "bell", label = "Bell", audio = { loaded = true, id = sentinel } },
        },
    })
    local stored = self.packs:OpenAudioChoices({}, nil):Commit("Voice / Bell")
    graph:SetControl(id, "resource", stored)
    local encoded = Serialize.ExportJSON(graph)
    luaunit.assertNil(encoded:find(sentinel, 1, true))
    graph = Serialize.ImportJSON(encoded, registry)
    local got = graph:GetControl(id, "resource")
    luaunit.assertEquals(got, { pack = "Voice", authorId = "bell" })
    luaunit.assertNil(got.audio)
end

TestPackAudioPlay = {}

function TestPackAudioPlay:setUp()
    self.packs = Packs.new()
end

function TestPackAudioPlay:testAPackRecordResolvesToTheRegisteredResource()
    local loads = 0
    local resource = {
        loaded = true,
        Load = function() loads = loads + 1 end,
    }
    self.packs:RegisterDataPack("Voice", {
        audioFiles = {
            { authorId = "bell", label = "Bell", audio = resource },
        },
    })
    luaunit.assertIs(
        self.packs:ResolveAudioPlay({ pack = "Voice", authorId = "bell" }, {}),
        resource
    )
    luaunit.assertEquals(loads, 0)
end

function TestPackAudioPlay:testAMissingPackResolvesToNothing()
    luaunit.assertNil(self.packs:ResolveAudioPlay({ pack = "Voice", authorId = "bell" }, {}))
    luaunit.assertNil(self.packs:ResolveAudioPlay(nil, {}))
end

function TestPackAudioPlay:testAWatchdogFileNameSavedBeforeThisContractResolves()
    local alarm = { loaded = true }
    luaunit.assertIs(self.packs:ResolveAudioPlay("alarm", { alarm = alarm }), alarm)
end

function TestPackAudioPlay:tearDown()
    audio = nil
end

function TestPackAudioPlay:testAPlayAlreadyStartedKeepsGoingAfterClear()
    local resource = { loaded = true }
    local token = self.packs:RegisterDataPack("Voice", {
        audioFiles = {
            { authorId = "bell", label = "Bell", audio = resource },
        },
    })
    luaunit.assertIs(self.packs:ResolveAudioPlay({ pack = "Voice", authorId = "bell" }, {}), resource)

    local stops = 0
    local instance = {
        isPlaying = true,
        numLoops = 4,
        Stop = function() stops = stops + 1 end,
    }
    audio = {
        Stop = function() stops = stops + 1 end,
        StopSoundsUsingResource = function() stops = stops + 1 end,
    }
    self.packs:NoteAudioPlay(instance)

    self.packs:Clear(token)
    luaunit.assertNil(self.packs:ResolveAudioPlay({ pack = "Voice", authorId = "bell" }, {}))
    luaunit.assertEquals(stops, 0)
    luaunit.assertTrue(instance.isPlaying)
    luaunit.assertEquals(instance.numLoops, 4)

    local replacement = { loaded = true }
    self.packs:RegisterDataPack("Voice", {
        audioFiles = {
            { authorId = "bell", label = "Bell", audio = replacement },
        },
    })
    luaunit.assertIs(
        self.packs:ResolveAudioPlay({ pack = "Voice", authorId = "bell" }, {}),
        replacement
    )
    luaunit.assertEquals(stops, 0)
    luaunit.assertTrue(instance.isPlaying)
    luaunit.assertEquals(instance.numLoops, 4)

    instance.isPlaying = false
    luaunit.assertIs(
        self.packs:ResolveAudioPlay({ pack = "Voice", authorId = "bell" }, {}),
        replacement
    )
    luaunit.assertEquals(stops, 0)
    luaunit.assertEquals(instance.numLoops, 4)
end
