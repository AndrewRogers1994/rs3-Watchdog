-- Save as preset and the Variable dialog. Both use Dialog; this file does not add a dialog harness.
-- Save as preset is parented to the Editor overlay. The Variable dialog stacks on the same
-- parent as New alert so that dialog stays mounted and inert underneath.
-- The form scrolls inside a SimpleView. Dialog itself is unchanged; the window's own
-- scrollbar is turned off so Cancel and Save stay on screen.

local Dialog = require("src/ui/dialog")
local Presets = require("src/presets")
local Packs = require("src/packs")
local ControlKinds = require("src/ui/control_kinds")
local NumberField = require("src/ui/widgets/number_field")
local SoundEffect = require("src/ui/controls/sound_effect")

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
        return Presets.NumberVariableText(value)
    end
    if widget == "enum" then
        for _, choice in ipairs(ControlKinds.Choices(pin.dataType) or {}) do
            if Presets.sameStored(choice.value, value) then return choice.label end
        end
        if type(value) == "table" then
            local packs = Packs.live() or Packs.new()
            return packs:AudioClosedLabel(value)
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
                        body:AddText(Presets.MarkLabel(graph, captured.nodeId, captured.pinName) or "")
                        body:AddText(valueText(graph, captured.nodeId, captured.pinName))
                        body:AddSimpleButton("Remove", function()
                            reopen(mounted, withoutMark(marks, captured.nodeId, captured.pinName), nil)
                        end)
                    end
                    if pick ~= nil and pick.kind == "node" then
                        body:AddText("Choose a node")
                        for _, group in ipairs(choices) do
                            local captured = group
                            local title = Presets.NodeTitle(graph, captured.nodeId) or tostring(captured.nodeId)
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
                                body:AddSimpleButton(Presets.PinLabel(graph, nodeId, capturedPin), function()
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
        slot.raw = Presets.NumberVariableText(value)
        if isSoundEffectMark(graph, mark) then
            local packs = Packs.live() or Packs.new()
            local rows = packs:SoundEffectRows()
            sortSoundRows(rows)
            slot.soundRows = rows
            local index = packs:SoundEffectSelectedRow(rows, value)
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
            if packs ~= nil then label = packs:AudioClosedLabel(value) end
        end
        slot.value, slot.choices = Presets.EnumSlotValue(
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
    local selected = SOUND_NONE_ID
    if slot.shown ~= nil then
        for i, row in ipairs(rows) do
            if row.pack == slot.shown.pack and row.authorId == slot.shown.authorId then
                selected = i + 1
                break
            end
        end
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
                    local answer = { raw = slot.raw, quantity = slot.quantity }
                    -- An untouched pack list stays on the number path so an
                    -- outdated record is kept. Choosing a row or None is explicit.
                    if slot.soundRows ~= nil and slot.packTouched == true then
                        if slot.shown ~= nil then
                            answer.packRow = slot.shown
                        else
                            answer.clearPack = true
                        end
                    end
                    answers[i] = answer
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
                    local label = Presets.MarkLabel(graph, mark.nodeId, mark.pinName) or mark.pinName
                    body:AddText(label)
                    if slot.widget == "enum" then
                        local choices = slot.choices or {}
                        local selected = 1
                        for i, choice in ipairs(choices) do
                            if Presets.sameStored(choice.value, slot.value) then
                                selected = i
                                break
                            end
                        end
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

return PresetDialogs
