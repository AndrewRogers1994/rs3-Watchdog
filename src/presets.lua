-- Preset library. One plugin-wide document under the PersistentDB key `presets`
-- (no watchdog_ prefix). Not a Scope Bucket: Store.Save / SaveTo never write this key.
-- Instantiate inserts an Alert into a caller-supplied Bucket; it does not save that Bucket.

local Store = require("src/store")
local ControlKinds = require("src/ui/control_kinds")
local NumberField = require("src/ui/widgets/number_field")
local Node = require("src/ui/node")

local Presets = {}

-- A Variable is one text, number, enum, or Matcher needle. Widget kind is the source of
-- truth, looked up from the tag recorded at Controls.Register.
local MARKABLE_WIDGET = {
    text = true,
    number = true,
    enum = true,
    matcher = true,
}

local DB_KEY = "presets"
local DOC_VERSION = 1
local NAME_MAX = 80

---@class Watchdog.PresetVariable
---@field nodeId integer
---@field pinName string

---@class Watchdog.Preset
---@field id integer
---@field name string
---@field graph LibNodeGraph.SerializedGraph
---@field layout Watchdog.LayoutArray
---@field variables Watchdog.PresetVariable[]

---@class Watchdog.PresetDoc
---@field version integer
---@field presets Watchdog.Preset[]

---@return Watchdog.PresetDoc
function Presets.Empty()
    return { version = DOC_VERSION, presets = {} }
end

---@return LibNodeGraph.Codec|nil
local function codec()
    if LibNodeGraph ~= nil and LibNodeGraph.Json ~= nil then
        return LibNodeGraph.Json.Default
    end
    return nil
end

-- Reported, not overwritten. A bad document stays on disk until a version-1 read succeeds.
---@param message string
local function report(message)
    if type(log) == "function" then
        log("Watchdog: " .. message)
    end
end

-- A missing key is an empty version-1 library. Load does not create the key.
-- Unreadable JSON, or any version other than 1, is reported and left on disk.
---@return Watchdog.PresetDoc|nil doc
---@return string|nil err
function Presets.Load()
    if PersistentDB == nil then return Presets.Empty(), nil end
    local text
    local got, getErr = pcall(function() text = PersistentDB:GetString(DB_KEY) end)
    if not got then
        report("presets document unreadable, left on disk - " .. tostring(getErr))
        return nil, "Presets could not be read."
    end
    if type(text) ~= "string" or text == "" then
        return Presets.Empty(), nil
    end
    local c = codec()
    if c == nil then
        report("presets document unreadable, left on disk - no JSON codec")
        return nil, "Presets could not be read."
    end
    local ok, doc = pcall(function() return c.decode(text) end)
    if not ok or type(doc) ~= "table" then
        report("presets document unreadable, left on disk - " .. tostring(doc))
        return nil, "Presets could not be read."
    end
    if doc.version ~= DOC_VERSION or type(doc.presets) ~= "table" then
        report("presets document version " .. tostring(doc.version) .. " is not supported, left on disk")
        return nil, "Presets could not be read."
    end
    return doc, nil
end

---@param name string|nil
---@return string
local function trim(name)
    if type(name) ~= "string" then return "" end
    return (name:match("^%s*(.-)%s*$"))
end

-- Same on-disk shape an Alert entry uses: `{ id, x, y }` sorted by node id.
---@param layout Watchdog.Layout|nil
---@return Watchdog.LayoutArray
local function layoutToArray(layout)
    local arr = {}
    for id, pos in pairs(layout or {}) do
        arr[#arr + 1] = { id = id, x = pos.x or 0, y = pos.y or 0 }
    end
    table.sort(arr, function(a, b) return a.id < b.id end)
    return arr
end

-- One past the highest id still in the list, or 1 when the list is empty. No nextId.
---@param doc Watchdog.PresetDoc
---@return integer
local function mintId(doc)
    local maxId = 0
    for _, preset in ipairs(doc.presets or {}) do
        if type(preset.id) == "number" and preset.id > maxId then
            maxId = preset.id
        end
    end
    return maxId + 1
end

---@param doc Watchdog.PresetDoc
---@return boolean
local function write(doc)
    if PersistentDB == nil then return false end
    local c = codec()
    if c == nil then
        report("failed to encode presets document - no JSON codec")
        return false
    end
    local ok, text = pcall(function() return c.encode(doc) end)
    if not ok or type(text) ~= "string" then
        report("failed to encode presets document - " .. tostring(text))
        return false
    end
    return pcall(function() PersistentDB:SetString(DB_KEY, text) end)
end

---@param nodeId integer
---@param pinName string
---@return string
local function markKey(nodeId, pinName)
    return tostring(nodeId) .. "\0" .. tostring(pinName)
end

-- Nil keeps the 3-arg save: variables = {}. A list is stored as { nodeId, pinName } only,
-- ordered by node id then pin order. Duplicates collapse. An ineligible mark writes nothing.
---@param graph LibNodeGraph.Graph
---@param variables Watchdog.PresetVariable[]|nil
---@return Watchdog.PresetVariable[]|nil marks
---@return string|nil err
local function storedMarks(graph, variables)
    if variables == nil then return {} end
    if type(variables) ~= "table" then
        return nil, "That control cannot be marked."
    end
    local allowed = {}
    for _, mark in ipairs(Presets.Eligible(graph)) do
        allowed[markKey(mark.nodeId, mark.pinName)] = true
    end
    local pinOrder = {}
    for id, node in pairs(graph.nodes or {}) do
        if node ~= nil then
            local order = {}
            for index, pin in ipairs(graph:GetPins(id) or {}) do
                order[pin.name] = index
            end
            pinOrder[id] = order
        end
    end
    local seen = {}
    local out = {}
    for _, mark in ipairs(variables) do
        if type(mark) ~= "table" or type(mark.nodeId) ~= "number" or type(mark.pinName) ~= "string" then
            return nil, "That control cannot be marked."
        end
        local key = markKey(mark.nodeId, mark.pinName)
        if not allowed[key] then
            return nil, "That control cannot be marked."
        end
        if not seen[key] then
            seen[key] = true
            out[#out + 1] = { nodeId = mark.nodeId, pinName = mark.pinName }
        end
    end
    table.sort(out, function(a, b)
        if a.nodeId ~= b.nodeId then return a.nodeId < b.nodeId end
        local aOrder = pinOrder[a.nodeId] and pinOrder[a.nodeId][a.pinName] or 0
        local bOrder = pinOrder[b.nodeId] and pinOrder[b.nodeId][b.pinName] or 0
        return aOrder < bOrder
    end)
    return out
end

-- Always adds. Never replaces. Duplicate names are kept.
-- Refuses to write until a version-1 document can be read, and refuses a blank name.
---@param name string
---@param graph LibNodeGraph.Graph
---@param layout Watchdog.Layout|nil
---@param variables Watchdog.PresetVariable[]|nil
---@return Watchdog.Preset|nil preset
---@return string|nil err
function Presets.Add(name, graph, layout, variables)
    local trimmed = trim(name)
    if trimmed == "" or #trimmed > NAME_MAX then
        return nil, "Enter a preset name."
    end
    if graph == nil or LibNodeGraph == nil or LibNodeGraph.Serialize == nil then
        return nil, "Could not copy the graph."
    end
    local marks, markErr = storedMarks(graph, variables)
    if marks == nil then
        return nil, markErr
    end
    local doc, err = Presets.Load()
    if doc == nil then
        return nil, err
    end
    local ok, serialized = pcall(LibNodeGraph.Serialize, graph)
    if not ok or type(serialized) ~= "table" then
        report("could not copy the alert graph - " .. tostring(serialized))
        return nil, "Could not copy the graph."
    end
    local preset = {
        id = mintId(doc),
        name = trimmed,
        graph = serialized,
        layout = layoutToArray(layout),
        variables = marks,
    }
    doc.presets[#doc.presets + 1] = preset
    if not write(doc) then
        return nil, "Could not save the preset."
    end
    return preset, nil
end

-- Martin Pool's natural order, the case-insensitive form PHP calls strnatcasecmp.
-- Spaces are skipped the way that algorithm skips them. A zero-padded run is
-- compared left to right, so "01" comes before "1". A run with no leading zero
-- uses the longer-run comparison, so "2" comes before "10".

local function isDigit(ch)
    return ch ~= nil and ch >= "0" and ch <= "9"
end

local function isSpace(ch)
    return ch == " " or ch == "\t" or ch == "\n" or ch == "\r" or ch == "\v" or ch == "\f"
end

local function upper(ch)
    local b = string.byte(ch)
    if b >= 97 and b <= 122 then
        return string.char(b - 32)
    end
    return ch
end

--- Case-insensitive natural order. Spaces are skipped. -1 when a < b, 0 when equal, 1 when a > b.
---@param a string
---@param b string
---@return integer
function Presets.natcasecmp(a, b)
    a = type(a) == "string" and a or ""
    b = type(b) == "string" and b or ""
    local aLen, bLen = #a, #b
    if aLen == 0 or bLen == 0 then
        if aLen == bLen then return 0 end
        if aLen > bLen then return 1 end
        return -1
    end

    local ap, bp = 1, 1
    local function charAt(s, len, i)
        if i > len then return nil end
        return s:sub(i, i)
    end
    local ca = charAt(a, aLen, ap)
    local cb = charAt(b, bLen, bp)

    local function compareRight()
        local bias = 0
        while true do
            local aEnd = ap > aLen or not isDigit(charAt(a, aLen, ap))
            local bEnd = bp > bLen or not isDigit(charAt(b, bLen, bp))
            if aEnd and bEnd then return bias end
            if aEnd then return -1 end
            if bEnd then return 1 end
            local da = charAt(a, aLen, ap)
            local db = charAt(b, bLen, bp)
            if da < db then
                if bias == 0 then bias = -1 end
            elseif da > db then
                if bias == 0 then bias = 1 end
            end
            ap = ap + 1
            bp = bp + 1
        end
    end

    local function compareLeft()
        while true do
            local aEnd = ap > aLen or not isDigit(charAt(a, aLen, ap))
            local bEnd = bp > bLen or not isDigit(charAt(b, bLen, bp))
            if aEnd and bEnd then return 0 end
            if aEnd then return -1 end
            if bEnd then return 1 end
            local da = charAt(a, aLen, ap)
            local db = charAt(b, bLen, bp)
            if da < db then return -1 end
            if da > db then return 1 end
            ap = ap + 1
            bp = bp + 1
        end
    end

    while true do
        while ca ~= nil and isSpace(ca) do
            ap = ap + 1
            ca = charAt(a, aLen, ap)
        end
        while cb ~= nil and isSpace(cb) do
            bp = bp + 1
            cb = charAt(b, bLen, bp)
        end

        if isDigit(ca) and isDigit(cb) then
            local result
            if ca == "0" or cb == "0" then
                result = compareLeft()
            else
                result = compareRight()
            end
            if result ~= 0 then return result end
            if ap > aLen and bp > bLen then return 0 end
            if ap > aLen then return -1 end
            if bp > bLen then return 1 end
            ca = charAt(a, aLen, ap)
            cb = charAt(b, bLen, bp)
        end

        if ca == nil and cb == nil then return 0 end
        if ca == nil then return -1 end
        if cb == nil then return 1 end

        local ua, ub = upper(ca), upper(cb)
        if ua < ub then return -1 end
        if ua > ub then return 1 end

        ap = ap + 1
        bp = bp + 1
        if ap > aLen and bp > bLen then return 0 end
        if ap > aLen then return -1 end
        if bp > bLen then return 1 end
        ca = charAt(a, aLen, ap)
        cb = charAt(b, bLen, bp)
    end
end

-- Sorted copy. The stored array keeps insertion order; nothing persists a display order.
---@return Watchdog.Preset[]|nil presets
---@return string|nil err
function Presets.List()
    local doc, err = Presets.Load()
    if doc == nil then return nil, err end
    local copy = {}
    for i, preset in ipairs(doc.presets) do
        copy[i] = preset
    end
    table.sort(copy, function(left, right)
        local cmp = Presets.natcasecmp(left.name, right.name)
        if cmp ~= 0 then return cmp < 0 end
        return (left.id or 0) < (right.id or 0)
    end)
    return copy, nil
end

-- Keeps the id. Only the trimmed name changes; graph, layout, and variables stay as saved.
-- Refuses a blank name and refuses to write until a version-1 document can be read.
---@param id integer
---@param name string
---@return Watchdog.Preset|nil preset
---@return string|nil err
function Presets.Rename(id, name)
    local trimmed = trim(name)
    if trimmed == "" or #trimmed > NAME_MAX then
        return nil, "Enter a preset name."
    end
    local doc, err = Presets.Load()
    if doc == nil then
        return nil, err
    end
    local preset
    for _, candidate in ipairs(doc.presets) do
        if candidate.id == id then
            preset = candidate
            break
        end
    end
    if preset == nil then
        return nil, "Preset not found."
    end
    preset.name = trimmed
    if not write(doc) then
        return nil, "Could not rename the preset."
    end
    return preset, nil
end

-- Removes one id. Another Preset with the same name stays. Does not write Scope buckets.
-- A missing id does not wipe the library. An unreadable document is left on disk.
---@param id integer
---@return boolean|nil ok
---@return string|nil err
function Presets.Delete(id)
    local doc, err = Presets.Load()
    if doc == nil then
        return nil, err
    end
    local index
    for i, candidate in ipairs(doc.presets) do
        if candidate.id == id then
            index = i
            break
        end
    end
    if index == nil then
        return nil, "Preset not found."
    end
    table.remove(doc.presets, index)
    if not write(doc) then
        return nil, "Could not delete the preset."
    end
    return true, nil
end

---@param arr Watchdog.LayoutArray|nil
---@return Watchdog.Layout
local function layoutFromArray(arr)
    local layout = {}
    for _, entry in ipairs(arr or {}) do
        if entry.id ~= nil then
            layout[entry.id] = { x = entry.x or 0, y = entry.y or 0 }
        end
    end
    return layout
end

---@param node table|nil
---@return boolean
local function isPlaceholder(node)
    if node == nil then return false end
    if node.unknown ~= nil then return true end
    local unknown = (LibNodeGraph ~= nil) and LibNodeGraph.UNKNOWN_TYPE or nil
    if unknown ~= nil and node.typeKey == unknown then return true end
    return node.typeKey == "__unknown__"
end

---@param graph LibNodeGraph.Graph
---@param nodeId integer
---@param pinName string
---@return boolean
local function pinConnected(graph, nodeId, pinName)
    for _, conn in pairs(graph.connections or {}) do
        if conn.toNode == nodeId and conn.toPin == pinName then
            return true
        end
    end
    return false
end

-- Pins a player can mark: unconnected data-in text, number, enum, or Matcher needle
-- on a real node. Ordered by node id, then that node's pin order.
---@param graph LibNodeGraph.Graph
---@return Watchdog.PresetVariable[]
function Presets.Eligible(graph)
    if type(graph) ~= "table" or type(graph.nodes) ~= "table" or type(graph.GetPins) ~= "function" then
        return {}
    end
    local ids = {}
    for id in pairs(graph.nodes) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    local out = {}
    for _, id in ipairs(ids) do
        local node = graph.nodes[id]
        if not isPlaceholder(node) then
            for _, pin in ipairs(graph:GetPins(id) or {}) do
                local widget = ControlKinds.Widget(pin.dataType)
                if pin.kind == "data" and pin.direction == "in"
                    and widget ~= nil and MARKABLE_WIDGET[widget] == true
                    and not pinConnected(graph, id, pin.name) then
                    out[#out + 1] = { nodeId = id, pinName = pin.name }
                end
            end
        end
    end
    return out
end

-- Eligible pins still unmarked, grouped by node in eligible order. A node with no pins
-- left is omitted. One pin in the group means choosing that node marks it.
---@param eligible Watchdog.PresetVariable[]|nil
---@param marked Watchdog.PresetVariable[]|nil
---@return { nodeId: integer, pinNames: string[] }[]
function Presets.UnmarkedNodes(eligible, marked)
    local taken = {}
    for _, mark in ipairs(marked or {}) do
        if type(mark) == "table" then
            taken[markKey(mark.nodeId, mark.pinName)] = true
        end
    end
    local groups = {}
    local order = {}
    for _, mark in ipairs(eligible or {}) do
        local key = markKey(mark.nodeId, mark.pinName)
        if not taken[key] then
            local group = groups[mark.nodeId]
            if group == nil then
                group = { nodeId = mark.nodeId, pinNames = {} }
                groups[mark.nodeId] = group
                order[#order + 1] = mark.nodeId
            end
            group.pinNames[#group.pinNames + 1] = mark.pinName
        end
    end
    local out = {}
    for _, id in ipairs(order) do
        out[#out + 1] = groups[id]
    end
    return out
end

---@param graph LibNodeGraph.Graph
---@param nodeId integer
---@param pinName string
---@return table|nil
local function dataInPin(graph, nodeId, pinName)
    for _, pin in ipairs(graph:GetPins(nodeId) or {}) do
        if pin.name == pinName and pin.kind == "data" and pin.direction == "in" then
            return pin
        end
    end
    return nil
end

-- Answers follow stored Variable order. A number is parsed; a blank is not stored as 0.
-- A Matcher answer is the needle. The mode already on that Control is kept.
---@param graph LibNodeGraph.Graph
---@param variables Watchdog.PresetVariable[]
---@param answers any[]
---@return string|nil err
local function bake(graph, variables, answers)
    if type(answers) ~= "table" or #answers ~= #variables then
        return "A marked control is missing."
    end
    for i, mark in ipairs(variables) do
        local node = graph.nodes[mark.nodeId]
        if node == nil or isPlaceholder(node) then
            return "A marked control is missing."
        end
        local pin = dataInPin(graph, mark.nodeId, mark.pinName)
        if pin == nil then
            return "A marked control is missing."
        end
        local widget = ControlKinds.Widget(pin.dataType)
        local answer = answers[i]
        if widget == "number" then
            local raw, quantity = answer, nil
            if type(answer) == "table" then
                raw = answer.raw
                quantity = answer.quantity
            end
            local parsed = NumberField.Parse(raw, quantity)
            if parsed == nil then
                return "Enter a number."
            end
            graph:SetControl(mark.nodeId, mark.pinName, parsed)
        elseif widget == "text" then
            if type(answer) ~= "string" then
                return "A marked control is missing."
            end
            graph:SetControl(mark.nodeId, mark.pinName, answer)
        elseif widget == "enum" then
            graph:SetControl(mark.nodeId, mark.pinName, answer)
        elseif widget == "matcher" then
            if type(answer) ~= "string" then
                return "A marked control is missing."
            end
            local existing = graph:GetControl(mark.nodeId, mark.pinName)
            local mode = "substring"
            if type(existing) == "table" and (existing.mode == "pattern" or existing.mode == "substring") then
                mode = existing.mode
            end
            graph:SetControl(mark.nodeId, mark.pinName, { needle = answer, mode = mode })
        else
            return "A marked control is missing."
        end
    end
    return nil
end

-- One copy path for a library Preset and an Alert Preset snapshot, so bake is not forked.
-- Does not save the Bucket and does not write the Preset library.
---@param bucket Watchdog.Bucket
---@param name string|nil
---@param graphData table|nil
---@param layoutData Watchdog.LayoutArray|nil
---@param variables Watchdog.PresetVariable[]|nil
---@param registry LibNodeGraph.Registry
---@param answers any[]|nil
---@param reportLabel any
---@return Watchdog.Entry|nil entry
---@return LibNodeGraph.Graph|nil graph
---@return Watchdog.Layout|nil layout
---@return string|nil err
local function instantiateSnapshot(bucket, name, graphData, layoutData, variables, registry, answers, reportLabel)
    local hasVariables = type(variables) == "table" and #variables > 0
    if hasVariables and answers == nil then
        return nil, nil, nil, "variables"
    end
    if LibNodeGraph == nil or LibNodeGraph.Deserialize == nil then
        return nil, nil, nil, "Could not copy the preset graph."
    end
    local ok, graph = pcall(function()
        return LibNodeGraph.Deserialize(graphData, registry, { onUnknown = "placeholder" })
    end)
    if not ok or graph == nil then
        report("could not instantiate preset " .. tostring(reportLabel) .. " - " .. tostring(graph))
        return nil, nil, nil, "Could not copy the preset graph."
    end
    if hasVariables then
        local bakeErr = bake(graph, variables, answers)
        if bakeErr ~= nil then
            return nil, nil, nil, bakeErr
        end
    end
    local layout = layoutFromArray(layoutData)
    local entry = Store.NewAlertEntry(Store.MintId(bucket), trim(name), graph, layout, true)
    if not Store.InsertEntry(bucket, entry) then
        return nil, nil, nil, "Could not create the alert."
    end
    return entry, graph, layout, nil
end

-- Answers bake a Preset that has Variables. Nil answers on a marked Preset still returns
-- "variables" and writes nothing. Empty variables keep the previous result: an enabled Alert,
-- a new Entry id, the Preset name, and the snapshot's node ids. The snapshot has no enabled flag.
---@param bucket Watchdog.Bucket
---@param presetId integer
---@param registry LibNodeGraph.Registry
---@param answers any[]|nil
---@return Watchdog.Entry|nil entry
---@return LibNodeGraph.Graph|nil graph
---@return Watchdog.Layout|nil layout
---@return string|nil err
function Presets.Instantiate(bucket, presetId, registry, answers)
    if type(bucket) ~= "table" or registry == nil then
        return nil, nil, nil, "No scope to create the alert in."
    end
    local doc, err = Presets.Load()
    if doc == nil then
        return nil, nil, nil, err
    end
    local preset
    for _, candidate in ipairs(doc.presets) do
        if candidate.id == presetId then
            preset = candidate
            break
        end
    end
    if preset == nil then
        return nil, nil, nil, "Preset not found."
    end
    return instantiateSnapshot(bucket, preset.name, preset.graph, preset.layout, preset.variables, registry, answers, presetId)
end

--- Copies a captured Alert Preset into an enabled Alert in the caller's Bucket.
--- Unknown node types become placeholders. Nil answers on a snapshot that has
--- Variables writes nothing. Does not save the Bucket, mint a Preset id, or
--- keep the author id or Pack name.
---@param bucket Watchdog.Bucket
---@param snapshot Watchdog.PackAlertPreset
---@param registry LibNodeGraph.Registry
---@param answers any[]|nil
---@return Watchdog.Entry|nil entry
---@return LibNodeGraph.Graph|nil graph
---@return Watchdog.Layout|nil layout
---@return string|nil err
function Presets.InstantiateSnapshot(bucket, snapshot, registry, answers)
    if type(bucket) ~= "table" or registry == nil then
        return nil, nil, nil, "No scope to create the alert in."
    end
    if type(snapshot) ~= "table" then
        return nil, nil, nil, "Could not copy the preset graph."
    end
    return instantiateSnapshot(
        bucket, snapshot.name, snapshot.graph, snapshot.layout, snapshot.variables,
        registry, answers, snapshot.name)
end

---@param graph LibNodeGraph.Graph
---@param node table
---@return string
local function typeLabelOf(graph, node)
    if isPlaceholder(node) then
        local original = "?"
        if node.unknown ~= nil and type(node.unknown.type) == "string" and node.unknown.type ~= "" then
            original = node.unknown.type
        end
        return "Unknown: " .. original
    end
    local nodeType = nil
    if graph.registry ~= nil and graph.registry.GetNodeType ~= nil then
        nodeType = graph.registry:GetNodeType(node.typeKey)
    end
    if nodeType == nil then return node.typeKey end
    return nodeType.displayName or node.typeKey
end

---@param node table
---@return string|nil
local function storedNameOf(node)
    if isPlaceholder(node) then
        if node.unknown == nil then return nil end
        return node.unknown.name
    end
    return node.name
end

---@param graph LibNodeGraph.Graph
---@param nodeId integer
---@return string|nil
function Presets.NodeTitle(graph, nodeId)
    local node = graph.nodes[nodeId]
    if node == nil then return nil end
    return Node.HeaderTitle(typeLabelOf(graph, node), storedNameOf(node))
end

-- Declared pin label, or the pin name when the type did not set one.
---@param graph LibNodeGraph.Graph
---@param nodeId integer
---@param pinName string
---@return string
function Presets.PinLabel(graph, nodeId, pinName)
    for _, pin in ipairs(graph:GetPins(nodeId) or {}) do
        if pin.name == pinName then
            if type(pin.label) == "string" and pin.label ~= "" then
                return pin.label
            end
            return pin.name
        end
    end
    return pinName
end

--- `{Type} - {Name}: {pin label}`. Name is `New {Type}` when the node has no stored name.
---@param typeLabel string
---@param storedName string|nil
---@param pinLabel string
---@return string
function Presets.VariableLabel(typeLabel, storedName, pinLabel)
    return Node.HeaderTitle(typeLabel, storedName) .. ": " .. pinLabel
end

---@param graph LibNodeGraph.Graph
---@param nodeId integer
---@param pinName string
---@return string|nil
function Presets.MarkLabel(graph, nodeId, pinName)
    local node = graph.nodes[nodeId]
    if node == nil then return nil end
    return Presets.VariableLabel(
        typeLabelOf(graph, node),
        storedNameOf(node),
        Presets.PinLabel(graph, nodeId, pinName))
end

-- Snapshotted choice when that choice is still offered; otherwise the type's default.
---@param snapshot any
---@param choices { value: any, label: string }[]|nil
---@param defaultValue any
---@return any
function Presets.EnumInitial(snapshot, choices, defaultValue)
    for _, choice in ipairs(choices or {}) do
        if type(choice) == "table" and choice.value == snapshot then
            return snapshot
        end
    end
    return defaultValue
end

return Presets
