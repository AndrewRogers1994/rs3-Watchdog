local Packs = require("src/packs")
local Controls = require("src/ui/controls")
local ControlKinds = require("src/ui/control_kinds")
local EnumControl = require("src/ui/controls/enum")
local Inline = require("src/ui/controls/inline")
local Dropdown = require("src/ui/widgets/dropdown")

local CustomSound = {}

local loaded = setmetatable({}, { __mode = "k" })

local function resolveResource(name)
    if name == nil or Plugin == nil or Plugin.resources == nil or Plugin.resources.audio == nil then
        return nil
    end
    return Plugin.resources.audio[name]
end

local function watchdogAudioMap()
    if Plugin == nil or Plugin.resources == nil then return nil end
    return Plugin.resources.audio
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

local function watchdogFileNames()
    local names = {}
    if Plugin ~= nil and Plugin.resources ~= nil and Plugin.resources.audio ~= nil then
        pcall(function()
            for name, _ in pairs(Plugin.resources.audio) do
                names[#names + 1] = name
            end
        end)
    end
    table.sort(names)
    return names
end

function CustomSound.ResourceChoices()
    local names = watchdogFileNames()
    local packs = Packs.live()
    if packs ~= nil then
        return packs:OpenAudioChoices(names, nil):Rows()
    end
    local choices = { { value = nil, label = "None" } }
    for _, name in ipairs(names) do
        if name ~= "None" then
            choices[#choices + 1] = { value = name, label = name }
        end
    end
    return choices
end

-- Closed text comes from the live registry. The open list is captured here, so a
-- Pack that clears while the list is open does not change the row being committed.
local function customSoundResourceControl()
    local shell = EnumControl.new({})
    local M = Inline.apply({})
    M.Layout = shell.Layout
    M.Draw = shell.Draw

    ---@param ctrl table
    ---@return string
    function M.Display(ctrl)
        local packs = Packs.live()
        if packs ~= nil then
            return packs:AudioClosedLabel(ctrl.value)
        end
        return EnumControl.new(CustomSound.ResourceChoices()).Display(ctrl)
    end

    ---@param host ControlHost
    ---@param ctrl table
    function M.Press(host, ctrl)
        local names = watchdogFileNames()
        local packs = Packs.live()
        local choices
        local initial
        local list
        if packs ~= nil then
            list = packs:OpenAudioChoices(names, ctrl.value)
            choices = list:Rows()
            initial = list:HighlightedLabel()
        else
            choices = CustomSound.ResourceChoices()
        end
        local dropdown = Dropdown.new(choices)
        local labels = dropdown:Labels()
        if initial == nil then
            initial = dropdown:LabelForValue(ctrl.value) or labels[1]
        end
        host:MountDropdown(ctrl, { labels = labels, initial = initial }, function(label)
            if list ~= nil then
                local value, found = list:Commit(label)
                if found then host:Commit(value) end
                return
            end
            local value, found = dropdown:ValueForLabel(label)
            if found then host:Commit(value) end
        end)
    end

    return M
end

---@param registry LibNodeGraph.Registry
function CustomSound.Register(registry)
    Controls.RegisterPinControl("customSoundResource", customSoundResourceControl())
    ControlKinds.Record("customSoundResource", "enum", CustomSound.ResourceChoices())
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
