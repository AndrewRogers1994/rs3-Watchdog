-- Variable text for the Preset dialog. The Preset library does not own these labels.
-- A pack sound effect record shows its builtin sound id. The caller passes the
-- Pack registry; this module does not call Packs.live().

local Node = require("src/ui/node")
local NumberField = require("src/ui/widgets/number_field")
local PackRows = require("src/pack_rows")

local PresetLabels = {}

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
function PresetLabels.NodeTitle(graph, nodeId)
    local node = graph.nodes[nodeId]
    if node == nil then return nil end
    return Node.HeaderTitle(typeLabelOf(graph, node), storedNameOf(node))
end

-- Declared pin label, or the pin name when the type did not set one.
---@param graph LibNodeGraph.Graph
---@param nodeId integer
---@param pinName string
---@return string
function PresetLabels.PinLabel(graph, nodeId, pinName)
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
function PresetLabels.VariableLabel(typeLabel, storedName, pinLabel)
    return Node.HeaderTitle(typeLabel, storedName) .. ": " .. pinLabel
end

---@param graph LibNodeGraph.Graph
---@param nodeId integer
---@param pinName string
---@return string|nil
function PresetLabels.MarkLabel(graph, nodeId, pinName)
    local node = graph.nodes[nodeId]
    if node == nil then return nil end
    return PresetLabels.VariableLabel(
        typeLabelOf(graph, node),
        storedNameOf(node),
        PresetLabels.PinLabel(graph, nodeId, pinName))
end

-- pack_rows owns which choice matches a stored pack identity. The Preset library
-- does not ask it. Reference equality stays here for callers that are not
-- comparing pack identities.
---@param left any
---@param right any
---@return boolean
function PresetLabels.sameStored(left, right)
    return left == right
end

---@param rows { value: any, label: string }[]|nil
---@param stored any
---@return integer|nil
local function matchingChoice(rows, stored)
    return PackRows.MatchingChoice(rows, stored)
end

---@param value any
---@return boolean
local function isPackIdentity(value)
    return type(value) == "table"
        and type(value.pack) == "string"
        and type(value.authorId) == "string"
end

-- Snapshotted choice when that choice is still offered; otherwise the type's default.
-- A Pack audio record that is not in the list is kept, so it is not baked as None.
---@param snapshot any
---@param choices { value: any, label: string }[]|nil
---@param defaultValue any
---@return any
function PresetLabels.EnumInitial(snapshot, choices, defaultValue)
    local index = matchingChoice(choices, snapshot)
    if index ~= nil then
        return choices[index].value
    end
    if isPackIdentity(snapshot) then return snapshot end
    return defaultValue
end

--- The offered rows, plus the stored Pack identity when the list does not
--- already contain it. A frozen choice list from before the Pack was installed
--- must not drop that record.
---@param choices { value: any, label: string }[]|nil
---@param snapshot any
---@param missingLabel string|nil
---@return { value: any, label: string }[]
function PresetLabels.withStoredChoice(choices, snapshot, missingLabel)
    local offered = {}
    for i, choice in ipairs(choices or {}) do
        offered[i] = choice
    end
    if not isPackIdentity(snapshot) then return offered end
    if matchingChoice(offered, snapshot) ~= nil then
        return offered
    end
    local label = missingLabel
    if type(label) ~= "string" or label == "" then
        label = snapshot.pack .. " / " .. snapshot.authorId
    end
    offered[#offered + 1] = { value = snapshot, label = label }
    return offered
end

--- What the Variable dialog stores for an enum pin, and the choices it shows.
--- A pack audio record survives even when the recorded choice list does not contain it.
---@param snapshot any
---@param choices { value: any, label: string }[]|nil
---@param defaultValue any
---@param missingLabel string|nil
---@return any value
---@return { value: any, label: string }[] choices
function PresetLabels.EnumSlotValue(snapshot, choices, defaultValue, missingLabel)
    local offered = PresetLabels.withStoredChoice(choices, snapshot, missingLabel)
    local initial = PresetLabels.EnumInitial(snapshot, offered, defaultValue)
    local index = matchingChoice(offered, initial)
    if index ~= nil then
        return offered[index].value, offered
    end
    if isPackIdentity(initial) then
        return initial, offered
    end
    if offered[1] ~= nil then
        return offered[1].value, offered
    end
    return initial, offered
end

--- The number a Variable field shows. A pack sound record shows its builtin
--- sound id, so Create is not disabled just because the stored value is a record.
--- The caller passes the Pack registry.
---@param registry Watchdog.PackRegistry
---@param value any
---@return string
function PresetLabels.NumberVariableText(registry, value)
    return NumberField.Format(registry:ResolveSoundEffect(value))
end

return PresetLabels
