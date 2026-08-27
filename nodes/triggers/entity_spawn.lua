local Matcher = require("matcher")

local EntitySpawn = {}

---@class Watchdog.Payload.EntitySpawn
---@field kind "npc"|"player"|"object"        # which entity family fired
---@field transition "Spawned"|"Despawned"|nil # nil only for a zero-delta ObjStackEntityChanged
---@field entity any                          # the raw entity usertype (may be nil in a malformed event)
---@field name string|nil                     # display name (entity.displayName, or objType.name for objects)
---@field coordGrid CoordGrid|nil             # the entity's tile at the moment of the event
---@field count number|nil                    # stack count for object events; nil for npc/player

EntitySpawn.KINDS = {
    { value = "any",    label = "Any" },
    { value = "npc",    label = "NPC" },
    { value = "player", label = "Player" },
    { value = "object", label = "Object" },
}

function EntitySpawn.KindChoices()
    return EntitySpawn.KINDS
end

local function shape(kind, transition, entity, name, count)
    local coordGrid = nil
    if entity ~= nil then
        coordGrid = entity.coordGrid
    end
    return {
        kind = kind,
        transition = transition,
        entity = entity,
        name = name,
        coordGrid = coordGrid,
        count = count,
    }
end

local function entityTransform(kind, transition, entityField)
    return function(raw)
        local entity = raw ~= nil and raw[entityField] or nil
        local name = entity ~= nil and entity.displayName or nil
        return shape(kind, transition, entity, name, nil)
    end
end

local function objFields(raw)
    local entity = raw ~= nil and raw.objStackEntity or nil
    local objType = raw ~= nil and raw.objType or nil
    local name = objType ~= nil and objType.name or nil
    return entity, name
end

local function objTransform(transition)
    return function(raw)
        local entity, name = objFields(raw)
        local count = raw ~= nil and raw.count or nil
        return shape("object", transition, entity, name, count)
    end
end

-- Zero stack-count delta => nil transition (filter rejects). Restock is Spawned.
local function objChangedTransform(raw)
    local oldCount = raw ~= nil and raw.oldCount or 0
    local newCount = raw ~= nil and raw.newCount or 0
    local transition = nil
    if newCount > oldCount then
        transition = "Spawned"
    elseif newCount < oldCount then
        transition = "Despawned"
    end
    local entity, name = objFields(raw)
    return shape("object", transition, entity, name, newCount)
end

local function passesFilter(payload, node)
    if payload == nil or payload.transition == nil then
        return false
    end
    local wantKind = node.GetControl("kind")
    if wantKind ~= nil and wantKind ~= "any" and wantKind ~= payload.kind then
        return false
    end
    if not Matcher.Test(node.GetControl("nameMatch"), payload.name) then
        return false
    end
    return true
end

---@param registry LibNodeGraph.Registry
---@param runtime Watchdog.Runtime
function EntitySpawn.Register(registry, runtime)
    pcall(function()
        local Controls = require("ui/controls")
        Controls.Register("entity_spawn.kind", { widget = "enum", choices = EntitySpawn.KindChoices() })
    end)

    registry:RegisterNodeType("trigger.entity_spawn", {
        category = "trigger",
        displayName = "Entity Spawn",
        description = "Fires when an NPC / player / object spawns or despawns near you",
        pins = {
            { name = "kind", kind = "data", direction = "in", dataType = "entity_spawn.kind", default = "any" },
            { name = "nameMatch", kind = "data", direction = "in", dataType = "matcher",
              default = { needle = "", mode = "substring" } },
            { name = "Spawned", kind = "exec", direction = "out" },
            { name = "Despawned", kind = "exec", direction = "out" },
            { name = "entityKind", kind = "data", direction = "out", dataType = "string" },
            { name = "name", kind = "data", direction = "out", dataType = "string" },
            { name = "coordGrid", kind = "data", direction = "out", dataType = "coordgrid" },
            { name = "count", kind = "data", direction = "out", dataType = "number" },
            { name = "entity", kind = "data", direction = "out", dataType = "any" },
        },
        run = function(ctx)
            local payload = ctx.payload
            ctx:Out("entityKind", payload.kind)
            ctx:Out("name", payload.name)
            ctx:Out("coordGrid", payload.coordGrid)
            ctx:Out("count", payload.count)
            ctx:Out("entity", payload.entity)
            ctx:Fire(payload.transition)
        end,
    })

    runtime:BindTrigger("trigger.entity_spawn", {
        { event = "NPCEntityAdded",        transform = entityTransform("npc", "Spawned", "npcEntity"),      filter = passesFilter },
        { event = "NPCEntityRemoved",      transform = entityTransform("npc", "Despawned", "npcEntity"),    filter = passesFilter },
        { event = "PlayerEntityAdded",     transform = entityTransform("player", "Spawned", "playerEntity"),   filter = passesFilter },
        { event = "PlayerEntityRemoved",   transform = entityTransform("player", "Despawned", "playerEntity"), filter = passesFilter },
        { event = "ObjStackEntityAdded",   transform = objTransform("Spawned"),   filter = passesFilter },
        { event = "ObjStackEntityRemoved", transform = objTransform("Despawned"), filter = passesFilter },
        { event = "ObjStackEntityChanged", transform = objChangedTransform,       filter = passesFilter },
    })
end

return EntitySpawn
