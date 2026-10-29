local AudioBus = require("src/audio_bus")
local Packs = require("src/packs")
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

--- The open-list rows. None, then Watchdog file names, then pack audio files.
---@return Watchdog.AudioChoiceRow[]
function CustomSound.ResourceChoices()
    return CustomSoundControl.Choices()
end

---@param registry LibNodeGraph.Registry
function CustomSound.Register(registry)
    CustomSoundControl.install()

    registry:RegisterNodeType("action.custom_sound", {
        category = "action",
        displayName = "Custom Sound",
        pins = {
            { name = "in", kind = "exec", direction = "in" },
            AudioBus.Pin(),
            { name = "resource", kind = "data", direction = "in", dataType = "customSoundResource",
              default = nil },
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
            params.audioBus = AudioBus.Resolve(ctx:In("bus"))
            local instance = audio.Play(resource, params)
            if packs ~= nil then
                packs:NoteAudioPlay(instance)
            end
        end,
    })
end

return CustomSound
