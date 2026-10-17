-- Tag -> widget kind, recorded where the tag is registered.
-- presets.lua reads this table and does not draw.

local ControlKinds = {}

---@class Watchdog.ControlKind
---@field widget string
---@field choices { value: any, label: string }[]|nil

---@type table<string, Watchdog.ControlKind>
local byTag = {}

---@param tag string
---@param widget string
---@param choices { value: any, label: string }[]|nil
function ControlKinds.Record(tag, widget, choices)
    byTag[tag] = { widget = widget, choices = choices }
end

---@param tag string|nil
---@return string|nil
function ControlKinds.Widget(tag)
    if tag == nil then return nil end
    local recorded = byTag[tag]
    if recorded == nil then return nil end
    return recorded.widget
end

---@param tag string|nil
---@return { value: any, label: string }[]|nil
function ControlKinds.Choices(tag)
    if tag == nil then return nil end
    local recorded = byTag[tag]
    if recorded == nil then return nil end
    return recorded.choices
end

return ControlKinds
