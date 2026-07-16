-- Exercises action.custom_sound (#33) through a fake registry + fake ctx and a stubbed
-- `Plugin.resources`/`audio` global — same convention as test_sound.lua, no LibNodeGraph
-- required since `run`/`preload` only touch ctx:In/ctx:GetControl.

local luaunit = require("luaunit")
local CustomSound = require("nodes/actions/custom_sound")

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

TestCustomSoundRegistration = {}

function TestCustomSoundRegistration:setUp()
    _G.Plugin = { resources = { beep = stubResource({}), boop = stubResource({}) } }
    self.reg = makeFakeRegistry()
    CustomSound.Register(self.reg)
    self.desc = self.reg.types["action.custom_sound"]
end

function TestCustomSoundRegistration:tearDown()
    _G.Plugin = nil
end

function TestCustomSoundRegistration:testRegistersActionCustomSoundPins()
    luaunit.assertNotNil(self.desc)
    luaunit.assertEquals(self.desc.category, "action")
    local byName = {}
    for _, pin in ipairs(self.desc.pins) do byName[pin.name] = pin end
    luaunit.assertEquals(byName["in"].kind, "exec")
    luaunit.assertEquals(byName.resource.dataType, "customSoundResource")
    luaunit.assertEquals(byName.volume.dataType, "number")
    luaunit.assertEquals(byName.volume.default, 1.0)
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

function TestCustomSoundRegistration:testResourceChoicesIsJustNoneWithoutPlugin()
    _G.Plugin = nil
    local choices = CustomSound.ResourceChoices()
    luaunit.assertEquals(#choices, 1)
    luaunit.assertEquals(choices[1].label, "None")
end

TestCustomSoundRun = {}

function TestCustomSoundRun:setUp()
    self.resources = { beep = stubResource({}) }
    _G.Plugin = { resources = self.resources }
    self.reg = makeFakeRegistry()
    CustomSound.Register(self.reg)
    self.desc = self.reg.types["action.custom_sound"]
    self.calls = {}
    _G.audio = { Play = function(res, params) self.calls[#self.calls + 1] = { res = res, params = params } end }
end

function TestCustomSoundRun:tearDown()
    _G.Plugin = nil
    _G.audio = nil
end

function TestCustomSoundRun:testPlaysChosenResourceWithDefaultsAndBusHardcodedToSfx()
    self.desc.run(makeCtx({ resource = "beep" }))
    luaunit.assertEquals(#self.calls, 1)
    luaunit.assertEquals(self.calls[1].res, self.resources.beep)
    luaunit.assertEquals(self.calls[1].params.volume, 1.0)
    luaunit.assertEquals(self.calls[1].params.loops, 0)
    luaunit.assertEquals(self.calls[1].params.bus, "sfx")
end

function TestCustomSoundRun:testHonorsVolumeAndLoopsPins()
    self.desc.run(makeCtx({ resource = "beep", volume = 0.5, loops = 3 }))
    luaunit.assertEquals(self.calls[1].params.volume, 0.5)
    luaunit.assertEquals(self.calls[1].params.loops, 3)
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

TestCustomSoundPreload = {}

function TestCustomSoundPreload:setUp()
    self.resources = { beep = stubResource({}) }
    _G.Plugin = { resources = self.resources }
    self.reg = makeFakeRegistry()
    CustomSound.Register(self.reg)
    self.desc = self.reg.types["action.custom_sound"]
end

function TestCustomSoundPreload:tearDown()
    _G.Plugin = nil
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
