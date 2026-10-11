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
            local soundId = ctx:In("soundId")
            if type(soundId) == "number" then
                ---@type SoundPlaybackParams
                local params = audio.SoundPlaybackParams.new()
                params.audioBus = audio.AudioBus.SFX
                audio.Play(soundId, params)
            end
        end,
    })
end

return Sound
