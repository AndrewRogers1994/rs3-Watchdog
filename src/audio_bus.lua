local Controls = require("src/ui/controls")

-- Keys match `audio.AudioBus` field names. Stored as strings so the dropdown
-- does not depend on the client enum existing at load; Resolve turns them into
-- the live values. Curated subset: the mixer has many sub-buses that are not
-- useful as a user choice.
local AudioBus = {}

local DEFAULT = "SFX"

AudioBus.TAG = "audioBus"

local CHOICES = {
    { value = "MASTER",    label = "Master" },
    { value = "SFX",       label = "SFX" },
    { value = "MUSIC",     label = "Music" },
    { value = "AMBIENT",   label = "Ambient" },
    { value = "VOICEOVER", label = "Voiceover" },
}

---@return { value: string, label: string }[]
function AudioBus.Choices()
    return CHOICES
end

function AudioBus.Pin()
    return {
        name = "bus",
        kind = "data",
        direction = "in",
        dataType = AudioBus.TAG,
        default = DEFAULT,
        label = "Bus",
    }
end

---@param name any
---@return any
function AudioBus.Resolve(name)
    local buses = audio.AudioBus
    if type(name) == "string" and buses[name] ~= nil then
        return buses[name]
    end
    return buses[DEFAULT]
end

Controls.Register(AudioBus.TAG, {
    widget = "enum",
    choices = CHOICES,
})

return AudioBus
