local CustomSound = {}

local loaded = setmetatable({}, { __mode = "k" })

local function resolveResource(name)
    if name == nil or Plugin == nil or Plugin.resources == nil or Plugin.resources.audio == nil then
        return nil
    end
    return Plugin.resources.audio[name]
end

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

function CustomSound.ResourceChoices()
    local names = {}
    if Plugin ~= nil and Plugin.resources ~= nil and Plugin.resources.audio ~= nil then
        pcall(function()
            for name, _ in pairs(Plugin.resources.audio) do
                names[#names + 1] = name
            end
        end)
    end
    table.sort(names)
    local choices = { { value = nil, label = "None" } }
    for _, name in ipairs(names) do
        choices[#choices + 1] = { value = name, label = name }
    end
    return choices
end

---@param registry LibNodeGraph.Registry
function CustomSound.Register(registry)
    local Controls = require("src/ui/controls")
    Controls.Register("customSoundResource", {
        widget = "enum",
        choices = CustomSound.ResourceChoices(),
    })
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
            preloadResource(resolveResource(node.GetControl("resource")))
        end,
        run = function(ctx)
            local resource = resolveResource(ctx:In("resource"))
            if resource == nil then
                return
            end
            preloadResource(resource)
            local volume = ctx:In("volume")
            if type(volume) ~= "number" then volume = 100 end
            local loops = ctx:In("loops")
            if type(loops) ~= "number" then loops = 0 end
            ---@type SoundPlaybackParams
            local params = audio.SoundPlaybackParams.new()
            params.volume = volume / 100
            params.numLoops = loops
            params.audioBus = resolveBus(ctx:In("bus"))
            audio.Play(resource, params)
        end,
    })
end

return CustomSound
