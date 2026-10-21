-- action.custom_sound (#33) through a fake registry + fake ctx and stubbed Plugin.resources/audio.
-- No LibNodeGraph: run/preload only touch ctx:In / ctx:GetControl.

local luaunit = require("luaunit")
local CustomSound = require("src/nodes/actions/custom_sound")
local Packs = require("src/packs")
local Controls = require("src/ui/controls")
local FakeHost = require("fake_control_host")

local function makeFakeRegistry()
    return {
        types = {},
        RegisterNodeType = function(self, key, desc) self.types[key] = desc end,
    }
end

local function makeCtx(values)
    return { In = function(_self, name) return values[name] end }
end

local function makeNodeHandle(controls)
    return { id = "n1", GetControl = function(name) return controls[name] end }
end

local function stubResource(loaded)
    return {
        loaded = false,
        Load = function(self) self.loaded = true; loaded.count = (loaded.count or 0) + 1 end,
    }
end

-- Fake of the client `audio` global: SoundPlaybackParams.new(), AudioBus.*, Play records the call.
-- Values are sentinels, not the client's integer enum, so a test can see which key was resolved.
local function makeFakeAudio(calls)
    return {
        AudioBus = {
            MASTER = "master",
            SFX = "sfx",
            MUSIC = "music",
            AMBIENT = "ambient",
            VOICEOVER = "voiceover",
        },
        SoundPlaybackParams = { new = function() return {} end },
        Play = function(res, params)
            local instance = { isPlaying = true }
            calls[#calls + 1] = { res = res, params = params, instance = instance }
            return instance
        end,
    }
end

TestCustomSoundRegistration = {}

function TestCustomSoundRegistration:setUp()
    _G.Plugin = { resources = { audio = { beep = stubResource({}), boop = stubResource({}) } } }
    self.reg = makeFakeRegistry()
    CustomSound.Register(self.reg)
    self.desc = self.reg.types["action.custom_sound"]
end

function TestCustomSoundRegistration:tearDown()
    _G.Plugin = nil
    Packs.install(nil)
end

function TestCustomSoundRegistration:testRegistersActionCustomSoundPins()
    luaunit.assertNotNil(self.desc)
    luaunit.assertEquals(self.desc.category, "action")
    local byName = {}
    for _, pin in ipairs(self.desc.pins) do byName[pin.name] = pin end
    luaunit.assertEquals(byName["in"].kind, "exec")
    luaunit.assertEquals(byName.resource.dataType, "customSoundResource")
    luaunit.assertEquals(byName.bus.dataType, "customSoundBus")
    luaunit.assertEquals(byName.bus.default, "SFX")
    luaunit.assertEquals(byName.bus.label, "Bus")
    luaunit.assertEquals(byName.volume.dataType, "number")
    luaunit.assertEquals(byName.volume.default, 100)
    luaunit.assertEquals(byName.loops.dataType, "number")
    luaunit.assertEquals(byName.loops.default, 0)
end

function TestCustomSoundRegistration:testResourceChoicesEnumeratesPluginResourcesPlusNone()
    local choices = CustomSound.ResourceChoices()
    local byLabel = {}
    for _, c in ipairs(choices) do byLabel[c.label] = c.value end
    luaunit.assertEquals(byLabel["None"], nil)
    luaunit.assertEquals(byLabel["beep"], "beep")
    luaunit.assertEquals(byLabel["boop"], "boop")
end

function TestCustomSoundRegistration:testBusChoicesAreTheCuratedSetDefaultingToSfx()
    local choices = CustomSound.BusChoices()
    local byLabel = {}
    for _, c in ipairs(choices) do byLabel[c.label] = c.value end
    luaunit.assertEquals(byLabel["Master"], "MASTER")
    luaunit.assertEquals(byLabel["SFX"], "SFX")
    luaunit.assertEquals(byLabel["Music"], "MUSIC")
    luaunit.assertEquals(byLabel["Ambient"], "AMBIENT")
    luaunit.assertEquals(byLabel["Voiceover"], "VOICEOVER")
    luaunit.assertEquals(#choices, 5)
end

function TestCustomSoundRegistration:testResourceChoicesIsJustNoneWithoutPlugin()
    _G.Plugin = nil
    local choices = CustomSound.ResourceChoices()
    luaunit.assertEquals(#choices, 1)
    luaunit.assertEquals(choices[1].label, "None")
end

function TestCustomSoundRegistration:testResourceChoicesIncludesALivePackAudioFile()
    local packs = Packs.new()
    Packs.install(packs)
    packs:RegisterDataPack("Voice", {
        audioFiles = {
            { authorId = "bell", label = "Bell", audio = { loaded = true } },
        },
    })
    local choices = CustomSound.ResourceChoices()
    local byLabel = {}
    for _, choice in ipairs(choices) do byLabel[choice.label] = choice.value end
    luaunit.assertEquals(byLabel["beep"], "beep")
    luaunit.assertEquals(byLabel["boop"], "boop")
    luaunit.assertEquals(byLabel["Voice / Bell"], { pack = "Voice", authorId = "bell" })
end

function TestCustomSoundRegistration:testClosedControlShowsTheLiveLabel()
    local packs = Packs.new()
    Packs.install(packs)
    packs:RegisterDataPack("Voice", {
        audioFiles = {
            { authorId = "a", label = "Bell", audio = { loaded = true } },
            { authorId = "b", label = "Bell", audio = { loaded = true } },
        },
    })
    local control = Controls.PinControlFor("customSoundResource")
    luaunit.assertEquals(control.Display({ value = { pack = "Voice", authorId = "a" } }), "Bell")
    luaunit.assertEquals(control.Display({ value = { pack = "Voice", authorId = "b" } }), "Bell")
    luaunit.assertEquals(control.Display({ value = nil }), "None")
    luaunit.assertEquals(control.Display({ value = "beep" }), "beep")
end

function TestCustomSoundRegistration:testVariableChoicesFollowTheLiveRegistry()
    local ControlKinds = require("src/ui/control_kinds")
    local function labelsOf(choices)
        local labels = {}
        for i, choice in ipairs(choices) do labels[i] = choice.label end
        return labels
    end
    luaunit.assertEquals(labelsOf(ControlKinds.Choices("customSoundResource")), { "None", "beep", "boop" })
    local packs = Packs.new()
    Packs.install(packs)
    packs:RegisterDataPack("Voice", {
        audioFiles = {
            { authorId = "bell", label = "Bell", audio = { loaded = true } },
        },
    })
    luaunit.assertEquals(labelsOf(ControlKinds.Choices("customSoundResource")), {
        "None", "beep", "boop", "Voice / Bell",
    })
end

function TestCustomSoundRegistration:testOpenListKeepsSpecOrderPastAlphabeticalSort()
    local packs = Packs.new()
    Packs.install(packs)
    packs:RegisterDataPack("Voice", {
        audioFiles = {
            { authorId = "bell", label = "Bell", audio = { loaded = true } },
        },
    })
    local control = Controls.PinControlFor("customSoundResource")
    local host = FakeHost.new(nil)
    control.Press(host, { value = nil, pinName = "resource" })
    local Dropdown = require("src/ui/widgets/dropdown")
    luaunit.assertEquals(Dropdown.VisibleOrder(host.mounted.opts.entries), {
        "None", "beep", "boop", "Voice / Bell",
    })
end

function TestCustomSoundRegistration:testCommitUsesTheRowsCapturedAtOpen()
    local packs = Packs.new()
    Packs.install(packs)
    local token = packs:RegisterDataPack("Voice", {
        audioFiles = {
            { authorId = "bell", label = "Bell", audio = { loaded = true } },
        },
    })
    local control = Controls.PinControlFor("customSoundResource")
    local host = FakeHost.new(nil)
    control.Press(host, { value = nil, pinName = "resource" })
    packs:Clear(token)
    host:Pick("Voice / Bell")
    luaunit.assertEquals(host.committed, { pack = "Voice", authorId = "bell" })
    luaunit.assertNil(host.committed.audio)
end

TestCustomSoundRun = {}

function TestCustomSoundRun:setUp()
    self.resources = { beep = stubResource({}) }
    _G.Plugin = { resources = { audio = self.resources } }
    self.reg = makeFakeRegistry()
    CustomSound.Register(self.reg)
    self.desc = self.reg.types["action.custom_sound"]
    self.calls = {}
    _G.audio = makeFakeAudio(self.calls)
end

function TestCustomSoundRun:tearDown()
    _G.Plugin = nil
    _G.audio = nil
    Packs.install(nil)
end

function TestCustomSoundRun:testPlaysChosenResourceWithDefaultsOnSfxBus()
    self.desc.run(makeCtx({ resource = "beep" }))
    luaunit.assertEquals(#self.calls, 1)
    luaunit.assertEquals(self.calls[1].res, self.resources.beep)
    luaunit.assertEquals(self.calls[1].params.volume, 1.0)
    luaunit.assertEquals(self.calls[1].params.numLoops, 0)
    luaunit.assertEquals(self.calls[1].params.audioBus, "sfx")
end

function TestCustomSoundRun:testHonorsBusPin()
    local expected = {
        MASTER = "master",
        SFX = "sfx",
        MUSIC = "music",
        AMBIENT = "ambient",
        VOICEOVER = "voiceover",
    }
    for key, bus in pairs(expected) do
        for i = #self.calls, 1, -1 do self.calls[i] = nil end
        self.desc.run(makeCtx({ resource = "beep", bus = key }))
        luaunit.assertEquals(#self.calls, 1)
        luaunit.assertEquals(self.calls[1].params.audioBus, bus)
    end
end

function TestCustomSoundRun:testUnknownBusFallsBackToSfx()
    self.desc.run(makeCtx({ resource = "beep", bus = "DIALOG_SUB" }))
    luaunit.assertEquals(self.calls[1].params.audioBus, "sfx")
end

function TestCustomSoundRun:testHonorsVolumeAndLoopsPins()
    -- volume is a 0-100 pin, scaled to the client's 0-1 float bus volume (50 -> 0.5).
    self.desc.run(makeCtx({ resource = "beep", volume = 50, loops = 3 }))
    luaunit.assertEquals(self.calls[1].params.volume, 0.5)
    luaunit.assertEquals(self.calls[1].params.numLoops, 3)
end

function TestCustomSoundRun:testNilResourceIsASilentNoop()
    local ok = pcall(function() self.desc.run(makeCtx({ resource = nil })) end)
    luaunit.assertTrue(ok)
    luaunit.assertEquals(#self.calls, 0)
end

function TestCustomSoundRun:testUnknownResourceNameIsASilentNoop()
    local ok = pcall(function() self.desc.run(makeCtx({ resource = "missing" })) end)
    luaunit.assertTrue(ok)
    luaunit.assertEquals(#self.calls, 0)
end

function TestCustomSoundRun:testRunLoadsResourceAsOnDemandBackstopWhenNotPreloaded()
    self.desc.run(makeCtx({ resource = "beep" }))
    luaunit.assertTrue(self.resources.beep.loaded)
end

function TestCustomSoundRun:testPackRecordPlaysTheRegistryResourceWithoutLoad()
    local loads = 0
    local resource = {
        loaded = true,
        Load = function() loads = loads + 1 end,
    }
    local packs = Packs.new()
    Packs.install(packs)
    packs:RegisterDataPack("Voice", {
        audioFiles = {
            { authorId = "bell", label = "Bell", audio = resource },
        },
    })
    self.desc.run(makeCtx({
        resource = { pack = "Voice", authorId = "bell" },
        volume = 50,
        loops = 3,
        bus = "MUSIC",
    }))
    luaunit.assertEquals(#self.calls, 1)
    luaunit.assertIs(self.calls[1].res, resource)
    luaunit.assertEquals(self.calls[1].params.volume, 0.5)
    luaunit.assertEquals(self.calls[1].params.numLoops, 3)
    luaunit.assertEquals(self.calls[1].params.audioBus, "music")
    luaunit.assertEquals(loads, 0)
end

function TestCustomSoundRun:testANilPackResolveDoesNotPlay()
    Packs.install(Packs.new())
    self.desc.run(makeCtx({ resource = { pack = "Voice", authorId = "bell" }, volume = 50, loops = 3 }))
    luaunit.assertEquals(#self.calls, 0)
end

TestCustomSoundPreload = {}

function TestCustomSoundPreload:setUp()
    self.resources = { beep = stubResource({}) }
    _G.Plugin = { resources = { audio = self.resources } }
    self.reg = makeFakeRegistry()
    CustomSound.Register(self.reg)
    self.desc = self.reg.types["action.custom_sound"]
end

function TestCustomSoundPreload:tearDown()
    _G.Plugin = nil
    Packs.install(nil)
end

function TestCustomSoundPreload:testPreloadHookLoadsTheControlChosenResource()
    luaunit.assertNotNil(self.desc.preload)
    self.desc.preload(makeNodeHandle({ resource = "beep" }))
    luaunit.assertTrue(self.resources.beep.loaded)
end

function TestCustomSoundPreload:testPreloadWithNoResourceControlIsASilentNoop()
    local ok = pcall(function() self.desc.preload(makeNodeHandle({})) end)
    luaunit.assertTrue(ok)
end

function TestCustomSoundPreload:testResourceIsNeverReloadedOnceLoaded()
    self.desc.preload(makeNodeHandle({ resource = "beep" }))
    self.desc.preload(makeNodeHandle({ resource = "beep" }))
    luaunit.assertEquals(self.resources.beep.loaded, true)
end

function TestCustomSoundPreload:testPreloadDoesNotLoadAPackRecord()
    local loads = 0
    local resource = {
        loaded = true,
        Load = function() loads = loads + 1 end,
    }
    local packs = Packs.new()
    Packs.install(packs)
    packs:RegisterDataPack("Voice", {
        audioFiles = {
            { authorId = "bell", label = "Bell", audio = resource },
        },
    })
    self.desc.preload(makeNodeHandle({ resource = { pack = "Voice", authorId = "bell" } }))
    luaunit.assertEquals(loads, 0)
end
