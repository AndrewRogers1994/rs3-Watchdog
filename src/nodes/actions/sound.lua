local Packs = require("src/packs")
local Controls = require("src/ui/controls")
local SoundEffectControl = require("src/ui/controls/sound_effect")

local Sound = {}

local DEFAULT_SOUND_ID = id.Sound.TOWN_CRIER_BELL_RING_1

---@param registry LibNodeGraph.Registry
function Sound.Register(registry)
    registry:RegisterNodeType("action.sound", {
        category = "action",
        displayName = "Sound Effect",
        pins = {
            { name = "in", kind = "exec", direction = "in" },
            { name = "soundId", kind = "data", direction = "in", dataType = "number",
              default = DEFAULT_SOUND_ID },
        },
        run = function(ctx)
            -- The registry resolves a raw id or a pack record to the stored
            -- builtin sound id. A pack sound effect has no private hold.
            local soundId = Packs:ResolveSoundEffect(ctx:In("soundId"))
            if soundId ~= nil then
                ---@type SoundPlaybackParams
                local params = audio.SoundPlaybackParams.new()
                params.audioBus = audio.AudioBus.SFX
                audio.Play(soundId, params)
            end
        end,
    })
end

-- Sound Effect stays dataType "number". The pack-sound list is installed here,
-- not from controls.lua: packs -> presets -> node -> controls would cycle if
-- that registry required this module while packs.lua was still loading.
Controls.RegisterPinControl("number", SoundEffectControl.wrap(Controls.PinControlFor("number")))

return Sound
