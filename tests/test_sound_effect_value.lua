-- What a Sound Effect Control stores. Callers pass the current value and what
-- the player did. This module does not read the Pack registry.

local luaunit = require("luaunit")
local Packs = require("src/packs")
local SoundEffectValue = require("src/sound_effect_value")

TestSoundEffectValue = {}

function TestSoundEffectValue:setUp()
    self.packs = Packs.new()
    Packs.install(self.packs)
end

function TestSoundEffectValue:tearDown()
    Packs.install(nil)
end

function TestSoundEffectValue:testAChosenRowStoresACopyOfThatRow()
    self.packs:RegisterDataPack("VoicePack", {
        soundEffects = {
            { authorId = "greet_01", label = "Welcome", soundId = 999 },
        },
    })
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    local row = {
        pack = "VoicePack",
        authorId = "greet_01",
        soundId = 50,
        label = "VoicePack / Hello",
    }
    local result = SoundEffectValue.apply(stored, "row", row)
    luaunit.assertEquals(result, {
        pack = "VoicePack", authorId = "greet_01", soundId = 50,
    })
    row.soundId = 1
    row.label = "changed"
    luaunit.assertEquals(result.soundId, 50)
    luaunit.assertNil(result.label)
end

-- An untouched pack list is this action: the typed id is compared with the
-- stored builtin sound id, and an outdated record survives when they match.
function TestSoundEffectValue:testTheSameBuiltinSoundIdKeepsAnOutdatedPackSoundEffect()
    self.packs:RegisterDataPack("VoicePack", {
        soundEffects = {
            { authorId = "greet_01", label = "Hello", soundId = 999 },
        },
    })
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    luaunit.assertIs(SoundEffectValue.apply(stored, "number", 12345), stored)
end

function TestSoundEffectValue:testADifferentBuiltinSoundIdStoresOnlyThatNumber()
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    luaunit.assertEquals(SoundEffectValue.apply(stored, "number", 99), 99)
end

function TestSoundEffectValue:testChoosingNoneStoresTheTypedNumber()
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    luaunit.assertEquals(SoundEffectValue.apply(stored, "none", 12345), 12345)
end

function TestSoundEffectValue:testHighlightLeavesTheStoredValueUnchanged()
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    local row = { pack = "Other", authorId = "bell", soundId = 7, label = "Other / Bell" }
    luaunit.assertIs(SoundEffectValue.apply(stored, "highlight", row), stored)
end

function TestSoundEffectValue:testDismissLeavesTheStoredValueUnchanged()
    local stored = { pack = "VoicePack", authorId = "greet_01", soundId = 12345 }
    luaunit.assertIs(SoundEffectValue.apply(stored, "dismiss", nil), stored)
end

return {}
