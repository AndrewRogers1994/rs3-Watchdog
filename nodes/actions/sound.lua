local Sound = {}

-- Default sound: the town-crier bell. Resolved to its numeric id at registration; the
-- pin stores/serializes the number, so the node keeps working even if the constant moves.
local DEFAULT_SOUND_ID = id.Sound.TOWN_CRIER_BELL_RING_1

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
            -- audio.Play(builtinResourceID, params?) — one-shot, `bus` hardcoded "sfx" (#33
            -- retrofit). Guard against a nil/non-number soundId (e.g. an unconnected wire that
            -- resolved to something odd) so a bad input can't error the whole graph run.
            local soundId = ctx:In("soundId")
            if type(soundId) == "number" then
                audio.Play(soundId, { bus = "sfx" })
            end
        end,
    })
end

return Sound
