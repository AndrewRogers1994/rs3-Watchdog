local Packs = require("src/packs")
local Controls = require("src/ui/controls")
local CustomSoundControl = require("src/ui/controls/custom_sound")

local CustomSound = {}

local loaded = setmetatable({}, { __mode = "k" })

---@param name any
---@return { Load: (fun(self: any))|nil }|nil
local function resolveResource(name)
    if name == nil or Plugin == nil or Plugin.resources == nil or Plugin.resources.audio == nil then
        return nil
    end
    return Plugin.resources.audio[name]
end

--- Watchdog's own audio map. Pack audio is not in this table; playback asks the registry.
---@return table<string, { Load: (fun(self: any))|nil }>|nil
local function watchdogAudioMap()
    if Plugin == nil or Plugin.resources == nil then return nil end
    return Plugin.resources.audio
end

---@param resource { Load: (fun(self: any))|nil }|nil
local function preloadResource(resource)
    if resource == nil or loaded[resource] then
        return
    end
    if resource.Load ~= nil then
        pcall(function() resource:Load() end)
    end
    loaded[resource] = true
end

-- Keys match `audio.AudioBus` field names. Stored as strings so the dropdown does not
-- depend on the client enum existing at load; `run` resolves them to the live values.
-- Curated subset: the mixer has many sub-buses that are not useful as a user choice.
local DEFAULT_BUS = "SFX"
local BUS_CHOICES = {
    { value = "MASTER",    label = "Master" },
    { value = "SFX",       label = "SFX" },
    { value = "MUSIC",     label = "Music" },
    { value = "AMBIENT",   label = "Ambient" },
    { value = "VOICEOVER", label = "Voiceover" },
}

---@return { value: string, label: string }[]
function CustomSound.BusChoices()
    return BUS_CHOICES
end

---@param name any
---@return any
local function resolveBus(name)
    local buses = audio.AudioBus
    if type(name) == "string" and buses[name] ~= nil then
        return buses[name]
    end
    return buses[DEFAULT_BUS]
end

--- The open-list rows. None, then Watchdog file names, then pack audio files.
---@return Watchdog.AudioChoiceRow[]
function CustomSound.ResourceChoices()
    return CustomSoundControl.Choices()
end

---@param registry LibNodeGraph.Registry
function CustomSound.Register(registry)
    CustomSoundControl.install()
    Controls.Register("customSoundBus", {
        widget = "enum",
        choices = CustomSound.BusChoices(),
    })

    registry:RegisterNodeType("action.custom_sound", {
        category = "action",
        displayName = "Custom Sound",
        pins = {
            { name = "in", kind = "exec", direction = "in" },
            { name = "resource", kind = "data", direction = "in", dataType = "customSoundResource",
              default = nil },
            { name = "bus", kind = "data", direction = "in", dataType = "customSoundBus",
              default = DEFAULT_BUS, label = "Bus" },
            { name = "volume", kind = "data", direction = "in", dataType = "number", default = 100 },
            { name = "loops", kind = "data", direction = "in", dataType = "number", default = 0 },
        },
        preload = function(node)
            local stored = node.GetControl("resource")
            -- Pack audio is loaded by the Pack. Preload stays the Watchdog-file path.
            if type(stored) == "table" then return end
            preloadResource(resolveResource(stored))
        end,
        run = function(ctx)
            local stored = ctx:In("resource")
            local packs = Packs.live()
            local resource
            if packs ~= nil then
                resource = packs:ResolveAudioPlay(stored, watchdogAudioMap())
            elseif type(stored) ~= "table" then
                resource = resolveResource(stored)
            end
            if resource == nil then
                return
            end
            -- A pack audio file is already loaded by the Pack. Watchdog does not call Load.
            if type(stored) ~= "table" then
                preloadResource(resource)
            end
            local volume = ctx:In("volume")
            if type(volume) ~= "number" then volume = 100 end
            local loops = ctx:In("loops")
            if type(loops) ~= "number" then loops = 0 end
            ---@type SoundPlaybackParams
            local params = audio.SoundPlaybackParams.new()
            params.volume = volume / 100
            params.numLoops = loops
            params.audioBus = resolveBus(ctx:In("bus"))
            local instance = audio.Play(resource, params)
            if packs ~= nil then
                packs:NoteAudioPlay(instance)
            end
        end,
    })
end

return CustomSound
