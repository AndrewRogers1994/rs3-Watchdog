-- Save as preset is parented to the Editor overlay.

local Dialog = require("src/ui/dialog")
local Presets = require("src/presets")
local PresetLabels = require("src/ui/preset_labels")
local Packs = require("src/packs")
local PackRows = require("src/pack_rows")
local ControlKinds = require("src/ui/control_kinds")
local PresetForm = require("src/ui/preset_form")

local PresetSaveDialog = {}

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
        return PresetLabels.NumberVariableText(Packs.live() or Packs.new(), value)
    end
    if ControlKinds.IsChoiceWidget(widget) then
        local choices = ControlKinds.Choices(pin.dataType) or {}
        local index = PackRows.MatchingChoice(choices, value)
        if index ~= nil then return choices[index].label end
        if type(value) == "table" then
            return PackRows.AudioClosedLabel(Packs.live() or Packs.new(), value)
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

---@param parent any
---@param opts PresetDialogs.SaveOpts
function PresetSaveDialog.mountSave(parent, opts)
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
            disabled = Presets.trim(nameText) == "",
            onClick = function()
                local name = ""
                pcall(function() name = Presets.trim(field:GetText()) end)
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

        local height = PresetForm.dialogHeight(parent, estimate)
        Dialog.mount(parent, {
            title = "Save as preset",
            width = PresetForm.DIALOG_WIDTH,
            height = height,
            content = function(mounted)
                local body = PresetForm.scrollBody(mounted, height)
                if body == nil then return end
                body:AddText("Preset name")
                field = body:AddTextField({
                    text = nameText or "",
                    maxLength = 80,
                    height = 30,
                    onChange = function(f)
                        local text = ""
                        pcall(function() text = f:GetText() or "" end)
                        if saveAction.setDisabled ~= nil then
                            saveAction.setDisabled(Presets.trim(text) == "")
                        end
                    end,
                })
                if #eligible == 0 then
                    body:AddText("Nothing on this Alert can be marked.")
                else
                    for _, mark in ipairs(marks) do
                        local captured = mark
                        body:AddText(PresetLabels.MarkLabel(graph, captured.nodeId, captured.pinName) or "")
                        body:AddText(valueText(graph, captured.nodeId, captured.pinName))
                        body:AddSimpleButton("Remove", function()
                            reopen(mounted, withoutMark(marks, captured.nodeId, captured.pinName), nil)
                        end)
                    end
                    if pick ~= nil and pick.kind == "node" then
                        body:AddText("Choose a node")
                        body:AddSimpleButton("Back", function()
                            reopen(mounted, marks)
                        end)
                        for _, group in ipairs(choices) do
                            local captured = group
                            local title = PresetLabels.NodeTitle(graph, captured.nodeId) or tostring(captured.nodeId)
                            body:AddSimpleButton(title, function()
                                reopen(mounted, marks, { kind = "pin", nodeId = captured.nodeId })
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
                        body:AddText("Choose a pin")
                        body:AddSimpleButton("Back", function()
                            reopen(mounted, marks, { kind = "node" })
                        end)
                        if group ~= nil then
                            for _, pinName in ipairs(group.pinNames) do
                                local capturedPin = pinName
                                local nodeId = group.nodeId
                                body:AddSimpleButton(PresetLabels.PinLabel(graph, nodeId, capturedPin), function()
                                    reopen(mounted, withMark(marks, nodeId, capturedPin), nil)
                                end)
                            end
                        end
                    elseif #choices > 0 then
                        body:AddSimpleButton("Mark Variable", function()
                            reopen(mounted, marks, { kind = "node" })
                        end)
                    end
                end
                feedback = body:AddText("")
            end,
            actions = {
                { label = "Cancel" },
                saveAction,
            },
        })
    end

    open({}, opts.initialName or "", nil)
end

return PresetSaveDialog
