-- action.custom_sound (#33): plays an author-bundled audio resource — a disk file-picker is
-- API-blocked and out of scope, so the pool is `Plugin.resources` (bundled under the plugin's
-- own resources/ folder), picked via an interim dropdown Control (node-config, not a pin,
-- same convention as action.sound's `soundId`). `bus` is hardcoded "sfx" like action.sound's
-- own retrofit; `volume`/`loops` are honored pins.
--
-- Resources are never Unload'd, preload-on-reference (loaded lazily, once, and kept): the
-- runtime's generalized `preload(node)` node-type hook (see runtime.lua's PreloadNode/
-- PreloadGraph) calls this node's `preload` on graph-restore and on control-commit so the
-- chosen resource is ready before Show ever fires; `run` also loads on demand as a backstop
-- for a resource referenced before any preload pass ran (e.g. via a connected wire, which the
-- preload hook — control-only — never sees).
--
-- BUILD-VERIFY: `Plugin.resources` is enumerable (assumed a name -> PluginResource map, iterated
-- with `pairs`) and `PluginResource:Load()` exists; `audio.SoundPlaybackParams` fields
-- (`volume`/`loops`/`bus`) match what's passed to `audio.Play` here. Neither is exercisable
-- under this sandbox's bare interpreter (no `Plugin`/`audio` globals) — confirm in-client.

local CustomSound = {}

-- Loaded-resource cache, keyed by the resource object itself (not its name): preload/run may
-- run many times across many nodes, but Load() should only ever be called once per resource.
local loaded = setmetatable({}, { __mode = "k" })

local function resolveResource(name)
    if name == nil or Plugin == nil or Plugin.resources == nil then
        return nil
    end
    return Plugin.resources[name]
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

-- Dropdown choices for the `resource` Control: every author-bundled resource name (sorted),
-- plus a leading "None" (value = nil) so an unconfigured node draws a real choice rather than
-- an empty box. Computed once at Register time — Plugin.resources is a fixed, author-bundled
-- set that doesn't change at runtime.
function CustomSound.ResourceChoices()
    local names = {}
    if Plugin ~= nil and Plugin.resources ~= nil then
        pcall(function()
            for name, _ in pairs(Plugin.resources) do
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
            { name = "volume", kind = "data", direction = "in", dataType = "number", default = 1.0 },
            { name = "loops", kind = "data", direction = "in", dataType = "number", default = 0 },
        },
        -- Runtime-called node-type hook (graph-restore / control-commit, see runtime.lua):
        -- `node` exposes GetControl(pinName), the same nodeHandle shape the dispatcher's
        -- filter already uses.
        preload = function(node)
            preloadResource(resolveResource(node.GetControl("resource")))
        end,
        run = function(ctx)
            local resource = resolveResource(ctx:In("resource"))
            if resource == nil then
                return
            end
            preloadResource(resource) -- on-demand backstop
            local volume = ctx:In("volume")
            if type(volume) ~= "number" then volume = 1.0 end
            local loops = ctx:In("loops")
            if type(loops) ~= "number" then loops = 0 end
            ---@type SoundPlaybackParams
            local params = audio.SoundPlaybackParams.new()
            params.volume = volume
            params.numLoops = loops
            params.audioBus = audio.AudioBus.SFX
            audio.Play(resource, params)
        end,
    })
end

return CustomSound
