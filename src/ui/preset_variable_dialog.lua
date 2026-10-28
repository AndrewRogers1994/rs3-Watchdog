-- The Variable dialog stacks on the same
-- parent as New alert so that dialog stays mounted and inert underneath.

local Dialog = require("src/ui/dialog")
local PresetLabels = require("src/ui/preset_labels")
local Packs = require("src/packs")
local PackRows = require("src/pack_rows")
local ControlKinds = require("src/ui/control_kinds")
local NumberField = require("src/ui/widgets/number_field")
local SoundEffect = require("src/ui/controls/sound_effect")
local SoundEffectValue = require("src/sound_effect_value")
local PresetForm = require("src/ui/preset_form")
local Text = require("src/text")

local PresetVariableDialog = {}

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

---@class PresetDialogs.VariableSlot
---@field widget string|nil
---@field raw string
---@field quantity number|nil
---@field value any
---@field choices { value: any, label: string }[]|nil
---@field soundRows Watchdog.PackSoundRow[]|nil
---@field stored any
---@field shown Watchdog.PackSoundRow|nil
---@field packTouched boolean|nil
---@field noneId integer|nil
---@field combo any
---@field mounting boolean|nil

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

-- Sound Effect stays a number wire. The Variable form still has to offer the
-- pack list that the node draws under the sound id.
---@param graph LibNodeGraph.Graph
---@param mark Watchdog.PresetVariable
---@return boolean
local function isSoundEffectMark(graph, mark)
    local node = graph.nodes[mark.nodeId]
    return node ~= nil and node.typeKey == "action.sound" and mark.pinName == "soundId"
end

---@param rows Watchdog.PackSoundRow[]
local function sortSoundRows(rows)
    table.sort(rows, function(left, right)
        if left.label ~= right.label then return left.label < right.label end
        if left.pack ~= right.pack then return left.pack < right.pack end
        return left.authorId < right.authorId
    end)
end

-- Typing a different id leaves the pack list. The same id keeps the row that
-- is showing, including the one captured when the dialog opened.
---@param slot PresetDialogs.VariableSlot
local function syncSoundText(slot)
    if slot.soundRows == nil or slot.shown == nil then return end
    local parsed = NumberField.Parse(slot.raw, slot.quantity)
    if parsed == slot.shown.soundId then return end
    slot.shown = nil
    slot.packTouched = true
    if slot.combo ~= nil and slot.combo.Select ~= nil and slot.noneId ~= nil then
        slot.combo:Select(slot.noneId, false)
    end
end

-- The answer is the value to store. An untouched pack list is a typed id.
-- Choosing a row or None is the player's explicit action.
---@param slot PresetDialogs.VariableSlot
---@return any
local function soundEffectAnswer(slot)
    local parsed = NumberField.Parse(slot.raw, slot.quantity)
    if slot.packTouched == true then
        if slot.shown ~= nil then
            return SoundEffectValue.apply(slot.stored, "row", slot.shown)
        end
        return SoundEffectValue.apply(slot.stored, "none", parsed)
    end
    return SoundEffectValue.apply(slot.stored, "number", parsed)
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
        -- A pack sound record shows its builtin sound id, so Create stays enabled.
        slot.raw = PresetLabels.NumberVariableText(Packs.live() or Packs.new(), value)
        if isSoundEffectMark(graph, mark) then
            slot.stored = value
            local packs = Packs.live() or Packs.new()
            local rows = PackRows.SoundEffectRows(packs)
            sortSoundRows(rows)
            slot.soundRows = rows
            local index = PackRows.SoundEffectSelectedRow(rows, value)
            if index ~= nil then slot.shown = rows[index] end
        end
    elseif widget == "matcher" then
        if type(value) == "table" and type(value.needle) == "string" then
            slot.raw = value.needle
        end
    elseif widget == "enum" then
        local label = nil
        if type(value) == "table" then
            local packs = Packs.live()
            if packs ~= nil then label = PackRows.AudioClosedLabel(packs, value) end
        end
        slot.value, slot.choices = PresetLabels.EnumSlotValue(
            value, ControlKinds.Choices(pin.dataType) or {}, pin.default, label)
    elseif type(value) == "string" then
        slot.raw = value
    end
    return slot
end

-- PrettyUI's combo always has a selection. None is the node's unselected pack
-- line, kept first so a raw sound id is not shown as the first pack sound.
local SOUND_NONE_ID = 1

---@param rows Watchdog.PackSoundRow[]
---@param entryID integer
---@param labelText string|nil
---@return Watchdog.PackSoundRow|nil
local function soundRowFromChoice(rows, entryID, labelText)
    local row = rows[entryID - 1]
    if row ~= nil and row.label == labelText then return row end
    for _, candidate in ipairs(rows) do
        if candidate.label == labelText then return candidate end
    end
    return nil
end

---@param createAction Watchdog.DialogAction
---@param slots PresetDialogs.VariableSlot[]
local function refreshCreate(createAction, slots)
    if createAction.setDisabled ~= nil then
        createAction.setDisabled(not numbersOk(slots))
    end
end

-- Number field, then the pack list, matching the node. No offers leave the
-- same message the node shows instead of an empty dropdown.
---@param body any
---@param slot PresetDialogs.VariableSlot
---@param field any
---@param slots PresetDialogs.VariableSlot[]
---@param createAction Watchdog.DialogAction
local function mountSoundPack(body, slot, field, slots, createAction)
    local rows = slot.soundRows or {}
    if #rows == 0 then
        body:AddText(SoundEffect.EMPTY_PACK)
        return
    end
    slot.noneId = SOUND_NONE_ID
    local entries = { { label = "None", id = SOUND_NONE_ID, order = 0 } }
    for i, row in ipairs(rows) do
        entries[#entries + 1] = { label = row.label, id = i + 1, order = i }
    end
    local selected = PackRows.SoundEffectSelectedRow(rows, slot.shown)
    if selected ~= nil then
        selected = selected + 1
    else
        selected = SOUND_NONE_ID
    end
    slot.mounting = true
    slot.combo = body:AddComboBox({
        entries = entries,
        selectedID = selected,
        onChange = function(_, entryID, labelText)
            if slot.mounting then return end
            if entryID == SOUND_NONE_ID or labelText == "None" then
                slot.shown = nil
                slot.packTouched = true
                return
            end
            local row = soundRowFromChoice(rows, entryID, labelText)
            if row == nil then return end
            slot.shown = row
            slot.packTouched = true
            slot.raw = tostring(row.soundId)
            slot.quantity = nil
            if field ~= nil and field.SetText ~= nil then
                field:SetText(slot.raw, false)
            end
            refreshCreate(createAction, slots)
        end,
    })
    slot.mounting = false
end

---@param parent any
---@param opts PresetDialogs.VariableOpts
function PresetVariableDialog.mountVariables(parent, opts)
    if parent == nil or opts == nil or opts.preset == nil then return end
    local preset = opts.preset
    local variables = preset.variables or {}
    local graph
    if LibNodeGraph ~= nil and LibNodeGraph.Deserialize ~= nil and opts.registry ~= nil then
        local ok, decoded = pcall(function()
            return LibNodeGraph.Deserialize(preset.graph, opts.registry, { onUnknown = "placeholder" })
        end)
        if ok then
            graph = decoded
            Text.StripGraphText(graph)
        end
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
                    if slot.soundRows ~= nil then
                        answers[i] = soundEffectAnswer(slot)
                    else
                        answers[i] = { raw = slot.raw, quantity = slot.quantity }
                    end
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

    local soundExtra = 0
    for _, slot in ipairs(slots) do
        if slot.soundRows ~= nil then soundExtra = soundExtra + 40 end
    end
    local estimate = 200 + math.max(#variables, 1) * 80 + soundExtra
    local height = PresetForm.dialogHeight(parent, estimate)
    Dialog.mount(parent, {
        title = preset.name or "",
        width = PresetForm.DIALOG_WIDTH,
        height = height,
        content = function(mounted)
            local body = PresetForm.scrollBody(mounted, height)
            if body == nil then return end
            if graph == nil then
                body:AddText("Could not copy the preset graph.")
            else
                for index, mark in ipairs(variables) do
                    local slot = slots[index]
                    local label = PresetLabels.MarkLabel(graph, mark.nodeId, mark.pinName) or mark.pinName
                    body:AddText(label)
                    if slot.widget == "enum" then
                        local choices = slot.choices or {}
                        local selected = PackRows.MatchingChoice(choices, slot.value) or 1
                        local entries = {}
                        for i, choice in ipairs(choices) do
                            entries[i] = { label = choice.label, id = i, order = i }
                        end
                        body:AddComboBox({
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
                        local field = body:AddTextField({
                            text = slot.raw,
                            height = 30,
                            maxLength = 128,
                            filter = slot.widget == "number" and numericFilter() or nil,
                            onChange = function(f)
                                slot.raw, slot.quantity = readField(f)
                                syncSoundText(slot)
                                refreshCreate(createAction, slots)
                            end,
                        })
                        if slot.soundRows ~= nil then
                            mountSoundPack(body, slot, field, slots, createAction)
                        end
                    end
                end
            end
            feedback = body:AddText("")
        end,
        actions = {
            { label = "Cancel" },
            createAction,
        },
    })
end

return PresetVariableDialog
