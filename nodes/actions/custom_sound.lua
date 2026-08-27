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
    local Controls = require("ui/controls")
    Controls.Register("customSoundResource", {
        widget = "enum",
        choices = CustomSound.ResourceChoices(),
    })

    registry:RegisterNodeType("action.custom_sound", {
        category = "action",
        displayName = "Custom Sound",
        pins = {
            { name = "in", kind = "exec", direction = "in" },
            { name = "resource", kind = "data", direction = "in", dataType = "customSoundResource",
              default = nil },
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
            params.audioBus = audio.AudioBus.SFX
            audio.Play(resource, params)
        end,
    })
end

return CustomSound
