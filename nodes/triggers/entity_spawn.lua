-- entity_spawn.lua — the Entity Spawn trigger (`trigger.entity_spawn`, #32): one node fanning
-- in all 7 entity channels — NPC/Player/ObjStack × Added/Removed plus ObjStackEntityChanged —
-- abstracted to **Spawned / Despawned** exec pins so the user never wires raw add/remove/change
-- channels. It rides the #24 event dispatcher (not the poll model): each channel is one
-- `{ event = "..." }` binding whose `transform` shapes the raw event into a shared
-- `Watchdog.Payload.EntitySpawn`, and a shared `filter` gates every node by its `kind` dropdown
-- and `nameMatch` contains-filter.
--
-- Pipeline split (why the work lives where it does):
--   * transform (once/event, per channel) — reads the channel's own raw fields and produces the
--     unified payload. The Added/Removed channels carry a fixed transition (Spawned/Despawned);
--     ObjStackEntityChanged resolves its transition by **delta sign** (`newCount - oldCount > 0`
--     → Spawned, `< 0` → Despawned; a mid-stack restock counts as Spawned, by design). A zero
--     delta yields a nil transition, which the filter rejects (no fire).
--   * filter (per node, shared) — the `kind` match (NPC / Player / Object / Any) and the
--     `nameMatch` plain-substring contains-filter, both read from the node's own controls. Also
--     the nil-transition guard for a degenerate ObjStackEntityChanged.
--   * run (per matched node) — surfaces kind/name/coordGrid/count/entity on the data outs and
--     fires the resolved transition's exec pin (Spawned or Despawned).
--
-- Registered from main.lua with one
-- `require("nodes/triggers/entity_spawn").Register(registry, runtime)` line: both the node type
-- and all 7 event bindings are declared here, so no dispatcher or main.lua edits are needed
-- beyond that require (the #24 self-contained-trigger architecture). Each distinct channel is
-- subscribed exactly once no matter how many entity_spawn nodes exist (dispatcher reverse-index).

local EntitySpawn = {}

-- The unified payload every channel's transform produces and the node's run consumes. `entity`
-- is the raw client usertype (NPCEntity / PlayerEntity / ObjStackEntity) for downstream nodes
-- that want the full object; the scalar fields are the pre-shaped conveniences.
---@class Watchdog.Payload.EntitySpawn
---@field kind "npc"|"player"|"object"        # which entity family fired
---@field transition "Spawned"|"Despawned"|nil # nil only for a zero-delta ObjStackEntityChanged
---@field entity any                          # the raw entity usertype (may be nil in a malformed event)
---@field name string|nil                     # display name (entity.displayName, or objType.name for objects)
---@field coordGrid CoordGrid|nil             # the entity's tile at the moment of the event
---@field count number|nil                    # stack count for object events; nil for npc/player

-- The `kind` dropdown choices (value stored on the Control, label shown in the enum widget).
-- "any" is the default so a fresh node reacts to every family until narrowed.
EntitySpawn.KINDS = {
    { value = "any",    label = "Any" },
    { value = "npc",    label = "NPC" },
    { value = "player", label = "Player" },
    { value = "object", label = "Object" },
}

function EntitySpawn.KindChoices()
    return EntitySpawn.KINDS
end

-- Shared shaper: one payload table from the resolved fields. `coordGrid` is pulled off the entity
-- (nil-guarded, since a malformed event could omit it), so every channel derives it uniformly.
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

-- NPC/Player channels: a fixed transition, the entity under `raw.<family>Entity`, and the name
-- straight off the entity's `displayName`. `entityField` is "npcEntity" / "playerEntity".
local function entityTransform(kind, transition, entityField)
    return function(raw)
        local entity = raw ~= nil and raw[entityField] or nil
        local name = entity ~= nil and entity.displayName or nil
        return shape(kind, transition, entity, name, nil)
    end
end

-- Shared object-event extraction: the stack entity and its display name (off the accompanying
-- `raw.objType`), the two fields every objStack channel carries. Both objStack transforms below
-- read the same pair, so the nil-guarded reads live in one place.
local function objFields(raw)
    local entity = raw ~= nil and raw.objStackEntity or nil
    local objType = raw ~= nil and raw.objType or nil
    local name = objType ~= nil and objType.name or nil
    return entity, name
end

-- ObjStack Added/Removed: a fixed transition, plus the event's `count`.
local function objTransform(transition)
    return function(raw)
        local entity, name = objFields(raw)
        local count = raw ~= nil and raw.count or nil
        return shape("object", transition, entity, name, count)
    end
end

-- ObjStackEntityChanged: transition resolved by delta sign. A restock (newCount grows) counts as
-- Spawned, a partial pickup (newCount shrinks) as Despawned; an exact-zero delta yields a nil
-- transition the filter rejects. `count` surfaces the post-change stack size (`newCount`).
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

-- The one filter shared across all 7 bindings: gate by the node's `kind` dropdown and `nameMatch`
-- contains-filter. Also drops a nil-transition payload (a zero-delta ObjStackEntityChanged), which
-- has nothing to fire. `nameMatch` is a plain substring (`plain = true`) so a name with Lua-pattern
-- metacharacters is matched literally.
local function passesFilter(payload, node)
    if payload == nil or payload.transition == nil then
        return false
    end
    local wantKind = node.GetControl("kind")
    if wantKind ~= nil and wantKind ~= "any" and wantKind ~= payload.kind then
        return false
    end
    local needle = node.GetControl("nameMatch")
    if needle ~= nil and needle ~= "" then
        local name = payload.name
        if type(name) ~= "string" or string.find(name, needle) == nil then
            return false
        end
    end
    return true
end

---@param registry LibNodeGraph.Registry
function EntitySpawn.Register(registry, runtime)
    -- Register the `kind` enum Control Spec (curated dropdown), reusing ADR-0004's Control Spec
    -- seam the same way action.popup does. Guarded so a headless/test require (no ui layer) still
    -- registers the node itself.
    pcall(function()
        local Controls = require("ui/controls")
        Controls.Register("entity_spawn.kind", { widget = "enum", choices = EntitySpawn.KindChoices() })
    end)

    registry:RegisterNodeType("trigger.entity_spawn", {
        category = "trigger",
        displayName = "Entity Spawn",
        description = "Fires when an NPC / player / object spawns or despawns near you",
        pins = {
            -- Both gate in `filter`. `kind` is a config dropdown (enum widget); `nameMatch` is a
            -- plain contains-filter ("" => match every name).
            { name = "kind", kind = "data", direction = "in", dataType = "entity_spawn.kind", default = "any" },
            { name = "nameMatch", kind = "data", direction = "in", dataType = "string", default = "" },
            { name = "Spawned", kind = "exec", direction = "out" },
            { name = "Despawned", kind = "exec", direction = "out" },
            -- Shaped conveniences plus the raw entity, for downstream nodes. The kind output is
            -- named `entityKind` (not `kind`) since a node type can't reuse the input control's
            -- pin name — it's the resolved family, most useful when the `kind` filter is "Any".
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
