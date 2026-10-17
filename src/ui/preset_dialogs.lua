-- Save as preset and the Variable dialog. Both use Dialog; this file does not add a dialog harness.
-- Save as preset is parented to the Editor overlay. The Variable dialog stacks on the same
-- parent as New alert so that dialog stays mounted and inert underneath.

local Dialog = require("src/ui/dialog")
local Presets = require("src/presets")
local ControlKinds = require("src/ui/control_kinds")
local NumberField = require("src/ui/widgets/number_field")

local PresetDialogs = {}

local DIALOG_WIDTH = 460

---@param name string|nil
---@return string
local function trimName(name)
    if type(name) ~= "string" then return "" end
    return (name:match("^%s*(.-)%s*$"))
end

---@param win any
---@param width integer
---@param estimate integer
local function fit(win, width, estimate)
    if win == nil or win.SetSize == nil then return end
    local height = estimate
    local content = win.contentHeight
    if type(content) == "number" and content + 100 > height then
        height = content + 100
    end
    if height < 220 then height = 220 end
    if height > 1100 then height = 1100 end
    win.maxHeight = height
    win.maxWidth = width
    win:SetSize(width, height)
end

---@param field any
---@return string raw
---@return number|nil quantity
local function readField(field)
    local raw = ""
    pcall(function() raw = field:GetText() or "" end)
    local quantity
    pcall(function()
        local dock = field.dock
        local root = dock ~= nil and dock.root or nil
        if root ~= nil then quantity = root.contentQuantity end
    end)
    return raw, quantity
end

---@return any
local function numericFilter()
    if ui ~= nil and ui.InputFieldFilterMode ~= nil and ui.InputFieldFilterMode.NUMERIC ~= nil then
        return ui.InputFieldFilterMode.NUMERIC
    end
    return "NUMERIC"
end

---@param graph LibNodeGraph.Graph
---@param nodeId integer
---@param pinName string
---@return string
local function valueText(graph, nodeId, pinName)
    local pin
    for _, candidate in ipairs(graph:GetPins(nodeId) or {}) do
        if candidate.name == pinName then
            pin = candidate
            break
        end
    end
    if pin == nil then return "" end
    local widget = ControlKinds.Widget(pin.dataType)
    local value = graph:GetControl(nodeId, pinName)
    if widget == "matcher" then
        if type(value) == "table" and type(value.needle) == "string" then
            return value.needle
        end
        return ""
    end
    if widget == "number" then
        return NumberField.Format(value)
    end
    if widget == "enum" then
        for _, choice in ipairs(ControlKinds.Choices(pin.dataType) or {}) do
            if choice.value == value then return choice.label end
        end
        if value == nil then return "" end
        return tostring(value)
    end
    if value == nil then return "" end
    return tostring(value)
end

-- Eligible order, not click order. Marks the player could not have chosen are dropped.
---@param graph LibNodeGraph.Graph
---@param marks Watchdog.PresetVariable[]|nil
---@return Watchdog.PresetVariable[]
local function sortedMarks(graph, marks)
    local want = {}
    for _, mark in ipairs(marks or {}) do
        want[tostring(mark.nodeId) .. "\0" .. mark.pinName] = true
    end
    local out = {}
    for _, mark in ipairs(Presets.Eligible(graph)) do
        local key = tostring(mark.nodeId) .. "\0" .. mark.pinName
        if want[key] then
            out[#out + 1] = { nodeId = mark.nodeId, pinName = mark.pinName }
            want[key] = nil
        end
    end
    return out
end

---@param graph LibNodeGraph.Graph
---@param marks Watchdog.PresetVariable[]
---@param nodeId integer
---@param pinName string
---@return Watchdog.PresetVariable[]
local function withoutMark(marks, nodeId, pinName)
    local out = {}
    for _, mark in ipairs(marks) do
        if mark.nodeId ~= nodeId or mark.pinName ~= pinName then
            out[#out + 1] = mark
        end
    end
    return out
end

---@param marks Watchdog.PresetVariable[]
---@param nodeId integer
---@param pinName string
---@return Watchdog.PresetVariable[]
local function withMark(marks, nodeId, pinName)
    local out = {}
    for i, mark in ipairs(marks) do
        out[i] = mark
    end
    out[#out + 1] = { nodeId = nodeId, pinName = pinName }
    return out
end

---@class PresetDialogs.SaveOpts
---@field graph LibNodeGraph.Graph
---@field initialName string|nil
---@field onSave fun(name: string, marks: Watchdog.PresetVariable[]|nil): Watchdog.Preset|nil, string|nil

---@param parent any
---@param opts PresetDialogs.SaveOpts
function PresetDialogs.mountSave(parent, opts)
    if parent == nil or opts == nil or opts.graph == nil then return end
    local graph = opts.graph
    local field

    ---@param marks Watchdog.PresetVariable[]
    ---@param nameText string
    ---@param pick { kind: string, nodeId: integer|nil }|nil
    local function open(marks, nameText, pick)
        marks = sortedMarks(graph, marks)
        local eligible = Presets.Eligible(graph)
        local choices = Presets.UnmarkedNodes(eligible, marks)
        local extra = 1
        if pick ~= nil and pick.kind == "node" then
            extra = 1 + #choices
        elseif pick ~= nil and pick.kind == "pin" then
            extra = 2
            for _, group in ipairs(choices) do
                if group.nodeId == pick.nodeId then
                    extra = 2 + #group.pinNames
                    break
                end
            end
        end
        local estimate = 240 + #marks * 96 + extra * 36
        local feedback
        local saveAction = {
            label = "Save",
            variant = "positive",
            disabled = trimName(nameText) == "",
            onClick = function()
                local name = ""
                pcall(function() name = trimName(field:GetText()) end)
                if name == "" then return false end
                local preset, err
                if #marks == 0 then
                    preset, err = opts.onSave(name, nil)
                else
                    preset, err = opts.onSave(name, marks)
                end
                if preset == nil then
                    if feedback ~= nil then
                        feedback.content = err or "Could not save the preset."
                    end
                    return false
                end
                return true
            end,
        }

        ---@param mounted any
        ---@param nextMarks Watchdog.PresetVariable[]
        ---@param nextPick { kind: string, nodeId: integer|nil }|nil
        local function reopen(mounted, nextMarks, nextPick)
            local name = nameText
            if field ~= nil then
                pcall(function() name = field:GetText() or "" end)
            end
            local ok = pcall(function() mounted:Destroy() end)
            if ok then open(nextMarks, name, nextPick) end
        end

        Dialog.mount(parent, {
            title = "Save as preset",
            width = DIALOG_WIDTH,
            height = estimate,
            content = function(mounted)
                mounted:AddText("Preset name")
                field = mounted:AddTextField({
                    text = nameText or "",
                    maxLength = 80,
                    height = 30,
                    onChange = function(f)
                        local text = ""
                        pcall(function() text = f:GetText() or "" end)
                        if saveAction.setDisabled ~= nil then
                            saveAction.setDisabled(trimName(text) == "")
                        end
                    end,
                })
                if #eligible == 0 then
                    mounted:AddText("Nothing on this Alert can be marked.")
                else
                    for _, mark in ipairs(marks) do
                        local captured = mark
                        mounted:AddText(Presets.MarkLabel(graph, captured.nodeId, captured.pinName) or "")
                        mounted:AddText(valueText(graph, captured.nodeId, captured.pinName))
                        mounted:AddSimpleButton("Remove", function()
                            reopen(mounted, withoutMark(marks, captured.nodeId, captured.pinName), nil)
                        end)
                    end
                    if pick ~= nil and pick.kind == "node" then
                        mounted:AddText("Choose a node")
                        for _, group in ipairs(choices) do
                            local captured = group
                            local title = Presets.NodeTitle(graph, captured.nodeId) or tostring(captured.nodeId)
                            mounted:AddSimpleButton(title, function()
                                if #captured.pinNames == 1 then
                                    reopen(mounted, withMark(marks, captured.nodeId, captured.pinNames[1]), nil)
                                else
                                    reopen(mounted, marks, { kind = "pin", nodeId = captured.nodeId })
                                end
                            end)
                        end
                    elseif pick ~= nil and pick.kind == "pin" then
                        local group
                        for _, candidate in ipairs(choices) do
                            if candidate.nodeId == pick.nodeId then
                                group = candidate
                                break
                            end
                        end
                        mounted:AddText("Choose a pin")
                        mounted:AddSimpleButton("Back", function()
                            reopen(mounted, marks, { kind = "node" })
                        end)
                        if group ~= nil then
                            for _, pinName in ipairs(group.pinNames) do
                                local capturedPin = pinName
                                local nodeId = group.nodeId
                                mounted:AddSimpleButton(Presets.PinLabel(graph, nodeId, capturedPin), function()
                                    reopen(mounted, withMark(marks, nodeId, capturedPin), nil)
                                end)
                            end
                        end
                    elseif #choices > 0 then
                        mounted:AddSimpleButton("Add", function()
                            reopen(mounted, marks, { kind = "node" })
                        end)
                    end
                end
                feedback = mounted:AddText("")
                fit(mounted, DIALOG_WIDTH, estimate)
            end,
            actions = {
                { label = "Cancel" },
                saveAction,
            },
        })
    end

    open({}, opts.initialName or "", nil)
end

---@class PresetDialogs.VariableSlot
---@field widget string|nil
---@field raw string
---@field quantity number|nil
---@field value any
---@field choices { value: any, label: string }[]|nil

---@param slots PresetDialogs.VariableSlot[]
---@return boolean
local function numbersOk(slots)
    for _, slot in ipairs(slots) do
        if slot.widget == "number" and NumberField.Parse(slot.raw, slot.quantity) == nil then
            return false
        end
    end
    return true
end

---@param graph LibNodeGraph.Graph
---@param mark Watchdog.PresetVariable
---@return PresetDialogs.VariableSlot
local function slotFor(graph, mark)
    ---@type PresetDialogs.VariableSlot
    local slot = { widget = nil, raw = "", quantity = nil, value = nil, choices = nil }
    local pin
    for _, candidate in ipairs(graph:GetPins(mark.nodeId) or {}) do
        if candidate.name == mark.pinName then
            pin = candidate
            break
        end
    end
    if pin == nil then return slot end
    local widget = ControlKinds.Widget(pin.dataType)
    slot.widget = widget
    local value = graph:GetControl(mark.nodeId, mark.pinName)
    if widget == "number" then
        slot.raw = NumberField.Format(value)
    elseif widget == "matcher" then
        if type(value) == "table" and type(value.needle) == "string" then
            slot.raw = value.needle
        end
    elseif widget == "enum" then
        local choices = ControlKinds.Choices(pin.dataType) or {}
        slot.choices = choices
        local initial = Presets.EnumInitial(value, choices, pin.default)
        local found = false
        for _, choice in ipairs(choices) do
            if choice.value == initial then
                found = true
                break
            end
        end
        if found then
            slot.value = initial
        elseif choices[1] ~= nil then
            slot.value = choices[1].value
        else
            slot.value = initial
        end
    elseif type(value) == "string" then
        slot.raw = value
    end
    return slot
end

---@class PresetDialogs.VariableOpts
---@field preset Watchdog.Preset
---@field registry LibNodeGraph.Registry
---@field onCreate fun(answers: any[]): integer|nil, string|nil

---@param parent any
---@param opts PresetDialogs.VariableOpts
function PresetDialogs.mountVariables(parent, opts)
    if parent == nil or opts == nil or opts.preset == nil then return end
    local preset = opts.preset
    local variables = preset.variables or {}
    local graph
    if LibNodeGraph ~= nil and LibNodeGraph.Deserialize ~= nil and opts.registry ~= nil then
        local ok, decoded = pcall(function()
            return LibNodeGraph.Deserialize(preset.graph, opts.registry, { onUnknown = "placeholder" })
        end)
        if ok then graph = decoded end
    end

    ---@type PresetDialogs.VariableSlot[]
    local slots = {}
    if graph ~= nil then
        for _, mark in ipairs(variables) do
            slots[#slots + 1] = slotFor(graph, mark)
        end
    end

    local feedback
    local createAction = {
        label = "Create",
        variant = "positive",
        disabled = not numbersOk(slots),
        onClick = function()
            if not numbersOk(slots) then return false end
            local answers = {}
            for i, slot in ipairs(slots) do
                if slot.widget == "number" then
                    answers[i] = { raw = slot.raw, quantity = slot.quantity }
                elseif slot.widget == "enum" then
                    answers[i] = slot.value
                else
                    answers[i] = slot.raw
                end
            end
            local id, err = opts.onCreate(answers)
            if id == nil then
                if feedback ~= nil then
                    feedback.content = err or "Could not create the alert."
                end
                return false
            end
            return true
        end,
    }

    local estimate = 200 + math.max(#variables, 1) * 80
    Dialog.mount(parent, {
        title = preset.name or "",
        width = DIALOG_WIDTH,
        height = estimate,
        content = function(mounted)
            if graph == nil then
                mounted:AddText("Could not copy the preset graph.")
            else
                for index, mark in ipairs(variables) do
                    local slot = slots[index]
                    local label = Presets.MarkLabel(graph, mark.nodeId, mark.pinName) or mark.pinName
                    mounted:AddText(label)
                    if slot.widget == "enum" then
                        local choices = slot.choices or {}
                        local selected = 1
                        for i, choice in ipairs(choices) do
                            if choice.value == slot.value then
                                selected = i
                                break
                            end
                        end
                        local entries = {}
                        for i, choice in ipairs(choices) do
                            entries[i] = { label = choice.label, id = i, order = i }
                        end
                        mounted:AddComboBox({
                            entries = entries,
                            selectedID = selected,
                            onChange = function(_, entryID, labelText)
                                local choice = choices[entryID]
                                if choice == nil or choice.label ~= labelText then
                                    choice = nil
                                    for _, candidate in ipairs(choices) do
                                        if candidate.label == labelText then
                                            choice = candidate
                                            break
                                        end
                                    end
                                end
                                if choice ~= nil then slot.value = choice.value end
                            end,
                        })
                    else
                        mounted:AddTextField({
                            text = slot.raw,
                            height = 30,
                            maxLength = 128,
                            filter = slot.widget == "number" and numericFilter() or nil,
                            onChange = function(f)
                                slot.raw, slot.quantity = readField(f)
                                if createAction.setDisabled ~= nil then
                                    createAction.setDisabled(not numbersOk(slots))
                                end
                            end,
                        })
                    end
                end
            end
            feedback = mounted:AddText("")
            fit(mounted, DIALOG_WIDTH, estimate)
        end,
        actions = {
            { label = "Cancel" },
            createAction,
        },
    })
end

return PresetDialogs
