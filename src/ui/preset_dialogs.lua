-- Save as preset, the Variable dialog, and New alert. All three use Dialog; this file does not add a dialog harness.
-- Save as preset is parented to the Editor overlay. The Variable dialog stacks on the same
-- parent as New alert so that dialog stays mounted and inert underneath.
-- The form scrolls inside a SimpleView. Dialog itself is unchanged; the window's own
-- scrollbar is turned off so Cancel and Save stay on screen.

local Dialog = require("src/ui/dialog")
local Confirm = require("src/ui/confirm")
local Theme = require("src/ui/theme")
local Presets = require("src/presets")
local PresetLabels = require("src/ui/preset_labels")
local Packs = require("src/packs")
local PackRows = require("src/pack_rows")
local ControlKinds = require("src/ui/control_kinds")
local NumberField = require("src/ui/widgets/number_field")
local SoundEffect = require("src/ui/controls/sound_effect")
local SoundEffectValue = require("src/sound_effect_value")

local PresetDialogs = {}

local DIALOG_WIDTH = 460
local MIN_DIALOG_H = 220
-- PrettyUI window content starts under the 32px title and above the 8px border.
local CHROME_H = 40
-- Footer buttons sit on the window, 35px up from the bottom (Dialog.ACTION_Y).
local FOOTER_H = 48

---@param parent any
---@param estimate number
---@return number
local function dialogHeight(parent, estimate)
    local maxH = 640
    local parentH = parent and parent.height
    if type(parentH) == "number" and parentH > 80 then
        maxH = math.max(MIN_DIALOG_H, parentH - 80)
    end
    local height = estimate
    if type(height) ~= "number" or height < MIN_DIALOG_H then height = MIN_DIALOG_H end
    if height > maxH then height = maxH end
    return height
end

-- The window stays a fixed size so the footer does not scroll away. The form
-- lives in a SimpleView that scrolls only when the marks or variables overflow.
---@param win any
---@param height number
---@return any|nil
local function scrollBody(win, height)
    if win ~= nil and win.SetScrollable ~= nil then
        win:SetScrollable(false)
    end
    if prettyui == nil or prettyui.SimpleView == nil or win == nil or win.content == nil then
        if log ~= nil then log("Watchdog: prettyui.SimpleView unavailable, preset dialog body aborted") end
        return nil
    end
    local width = DIALOG_WIDTH - 16
    local contentW = win.content.width
    if type(contentW) == "number" and contentW > 0 then width = contentW end
    local bodyH = math.max(80, height - CHROME_H - FOOTER_H)
    local view
    local ok, err = pcall(function()
        view = prettyui.SimpleView.new(win.content, {
            x = 0,
            y = 0,
            width = width,
            height = bodyH,
        })
    end)
    if not ok or view == nil then
        if log ~= nil then
            log("Watchdog: preset dialog scroll body failed - " .. tostring(err))
        end
        return nil
    end
    return view
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
        return PresetLabels.NumberVariableText(Packs.live() or Packs.new(), value)
    end
    if widget == "enum" then
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

        local height = dialogHeight(parent, estimate)
        Dialog.mount(parent, {
            title = "Save as preset",
            width = DIALOG_WIDTH,
            height = height,
            content = function(mounted)
                local body = scrollBody(mounted, height)
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
                        for _, group in ipairs(choices) do
                            local captured = group
                            local title = PresetLabels.NodeTitle(graph, captured.nodeId) or tostring(captured.nodeId)
                            body:AddSimpleButton(title, function()
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
                        body:AddSimpleButton("Add", function()
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
    local height = dialogHeight(parent, estimate)
    Dialog.mount(parent, {
        title = preset.name or "",
        width = DIALOG_WIDTH,
        height = height,
        content = function(mounted)
            local body = scrollBody(mounted, height)
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

---@param preset Watchdog.Preset|Watchdog.PackAlertPreset
---@return boolean
local function presetHasVariables(preset)
    return type(preset.variables) == "table" and #preset.variables > 0
end

---@class PresetDialogs.NewAlertOpts
---@field registry LibNodeGraph.Registry|nil
---@field onFromScratch fun(): Watchdog.EditorResult, integer|nil
---@field onFromPreset fun(presetId: integer, answers: any[]|nil): Watchdog.EditorResult, integer|nil, string|nil
---@field onFromAlertPreset fun(snapshot: Watchdog.PackAlertPreset, answers: any[]|nil): Watchdog.EditorResult, integer|nil, string|nil
---@field onCreated fun(result: Watchdog.EditorResult)|nil

-- Calls the Variable dialog for a preset that has variables. It does not
-- decide Sound Effect answers itself. onCreated is how main opens the Editor
-- after a create. This dialog does not show the Editor.
---@param parent any
---@param opts PresetDialogs.NewAlertOpts|nil
---@return nil
function PresetDialogs.mountNewAlert(parent, opts)
    if parent == nil or opts == nil then return nil end
    local feedback
    local body = {}
    local alertWin
    local fillList, beginRename, beginDelete

    -- Captured at this open. A later registration does not rebuild an open dialog.
    -- Rename and delete call fillList again and still use this list.
    local offered = {}
    local livePacks = Packs.live()
    if livePacks ~= nil then
        offered = PackRows.AlertPresetGroups(livePacks)
    end

    local function deliver(result, id, err)
        if id ~= nil and opts.onCreated ~= nil then opts.onCreated(result) end
        return id, err
    end

    -- PrettyUI flow padding (14) and column gap (8). The name fills the row.
    -- The pencil and trash sit inline after it, the same sprites as the Manager.
    local FLOW_PAD = 14
    local FLOW_GAP = 8

    local function forget(host, widget)
        local entries = host._managedFlowEntries
        if type(entries) == "table" then
            for i = #entries, 1, -1 do
                if entries[i].component == widget then
                    table.remove(entries, i)
                end
            end
        end
        pcall(function() widget:Destroy() end)
    end

    local function clearBody(host)
        for i = #body, 1, -1 do
            local widget = body[i]
            body[i] = nil
            forget(host, widget)
        end
        local layout = host._flowLayout
        if layout ~= nil then
            layout.nextY = layout.startY
            layout.row = nil
            layout.hasItems = false
            -- Flow only grows the scroll height. Drop it back so a shorter list,
            -- including the empty library, does not leave the footer below a hole.
            if host.SetContentHeight ~= nil then
                pcall(function() host:SetContentHeight(layout.startY) end)
            end
        end
        feedback = nil
    end

    local function remember(widget)
        if widget ~= nil then body[#body + 1] = widget end
        return widget
    end

    -- `actions` is the pencil and trash. Alert Preset rows have neither, so the name uses the row.
    ---@param host any
    ---@param actions integer
    ---@return integer
    local function rowWidth(host, actions)
        local contentW = host.contentWidth
        if type(contentW) ~= "number" then contentW = 352 end
        local width = contentW - FLOW_PAD * 2 - (Theme.MANAGER_ACT_W + FLOW_GAP) * actions
        if width < 80 then width = 80 end
        return width
    end

    ---@param captured Watchdog.Preset|Watchdog.PackAlertPreset
    ---@param create fun(answers: any[]|nil): integer|nil, string|nil
    local function openPreset(captured, create)
        if presetHasVariables(captured) then
            PresetDialogs.mountVariables(parent, {
                preset = captured,
                registry = opts.registry,
                onCreate = function(answers)
                    return create(answers)
                end,
            })
            return
        end
        local id, err = create(nil)
        if id == nil and err ~= "variables" and feedback ~= nil then
            feedback.content = err or "Could not create the alert."
        end
    end

    beginRename = function(preset)
        local field, renameFeedback
        local initial = preset.name or ""
        local renameAction = {
            label = "Rename",
            variant = "positive",
            disabled = Presets.trim(initial) == "",
            onClick = function()
                local name = ""
                pcall(function() name = field:GetText() or "" end)
                if Presets.trim(name) == "" then return false end
                local renamed, err = Presets.Rename(preset.id, name)
                if renamed == nil then
                    if renameFeedback ~= nil then
                        renameFeedback.content = err or "Could not rename the preset."
                    end
                    return false
                end
                if alertWin ~= nil then fillList(alertWin) end
                return true
            end,
        }
        Dialog.mount(parent, {
            title = "Rename preset",
            width = 380,
            height = 200,
            content = function(win)
                win:AddText("Preset name")
                field = win:AddTextField({
                    text = initial,
                    maxLength = 80,
                    height = 30,
                    onChange = function(f)
                        local text = ""
                        pcall(function() text = f:GetText() or "" end)
                        if renameAction.setDisabled ~= nil then
                            renameAction.setDisabled(Presets.trim(text) == "")
                        end
                    end,
                })
                renameFeedback = win:AddText("")
            end,
            actions = {
                { label = "Cancel" },
                renameAction,
            },
        })
    end

    beginDelete = function(preset)
        Confirm.mount(parent, {
            title = "CONFIRM DELETE",
            body = string.format('Delete "%s"? This cannot be undone.', preset.name or ""),
            confirmLabel = "DELETE",
            confirmVariant = "negative",
            onConfirm = function()
                local deleted, err = Presets.Delete(preset.id)
                if deleted ~= true then
                    if feedback ~= nil then
                        feedback.content = err or "Could not delete the preset."
                    end
                    return false
                end
                if alertWin ~= nil then fillList(alertWin) end
                return true
            end,
        })
    end

    fillList = function(host)
        clearBody(host)
        local listed, listErr = Presets.List()
        local hasGroups = #offered > 0
        if listed == nil then
            remember(host:AddText(listErr or "Presets could not be read."))
        elseif #listed == 0 and not hasGroups then
            remember(host:AddText("There are no presets."))
        else
            if listed ~= nil and #listed > 0 then
                local width = rowWidth(host, 2)
                local iconOffset = math.floor((Theme.MANAGER_ROW_H - Theme.MANAGER_ACT_W) / 2)
                for _, preset in ipairs(listed) do
                    local captured = preset
                    remember(host:AddSimpleButton(captured.name, function()
                        openPreset(captured, function(answers)
                            if opts.onFromPreset == nil then
                                return nil, "Could not create the alert."
                            end
                            return deliver(opts.onFromPreset(captured.id, answers))
                        end)
                    end, {
                        width = width,
                        height = Theme.MANAGER_ROW_H,
                    }))
                    remember(host:AddSpriteButton("PENCIL", function()
                        beginRename(captured)
                    end, {
                        inline = true,
                        size = Theme.MANAGER_ACT_W,
                        offsetY = iconOffset,
                        tooltip = "Rename",
                    }))
                    remember(host:AddSpriteButton("TRASH", function()
                        beginDelete(captured)
                    end, {
                        inline = true,
                        size = Theme.MANAGER_ACT_W,
                        offsetY = iconOffset,
                        tooltip = "Delete",
                    }))
                end
            end
            -- The registry already ordered these groups. Do not sort them again.
            if hasGroups then
                local width = rowWidth(host, 0)
                for _, group in ipairs(offered) do
                    remember(host:AddText(group.packName))
                    for _, preset in ipairs(group.presets) do
                        local captured = preset
                        remember(host:AddSimpleButton(captured.name, function()
                            openPreset(captured, function(answers)
                                if opts.onFromAlertPreset == nil then
                                    return nil, "Could not create the alert."
                                end
                                return deliver(opts.onFromAlertPreset(captured, answers))
                            end)
                        end, {
                            width = width,
                            height = Theme.MANAGER_ROW_H,
                        }))
                    end
                end
            end
        end
        feedback = remember(host:AddText(""))
    end

    Dialog.mount(parent, {
        title = "New alert",
        width = 400,
        height = 420,
        content = function(win)
            if win.SetScrollable ~= nil then win:SetScrollable(false) end
            if prettyui == nil or prettyui.SimpleView == nil or win.content == nil then
                if log ~= nil then log("Watchdog: prettyui.SimpleView unavailable, New alert list aborted") end
                return
            end
            -- Same chrome as the preset dialogs: title 32 + border 8, footer band 48.
            local width = 400 - 16
            local contentW = win.content.width
            if type(contentW) == "number" and contentW > 0 then width = contentW end
            local view
            local ok, err = pcall(function()
                view = prettyui.SimpleView.new(win.content, {
                    x = 0,
                    y = 0,
                    width = width,
                    height = 420 - 40 - 48,
                })
            end)
            if not ok or view == nil then
                if log ~= nil then log("Watchdog: New alert list failed - " .. tostring(err)) end
                return
            end
            alertWin = view
            fillList(view)
        end,
        actions = {
            { label = "Cancel" },
            {
                label = "From scratch",
                variant = "positive",
                onClick = function()
                    if opts.onFromScratch == nil then return false end
                    local result, id = opts.onFromScratch()
                    if id == nil then
                        if feedback ~= nil then
                            feedback.content = "Could not create the alert."
                        end
                        return false
                    end
                    if opts.onCreated ~= nil then opts.onCreated(result) end
                    return true
                end,
            },
        },
    })
    return nil
end

return PresetDialogs
