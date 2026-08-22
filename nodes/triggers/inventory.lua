local Matcher = require('matcher')

---@class InventoryCache.InventoryCacheEntry
---@field slots InvSlot[]
---@field slotCount Int

---@class InventoryCache
---@field [InvType] InventoryCache.InventoryCacheEntry

---@type InventoryCache
local CACHE = {}

Event.InventoryAdded.Subscribe("inventory.added", function(event)
    print("InventoryAdded:", event.inv.configName)
    local inv = Inventory.Find(event.inv)
    if inv == nil or not inv.isValid then
        return
    end
    print(type(inv))

    if not CACHE[event.inv] then
        CACHE[event.inv] = { slots = {} }
    end

    local slots = inv:GetSlots()
    for i, slot in ipairs(slots) do
        CACHE[event.inv].slots[i] = slot
    end
end)

-- idk if i want to do this?
Event.InventoryRemoved.Subscribe("inventory.removed", function(event)
    print("InventoryRemoved:", event.inv.configName)
    CACHE[event.inv] = nil
end)

local InventoryTrigger = {}

---@class Watchdog.Payload.InventoryUpdated
---@field inventoryType InvType The inventory type that was updated.
---@field prevSlotCount Int The number of used slots before the update
---@field newSlotCount Int The number of used slots after the update
---@field slotDiff { slotIndex: Int, oldSlot: InvSlot, newSlot: InvSlot, diffCount: Int, isDiffObj: Bool }[] A list of slot changes, each containing the slot index, the old and new InvSlot data, the difference in count, and whether the object in the slot changed.

local function inventoryModeChoices()
    local choices = {
        { value = "full", label = "Full" },
        { value = "empty", label = "Empty" },
        { value = "count", label = "Count" },
        { value = "amount", label = "Amount" },
        { value = "changed", label = "Changed By" },
    }
    return choices
end

local Controls = require("ui/controls")
Controls.Register("inventoryMode", {
    widget = "enum",
    choices = inventoryModeChoices(),
})

---@param raw InventoryUpdated
---@return Watchdog.Payload.InventoryUpdated
local transform = function(raw)
    local inv = Inventory.Find(raw.inv)
    ---@type Watchdog.Payload.InventoryUpdated
    local retData = {
        inventoryType = raw.inv,
        prevSlotCount = CACHE[raw.inv].slotCount,
        newSlotCount = -1,
        slotDiff = {}
    }


    for i, slotIdx in ipairs(raw.slotsUpdated) do
        local slot = inv:GetSlot(slotIdx)
        if slot ~= nil then
            local oldSlotData = CACHE[raw.inv].slots[slotIdx]
            local diff = slot.count - oldSlotData.count
            local isDiffObj = slot.obj.id ~= oldSlotData.obj.id
            -- update the cache with the new slot data
            CACHE[raw.inv].slots[slotIdx] = slot

            table.insert(retData.slotDiff, {
                slotIndex = slotIdx,
                oldSlot = oldSlotData,
                newSlot = slot,
                diffCount = diff,
                isDiffObj = isDiffObj
            })
        else
            -- TODO: check this
            CACHE[raw.inv].slots[slotIdx] = nil
        end
    end

    CACHE[raw.inv].slotCount = inv.usedSlotCount
    retData.newSlotCount = inv.usedSlotCount

    return retData
end

---@param registry LibNodeGraph.Registry
---@param runtime Watchdog.Runtime
function InventoryTrigger.Register(registry, runtime)
    local itemNamePin = { name = "nameMatch", kind = "data", direction = "in", dataType = "matcher", default = { needle = "", mode = "substring" } }
    local countPin = { name = "count", kind = "data", direction = "in", dataType = "number" }
    local edgeOnlyPin = { name = "edgeOnly", kind = "data", direction = "in", dataType = "boolean" }
    local outPin = { name = "out", kind = "exec", direction = "out" }
    local itemPin = { name = "item", kind = "data", direction = "out", dataType = "string" }
    local countOfMatchedPin = { name = "countOfMatched", kind = "data", direction = "out", dataType = "number" }
    local changedByPin = { name = "changedBy", kind = "data", direction = "out", dataType = "number" }
    registry:RegisterNodeType("trigger.inventory", {
        category = "trigger",
        displayName = "Inventory",
        description = "Inventory changes",
        modes = {
            { key = "full", label = "Full", pins = { edgeOnlyPin, outPin } },
            { key = "empty", label = "Empty", pins = { edgeOnlyPin, outPin } },
            { key = "count", label = "Count", pins = { countPin, edgeOnlyPin, outPin, changedByPin } },
            { key = "amount", label = "Amount", pins = { itemNamePin, countPin, edgeOnlyPin, outPin, itemPin, countOfMatchedPin, changedByPin } },
            { key = "changed", label = "Changed By", pins = { itemNamePin, countPin, edgeOnlyPin, outPin, itemPin, countOfMatchedPin, changedByPin } },
        },
        defaultMode = "full",
        ---@param ctx LibNodeGraph.RunContext<Watchdog.Payload.InventoryUpdated>
        run = function (ctx)
            local p = ctx.payload
            if ctx.mode == "full" or ctx.mode == "empty" then
                -- nothing to output
            elseif ctx.mode == "count" then
                ctx:Out("countOfMatched", p.newSlotCount)
                ctx:Out("changedBy", p.newSlotCount - p.prevSlotCount)
            elseif ctx.mode == "amount" or ctx.mode == "changed" then
                local totalCount = 0
                local totalChanged = 0
                for _, slotChange in ipairs(p.slotDiff) do
                    totalCount = totalCount + slotChange.newSlot.count
                    totalChanged = totalChanged + slotChange.diffCount
                end
                -- output the item name that triggered the event
                ctx:Out("item", p.slotDiff[1] and p.slotDiff[1].newSlot.obj.name or "")
                ctx:Out("countOfMatched", totalCount)
                ctx:Out("changedBy", totalChanged)
            end
            ctx:Fire("out")
        end
    })

    runtime:BindTrigger("trigger.inventory", {
        {
            event = "InventoryUpdated",
            ---@param payload Watchdog.Payload.InventoryUpdated
            filter = function(payload, node)
                -- only support INV type right now
                if payload.inventoryType ~= config.Inv.INV then
                    print("not supported inv type:", payload.inventoryType.configName)
                    return false
                end
                local mode = node.GetControl("mode")
                local itemMatcher = node.GetControl("nameMatch")
                local count = node.GetControl("count")
                local edgeOnly = node.GetControl("edgeOnly")

                if mode == "full" then
                    if payload.newSlotCount == payload.inventoryType.size then
                        if edgeOnly then
                            return payload.prevSlotCount < payload.inventoryType.size
                        end
                        return true
                    end
                    return false
                elseif mode == "empty" then
                    if payload.newSlotCount == 0 then
                        if edgeOnly then
                            return payload.prevSlotCount > 0
                        end
                        return true
                    end
                    return false
                elseif mode == "count" then
                    if payload.newSlotCount == count then
                        if edgeOnly then
                            return payload.prevSlotCount ~= count
                        end
                        return true
                    end
                    return false
                elseif mode == "amount" then
                    local totalCount = 0
                    for _, slotChange in ipairs(payload.slotDiff) do
                        if Matcher.Test(itemMatcher, slotChange.newSlot.obj.name) then
                            totalCount = totalCount + slotChange.newSlot.count
                        end
                    end
                    if totalCount == count then
                        if edgeOnly then
                            return payload.prevSlotCount ~= count
                        end
                        return true
                    end
                    return false
                elseif mode == "changed" then
                    local totalChanged = 0
                    for _, slotChange in ipairs(payload.slotDiff) do
                        if slotChange.newSlot.obj.name == itemMatcher then
                            totalChanged = totalChanged + slotChange.diffCount
                        end
                    end
                    if totalChanged == count then
                        if edgeOnly then
                            return payload.prevSlotCount ~= count
                        end
                        return true
                    end
                    return false
                end

                return true
            end,
            transform = transform,
        }
    })
end

return InventoryTrigger
