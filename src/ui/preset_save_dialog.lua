-- One dialog window. A Multiplexer stacks the root form, Choose a node, and
-- Choose a pin, so a drag is not recentered. Cancel and Save stay on the footer.

local Dialog = require("src/ui/dialog")
local Multiplexer = require("src/ui/multiplexer")
local Presets = require("src/presets")
local PresetLabels = require("src/ui/preset_labels")
local Packs = require("src/packs")
local PackRows = require("src/pack_rows")
local ControlKinds = require("src/ui/control_kinds")
local PresetForm = require("src/ui/preset_form")
local Theme = require("src/ui/theme")

local PresetSaveDialog = {}

local PAD = 8
local LABEL_H = 20
local FIELD_H = 30
local GAP = 8
local ROW_H = Theme.MANAGER_ROW_H
local HEADER_H = Theme.MANAGER_HEADER_H
local ERROR_H = 20
local BACK_H = Theme.TOOLBAR_BTN
local ACTION_W = Theme.MANAGER_ACT_W
local COL_GAP = Theme.MANAGER_ROW_GAP
local VALUE_W = 160
local MAX_LIST_ROWS = 6
-- PrettyUI window content starts under the title and inside the border.
local CHROME_H = 40
-- Footer buttons sit on the window, above Dialog.ACTION_Y.
local FOOTER_H = 48

---@class Watchdog.PresetStep : Watchdog.MuxSurface
---@field layout (fun(self, stackH: number, width: number))|nil
---@field windowH (fun(): number)|nil

local ROOT_TITLE = "Save as preset"
local NODE_TITLE = "Save as preset - Choose a node"
local PIN_TITLE = "Save as preset - Choose a pin"

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

---@param graph LibNodeGraph.Graph
---@param nodeId integer
---@param pinName string
---@return integer
local function pinIndex(graph, nodeId, pinName)
    local pins = graph:GetPins(nodeId) or {}
    for i, pin in ipairs(pins) do
        if pin.name == pinName then return i end
    end
    return #pins + 1
end

-- Pin index breaks a title tie. table.sort is not stable.
---@param graph LibNodeGraph.Graph
---@param a Watchdog.PresetVariable
---@param b Watchdog.PresetVariable
---@return boolean
local function markBefore(graph, a, b)
    local left = PresetLabels.NodeTitle(graph, a.nodeId) or ""
    local right = PresetLabels.NodeTitle(graph, b.nodeId) or ""
    local cmp = Presets.natcasecmp(left, right)
    if cmp ~= 0 then return cmp < 0 end
    if a.nodeId ~= b.nodeId then return a.nodeId < b.nodeId end
    return pinIndex(graph, a.nodeId, a.pinName) < pinIndex(graph, b.nodeId, b.pinName)
end

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
        end
    end
    table.sort(out, function(a, b)
        return markBefore(graph, a, b)
    end)
    return out
end

---@param graph LibNodeGraph.Graph
---@param eligible Watchdog.PresetVariable[]
---@param marks Watchdog.PresetVariable[]
---@return { nodeId: integer, pinNames: string[] }[]
local function sortedNodes(graph, eligible, marks)
    local groups = Presets.UnmarkedNodes(eligible, marks)
    table.sort(groups, function(a, b)
        local left = PresetLabels.NodeTitle(graph, a.nodeId) or ""
        local right = PresetLabels.NodeTitle(graph, b.nodeId) or ""
        local cmp = Presets.natcasecmp(left, right)
        if cmp ~= 0 then return cmp < 0 end
        return a.nodeId < b.nodeId
    end)
    return groups
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
---@param text string
---@param x number
---@param y number
---@param w number
---@param h number
---@return any|nil
local function mountText(parent, text, x, y, w, h)
    if ui == nil or ui.Text == nil then return nil end
    local label
    local ok = pcall(function() label = ui.Text.new(parent) end)
    if not ok or label == nil then return nil end
    pcall(function()
        label:SetPos(x, y)
        label:SetSize(w, h)
        label.content = text
        label.clickthrough = true
        label.isShadowed = true
        label.maxLines = 1
        -- ui.Text draws nothing until it has a colour.
        label.rgb = 0xE7D7B0FF
        label.rgba = 0xE7D7B0FF
        if id ~= nil and id.Font ~= nil then
            label.font = id.Font.MUSEO_SANS_15PT_REGULAR
        end
    end)
    return label
end

---@param rowW number
---@return number variableW
---@return number valueW
---@return number actionW
local function columnWidths(rowW)
    local gaps = COL_GAP * 2
    local valueW = VALUE_W
    local variableW = rowW - valueW - ACTION_W - gaps
    if variableW < 80 then
        variableW = 80
        valueW = rowW - variableW - ACTION_W - gaps
        if valueW < 40 then valueW = 40 end
        variableW = rowW - valueW - ACTION_W - gaps
        if variableW < 1 then variableW = 1 end
    end
    return variableW, valueW, ACTION_W
end

---@param count integer
---@return number
local function visibleRows(count)
    if count > MAX_LIST_ROWS then return MAX_LIST_ROWS end
    return count
end

---@param nothing boolean
---@param hasButton boolean
---@param rows integer
---@return number
local function rootInner(nothing, hasButton, rows)
    local h = PAD + LABEL_H + GAP + FIELD_H
    if nothing then
        h = h + GAP + LABEL_H
    elseif hasButton then
        h = h + GAP + ROW_H
    end
    if rows > 0 then
        h = h + GAP + HEADER_H + visibleRows(rows) * ROW_H
    end
    return h + PAD
end

---@param count integer
---@return number
local function chooseInner(count)
    return PAD + BACK_H + GAP + visibleRows(count) * ROW_H + PAD
end

---@param width number
---@return number
local function innerWidth(width)
    return math.max(40, width - PAD * 2)
end

---@param parent any
---@param inner number
---@return number
local function windowHeight(parent, inner)
    return PresetForm.dialogHeight(parent, inner + ERROR_H + GAP + CHROME_H + FOOTER_H)
end

---@param comp any
---@param handler (fun(component: any, delta: number): boolean)|nil
local function bindWheel(comp, handler)
    if comp == nil or handler == nil or ui == nil or ui.Hook == nil or ui.Hook.ONSCROLLWHEEL == nil then
        return
    end
    pcall(function() comp:Subscribe(ui.Hook.ONSCROLLWHEEL, handler) end)
end

---@param win any
---@return number
local function hostWidth(win)
    local width = win.content and win.content.width
    if type(width) == "number" and width > 0 then return width end
    return PresetForm.DIALOG_WIDTH - 16
end

---@param parent any
---@param opts PresetDialogs.SaveOpts
function PresetSaveDialog.mountSave(parent, opts)
    if parent == nil or opts == nil or opts.graph == nil then return end
    local graph = opts.graph
    local eligible = Presets.Eligible(graph)
    local marks = {}
    local nameText = opts.initialName or ""
    local field
    local feedback
    local mux
    local rootSurface

    local saveAction = {
        label = "Save",
        variant = "positive",
        disabled = Presets.trim(nameText) == "",
        onClick = function()
            local name = ""
            if field ~= nil then
                local ok, text = pcall(function() return field:GetText() end)
                if ok and type(text) == "string" then name = Presets.trim(text) end
            end
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

    ---@param hasButton boolean
    ---@param hasRows boolean
    ---@return number nameY
    ---@return number fieldY
    ---@return number|nil markY
    ---@return number|nil nothingY
    ---@return number|nil headerY
    ---@return number|nil listTop
    local function rootSlots(hasButton, hasRows)
        local y = PAD
        local nameY = y
        y = y + LABEL_H + GAP
        local fieldY = y
        y = y + FIELD_H
        local markY = nil
        local nothingY = nil
        if #eligible == 0 then
            y = y + GAP
            nothingY = y
            y = y + LABEL_H
        elseif hasButton then
            y = y + GAP
            markY = y
            y = y + ROW_H
        end
        local headerY = nil
        local listTop = nil
        if hasRows then
            y = y + GAP
            headerY = y
            y = y + HEADER_H
            listTop = y
        end
        return nameY, fieldY, markY, nothingY, headerY, listTop
    end

    ---@param stackH number
    ---@param width number
    local function placeFeedback(stackH, width)
        if feedback == nil or feedback.SetPos == nil then return end
        feedback:SetPos(PAD, stackH + GAP)
        feedback:SetSize(math.max(40, width - PAD * 2), ERROR_H)
    end

    ---@param windowH number
    local function applyHeight(windowH)
        local mounted = mux and mux:Window()
        if mounted == nil then return end
        Dialog.resizeKeepingTop(mounted, PresetForm.DIALOG_WIDTH, windowH)
        local bodyH = math.max(80, windowH - CHROME_H - FOOTER_H)
        local stackH = math.max(40, bodyH - ERROR_H - GAP)
        local width = hostWidth(mounted)
        placeFeedback(stackH, width)
        ---@type Watchdog.PresetStep|nil
        local top = mux:Top()
        if top ~= nil and top.layout ~= nil then
            top:layout(stackH, width)
        end
    end

    ---@return number
    local function measureRoot()
        local rows = #marks
        local showButton = #sortedNodes(graph, eligible, marks) > 0
        return windowHeight(parent, rootInner(#eligible == 0, showButton, rows))
    end

    Dialog.mount(parent, {
        title = ROOT_TITLE,
        width = PresetForm.DIALOG_WIDTH,
        height = measureRoot(),
        content = function(mounted)
            local pushNodes, pushPins
            if mounted.SetScrollable ~= nil then
                mounted:SetScrollable(false)
            end
            mux = Multiplexer.new(mounted)
            mux:SetShown(true)
            feedback = mountText(mounted.content, "", PAD, 0, hostWidth(mounted) - PAD * 2, ERROR_H)

            local host = ui.Layer.new(mounted.content)
            host:SetPos(0, 0)
            local width0 = hostWidth(mounted)
            local nameY, fieldY, markY, nothingY = rootSlots(#eligible > 0, false)
            local nameLabel = mountText(host, "Preset name", PAD, nameY, width0 - PAD * 2, LABEL_H)
            field = prettyui.TextField.new(host, {
                text = nameText,
                maxLength = 80,
                x = PAD,
                y = fieldY,
                width = math.max(80, width0 - PAD * 2),
                height = FIELD_H,
                onChange = function(f)
                    local text = ""
                    local ok, value = pcall(function() return f:GetText() end)
                    if ok and type(value) == "string" then text = value end
                    if saveAction.setDisabled ~= nil then
                        saveAction.setDisabled(Presets.trim(text) == "")
                    end
                end,
            })
            local nothingLabel = nil
            local markButton = nil
            if #eligible == 0 then
                nothingLabel = mountText(host, "Nothing on this Alert can be marked.", PAD, nothingY or 0, width0 - PAD * 2, LABEL_H)
            else
                markButton = prettyui.SimpleButton.new(host, "Mark Variable", function()
                    pushNodes()
                end, {
                    x = PAD,
                    y = markY or 0,
                    width = 160,
                    height = ROW_H,
                })
            end

            local headerPanel = nil
            local listView = nil

            local function dropTable()
                -- Destroy the view, not each SpriteButton and then its panel.
                -- That order faults the client.
                if listView ~= nil then listView:Destroy() end
                listView = nil
                if headerPanel ~= nil then headerPanel:Destroy() end
                headerPanel = nil
            end

            ---@param stackH number
            ---@param width number
            local function syncTable(stackH, width)
                dropTable()
                local rows = marks
                local choices = sortedNodes(graph, eligible, rows)
                if markButton ~= nil then
                    markButton.root.hidden = #choices == 0
                end
                if nothingLabel ~= nil then return end
                if #rows == 0 then return end
                local _, _, _, _, headerY, listTop = rootSlots(#choices > 0, true)
                local listH = math.max(1, stackH - (listTop or 0) - PAD)
                local innerW = innerWidth(width)
                listView = prettyui.SimpleView.new(host, {
                    x = PAD,
                    y = listTop,
                    width = innerW,
                    height = listH,
                })
                listView:SetContentHeight(#rows * ROW_H)
                local rowW = listView.contentWidth
                if type(rowW) ~= "number" or rowW <= 0 then rowW = innerW end
                local variableW, valueW, actionW = columnWidths(rowW)
                log(variableW, valueW, actionW)

                headerPanel = ui.Panel.new(host)
                headerPanel.isVertical = false
                headerPanel.spacing = COL_GAP
                headerPanel.clickthrough = true
                headerPanel:SetPos(PAD, headerY)
                headerPanel:SetSize(rowW, HEADER_H)
                mountText(headerPanel, "Variable", 0, 0, variableW, HEADER_H)
                mountText(headerPanel, "Default value", 0, 0, valueW, HEADER_H)
                mountText(headerPanel, "", 0, 0, actionW, HEADER_H)

                local onWheel = listView._onScrollWheel
                local tree = ui.Panel.new(listView.content)
                tree.isVertical = true
                tree.spacing = 0
                tree:SetPos(0, 0)
                tree:SetSize(rowW, #rows * ROW_H)
                bindWheel(tree, onWheel)
                for _, mark in ipairs(rows) do
                    local captured = mark
                    local rowPanel = ui.Panel.new(tree)
                    rowPanel.isVertical = false
                    rowPanel.spacing = COL_GAP
                    rowPanel:SetSize(rowW, ROW_H)
                    bindWheel(rowPanel, onWheel)
                    mountText(rowPanel, PresetLabels.MarkLabel(graph, captured.nodeId, captured.pinName) or "", 0, 0, variableW, ROW_H)
                    mountText(rowPanel, valueText(graph, captured.nodeId, captured.pinName), 0, 0, valueW, ROW_H)
                    prettyui.SpriteButton.new(rowPanel, "TRASH", function()
                        marks = sortedMarks(graph, withoutMark(marks, captured.nodeId, captured.pinName))
                        applyHeight(measureRoot())
                    end, {
                        size = ACTION_W,
                        tooltip = "Remove",
                        _onScrollWheel = onWheel,
                    })
                end
            end

            ---@type Watchdog.PresetStep
            rootSurface = {
                id = "root",
                title = ROOT_TITLE,
                SetVisible = function(_, v)
                    host.hidden = not v
                end,
                layout = function(_, stackH, width)
                    host:SetSize(width, stackH)
                    if nameLabel ~= nil then
                        nameLabel:SetSize(math.max(40, width - PAD * 2), LABEL_H)
                    end
                    syncTable(stackH, width)
                end,
                windowH = function()
                    return measureRoot()
                end,
            }

            ---@param id string
            ---@param title string
            ---@param entries { label: string }[]
            ---@param onPick fun(entry: table)
            local function pushChoose(id, title, entries, onPick)
                local step = ui.Layer.new(mounted.content)
                step:SetPos(0, 0)
                ---@type Watchdog.PresetStep
                local surface = {
                    id = id,
                    title = title,
                    SetVisible = function(_, v)
                        step.hidden = not v
                    end,
                    -- Destroy the layer, not the Back sprite and then the layer.
                    OnPop = function()
                        step:Destroy()
                    end,
                }
                local stepH = windowHeight(parent, chooseInner(#entries))
                local stepBody = math.max(80, stepH - CHROME_H - FOOTER_H)
                local stepStack = math.max(40, stepBody - ERROR_H - GAP)
                surface.windowH = function()
                    return stepH
                end
                prettyui.SpriteButton.new(step, "BACK", function()
                    mux:Pop()
                    ---@type Watchdog.PresetStep|nil
                    local top = mux:Top()
                    local h = measureRoot()
                    if top ~= nil and top.windowH ~= nil then
                        h = top.windowH()
                    end
                    applyHeight(h)
                end, {
                    x = PAD,
                    y = PAD,
                    size = BACK_H,
                    tooltip = "Back",
                })
                local listTop = PAD + BACK_H + GAP
                local listH = math.max(1, stepStack - listTop - PAD)
                local innerW = innerWidth(width0)
                local view
                surface.layout = function(_, stackH, width)
                    step:SetSize(width, stackH)
                    listH = math.max(1, stackH - listTop - PAD)
                    view:SetSize(innerWidth(width), listH)
                end
                view = prettyui.SimpleView.new(step, {
                    x = PAD,
                    y = listTop,
                    width = innerW,
                    height = listH,
                })
                view:SetContentHeight(math.max(ROW_H, #entries * ROW_H))
                local buttonW = innerW
                if type(view.contentWidth) == "number" and view.contentWidth > 0 then
                    buttonW = view.contentWidth
                end
                for i, entry in ipairs(entries) do
                    local captured = entry
                    local label = captured.label
                    prettyui.SimpleButton.new(view.content, label, function()
                        onPick(captured)
                    end, {
                        x = 0,
                        y = (i - 1) * ROW_H,
                        width = math.max(40, buttonW),
                        height = ROW_H,
                        _onScrollWheel = view._onScrollWheel,
                    })
                end
                mux:Push(surface)
                applyHeight(windowHeight(parent, chooseInner(#entries)))
            end

            pushNodes = function()
                local groups = sortedNodes(graph, eligible, marks)
                local entries = {}
                for _, group in ipairs(groups) do
                    entries[#entries + 1] = {
                        label = PresetLabels.NodeTitle(graph, group.nodeId) or tostring(group.nodeId),
                        group = group,
                    }
                end
                pushChoose("node", NODE_TITLE, entries, function(entry)
                    pushPins(entry.group)
                end)
            end

            ---@param group { nodeId: integer, pinNames: string[] }
            pushPins = function(group)
                local entries = {}
                for _, pinName in ipairs(group.pinNames) do
                    entries[#entries + 1] = {
                        label = PresetLabels.PinLabel(graph, group.nodeId, pinName),
                        pinName = pinName,
                        nodeId = group.nodeId,
                    }
                end
                pushChoose("pin", PIN_TITLE, entries, function(entry)
                    marks = sortedMarks(graph, withMark(marks, entry.nodeId, entry.pinName))
                    mux:PopTo("root")
                    applyHeight(measureRoot())
                end)
            end

            mux:Push(rootSurface)
            applyHeight(measureRoot())
        end,
        actions = {
            { label = "Cancel" },
            saveAction,
        },
    })
end

return PresetSaveDialog
