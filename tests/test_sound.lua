-- Exercises action.sound (#33 retrofit) through a fake registry + fake ctx and a stubbed
-- `audio` global - no LibNodeGraph required, matching test_infobox_node's convention (a plain
-- Register/run wiring test needs no real Graph, since ctx:In is all `run` touches).

_G.id = _G.id or {}
_G.id.Sound = _G.id.Sound or { TOWN_CRIER_BELL_RING_1 = 2608 }

local luaunit = require("luaunit")
local Sound = require("src/nodes/actions/sound")

local function makeFakeRegistry()
    return {
        types = {},
        RegisterNodeType = function(self, key, desc) self.types[key] = desc end,
    }
end

local function makeCtx(values)
    return { In = function(_self, name) return values[name] end }
end

TestSoundRegistration = {}

function TestSoundRegistration:setUp()
    self.reg = makeFakeRegistry()
    Sound.Register(self.reg)
    self.desc = self.reg.types["action.sound"]
end

function TestSoundRegistration:testRegistersActionSoundWithExecInAndSoundIdPin()
    luaunit.assertNotNil(self.desc)
    luaunit.assertEquals(self.desc.category, "action")
    local byName = {}
    for _, pin in ipairs(self.desc.pins) do byName[pin.name] = pin end
    luaunit.assertEquals(byName["in"].kind, "exec")
    luaunit.assertEquals(byName["in"].direction, "in")
    luaunit.assertEquals(byName.soundId.dataType, "number")
end

TestSoundRun = {}

function TestSoundRun:setUp()
    self.reg = makeFakeRegistry()
    Sound.Register(self.reg)
    self.desc = self.reg.types["action.sound"]
    self.calls = {}
    _G.audio = {
        AudioBus = { SFX = "sfx" },
        SoundPlaybackParams = { new = function() return {} end },
        Play = function(id, params) self.calls[#self.calls + 1] = { id = id, params = params } end,
    }
end

function TestSoundRun:tearDown()
    _G.audio = nil
end

function TestSoundRun:testPlaysWithBusHardcodedToSfx()
    self.desc.run(makeCtx({ soundId = 1234 }))
    luaunit.assertEquals(#self.calls, 1)
    luaunit.assertEquals(self.calls[1].id, 1234)
    luaunit.assertEquals(self.calls[1].params.audioBus, "sfx")
end

function TestSoundRun:testNonNumberSoundIdIsASilentNoop()
    local ok = pcall(function() self.desc.run(makeCtx({ soundId = "nope" })) end)
    luaunit.assertTrue(ok)
    luaunit.assertEquals(#self.calls, 0)
end
