local Controls = require("ui/controls")

local InventoryTrigger = {}

---@class Watchdog.InvSnapshotSlot
---@field name string|nil
---@field configName string|nil
---@field count number|nil

---@class Watchdog.InvSnapshot
---@field slots Watchdog.InvSnapshotSlot[]
---@field usedSlotCount integer
---@field slotCount integer

---@class Watchdog.Payload.InventoryUpdated
---@field inventoryType InvType|nil
---@field prevUsedSlots integer
---@field usedSlots integer
---@field isFull boolean
---@field isEmpty boolean
---@field prevSnapshot Watchdog.InvSnapshot
---@field snapshot Watchdog.InvSnapshot

---@class InventoryCache
---@field [InvType] Watchdog.InvSnapshot

---@type InventoryCache
local CACHE = {}

Controls.Register("invContainer", {
    widget = "enum",
    choices = {
        { value = config.Inv.INV, label = "Inventory" },
        { value = config.Inv.BANK, label = "Bank" },
    },
})

---@param value any
---@return integer
local function encodeInvContainer(value)
    if type(value) == "number" then
        return value
    end
    if value == config.Inv.BANK then
        return config.Inv.BANK.id
    end
    if value == config.Inv.INV then
        return config.Inv.INV.id
    end
    local id = value and value.id
    if type(id) == "number" then
        return id
    end
    return config.Inv.INV.id
end

---@param raw any
---@return InvType
local function decodeInvContainer(raw)
    local bank = config.Inv.BANK
    if raw == bank or (type(raw) == "number" and bank ~= nil and raw == bank.id) then
        return bank
    end
    return config.Inv.INV
end

---@param invType any
---@return Inv|nil
local function findInv(invType)
    if Inventory == nil or Inventory.Find == nil then
        return nil
    end
    return Inventory.Find(invType)
end

---@param raw InventoryUpdated|InventoryAdded|InventoryRemoved|nil
---@return integer
local function invTypeSize(raw)
    local invType = raw and raw.inv
    local size = invType and invType.size
    if type(size) == "number" then
        return size
    end
    return 0
end

local function copyOccupiedSlot(s)
    if s == nil or s.obj == nil then
        return nil
    end
    return {
        name = s.obj.name,
        configName = s.obj.configName,
        count = s.count,
    }
end

-- std.tostring calls Lua tostring(); this is what a Snapshot pin prints.
local SNAPSHOT_MT = {
    __tostring = function(snap)
        local slots = snap.slots or {}
        local used = snap.usedSlotCount or #slots
        local cap = snap.slotCount or 0
        local header = tostring(used) .. "/" .. tostring(cap)
        if #slots == 0 then
            return header
        end
        local parts = {}
        for i = 1, #slots do
            local s = slots[i]
            local name = s.name or s.configName or "?"
            if s.count ~= nil then
                parts[i] = name .. " x" .. tostring(s.count)
            else
                parts[i] = name
            end
        end
        return header .. ": " .. table.concat(parts, ", ")
    end,
}

---@param slots Watchdog.InvSnapshotSlot[]|nil
---@param used integer|nil
---@param cap integer|nil
---@return Watchdog.InvSnapshot
local function snapshotOf(slots, used, cap)
    return setmetatable({
        slots = slots or {},
        usedSlotCount = used or 0,
        slotCount = cap or 0,
    }, SNAPSHOT_MT)
end

---@param inv Inv|nil
---@param fallbackSize integer
---@return Watchdog.InvSnapshot
local function freezeInv(inv, fallbackSize)
    if inv == nil then
        return snapshotOf({}, 0, fallbackSize)
    end
    local slots = {}
    local cap = inv.slotCount or fallbackSize
    local rawSlots = inv.GetSlots and inv:GetSlots()
    if type(rawSlots) == "table" then
        local n = cap
        if #rawSlots > n then
            n = #rawSlots
        end
        for i = 1, n do
            local copied = copyOccupiedSlot(rawSlots[i])
            if copied ~= nil then
                slots[#slots + 1] = copied
            end
        end
    elseif inv.GetSlot ~= nil then
        for i = 1, cap do
            local copied = copyOccupiedSlot(inv:GetSlot(i))
            if copied ~= nil then
                slots[#slots + 1] = copied
            end
        end
    end
    return snapshotOf(slots, inv.usedSlotCount or 0, cap)
end

---@param raw InventoryUpdated|InventoryAdded|nil
---@return Watchdog.InvSnapshot
local function snapshotNow(raw)
    return freezeInv(findInv(raw and raw.inv), invTypeSize(raw))
end

---@param raw InventoryUpdated|nil
---@return Watchdog.Payload.InventoryUpdated
local transform = function(raw)
    local inventoryType = raw and raw.inv
    local current = snapshotNow(raw)
    local prev = CACHE[inventoryType]
    if prev == nil then
        prev = snapshotOf({}, 0, current.slotCount)
    end
    if inventoryType ~= nil then
        CACHE[inventoryType] = current
    end
    local used = current.usedSlotCount
    local cap = current.slotCount
    return {
        inventoryType = inventoryType,
        prevUsedSlots = prev.usedSlotCount,
        usedSlots = used,
        isFull = used == cap,
        isEmpty = used == 0,
        prevSnapshot = prev,
        snapshot = current,
    }
end

---@param raw InventoryAdded|nil
---@return { inventoryType: InvType|nil }
local function transformAdded(raw)
    local inventoryType = raw and raw.inv
    if inventoryType ~= nil then
        CACHE[inventoryType] = snapshotNow(raw)
    end
    return { inventoryType = inventoryType }
end

---@param raw InventoryRemoved|nil
---@return { inventoryType: InvType|nil }
local function transformRemoved(raw)
    local inventoryType = raw and raw.inv
    if inventoryType ~= nil then
        CACHE[inventoryType] = nil
    end
    return { inventoryType = inventoryType }
end

---@param payload Watchdog.Payload.InventoryUpdated|{ inventoryType: InvType|nil }
---@param node { GetControl: fun(pinName: string): any }
---@return boolean
local function containerMatches(payload, node)
    if payload == nil or payload.inventoryType == nil then
        return false
    end
    local sel = node.GetControl("container")
    if sel == nil then
        sel = config.Inv.INV
    end
    return payload.inventoryType == sel
end

local function neverFire()
    return false
end

---@param registry LibNodeGraph.Registry
---@param runtime Watchdog.Runtime
function InventoryTrigger.Register(registry, runtime)
    for k in pairs(CACHE) do
        CACHE[k] = nil
    end

    registry:RegisterDataType("invContainer", {
        encode = encodeInvContainer,
        decode = decodeInvContainer,
    })

    registry:RegisterNodeType("trigger.inventory", {
        category = "trigger",
        displayName = "Inventory",
        description = "Fires on every Inventory or Bank update for the chosen Container",
        pins = {
            { name = "container", kind = "data", direction = "in", dataType = "invContainer",
              label = "Container", default = config.Inv.INV },
            { name = "out", kind = "exec", direction = "out" },
            { name = "prevUsedSlots", kind = "data", direction = "out", dataType = "number",
              label = "Prev used slots" },
            { name = "usedSlots", kind = "data", direction = "out", dataType = "number",
              label = "Used slots" },
            { name = "isFull", kind = "data", direction = "out", dataType = "bool" },
            { name = "isEmpty", kind = "data", direction = "out", dataType = "bool" },
            { name = "prevSnapshot", kind = "data", direction = "out", dataType = "invSnapshot",
              label = "Prev snapshot" },
            { name = "snapshot", kind = "data", direction = "out", dataType = "invSnapshot",
              label = "Snapshot" },
        },
        ---@param ctx LibNodeGraph.RunContext<Watchdog.Payload.InventoryUpdated>
        run = function (ctx)
            local p = ctx.payload
            ctx:Out("prevUsedSlots", p.prevUsedSlots)
            ctx:Out("usedSlots", p.usedSlots)
            ctx:Out("isFull", p.isFull)
            ctx:Out("isEmpty", p.isEmpty)
            ctx:Out("prevSnapshot", p.prevSnapshot)
            ctx:Out("snapshot", p.snapshot)
            ctx:Fire("out")
        end,
    })

    runtime:BindTrigger("trigger.inventory", {
        { event = "InventoryUpdated", transform = transform, filter = containerMatches },
        { event = "InventoryAdded", transform = transformAdded, filter = neverFire },
        { event = "InventoryRemoved", transform = transformRemoved, filter = neverFire },
    })
end

return InventoryTrigger
