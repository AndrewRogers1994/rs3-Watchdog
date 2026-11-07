-- Tag -> widget kind, recorded where the tag is registered.
-- The Preset library reads this table to decide which pins can be marked.
-- Copying a Preset into a Scope reads it to bake an answer. Neither draws.

local ControlKinds = {}

---@class Watchdog.ControlKind
---@field widget string
---@field choices { value: any, label: string }[]|nil
---@field choicesFn (fun(): { value: any, label: string }[])|nil

---@type table<string, Watchdog.ControlKind>
local byTag = {}

--- `choices` may be a function. The Variable dialog calls it when it opens, so a
--- list that depends on the live Pack registry is not frozen at load.
---@param tag string
---@param widget string
---@param choices ({ value: any, label: string }[]|fun(): { value: any, label: string }[])|nil
function ControlKinds.Record(tag, widget, choices)
    if type(choices) == "function" then
        byTag[tag] = { widget = widget, choicesFn = choices }
    else
        byTag[tag] = { widget = widget, choices = choices }
    end
end

---@param tag string|nil
---@return string|nil
function ControlKinds.Widget(tag)
    if tag == nil then return nil end
    local recorded = byTag[tag]
    if recorded == nil then return nil end
    return recorded.widget
end

-- An enum value and a checkbox boolean are both stored as given.
---@param widget string|nil
---@return boolean
function ControlKinds.IsChoiceWidget(widget)
    return widget == "enum" or widget == "checkbox"
end

---@param tag string|nil
---@return { value: any, label: string }[]|nil
function ControlKinds.Choices(tag)
    if tag == nil then return nil end
    local recorded = byTag[tag]
    if recorded == nil then return nil end
    if recorded.choicesFn ~= nil then
        return recorded.choicesFn()
    end
    return recorded.choices
end

return ControlKinds
