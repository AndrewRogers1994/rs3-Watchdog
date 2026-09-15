local Placeholder = {}

local NEUTRAL_KIND = "data"
local NEUTRAL_TYPE = "any"

---@param graph LibNodeGraph.Graph
---@param nodeId integer
---@return { name: string, kind: string, direction: string, dataType: string|nil, label: string }[]
function Placeholder.Stubs(graph, nodeId)
    -- Lazily resolve + cache the other node's pins, so the shape/color inference costs one
    -- GetPins per neighbor rather than per wire. A placeholder neighbor returns [] here.
    local pinCache = {}
    local function otherPin(otherId, pinName)
        local pins = pinCache[otherId]
        if pins == nil then
            pins = {}
            for _, p in ipairs(graph:GetPins(otherId) or {}) do
                pins[p.name] = p
            end
            pinCache[otherId] = pins
        end
        return pins[pinName]
    end

    local seen = {}
    local stubs = {}
    local function add(name, direction, otherId, otherPinName)
        local key = direction .. ":" .. name
        if seen[key] then return end
        seen[key] = true
        local op = otherPin(otherId, otherPinName)
        local kind = op and op.kind or NEUTRAL_KIND
        stubs[#stubs + 1] = {
            name = name,
            direction = direction,
            kind = kind,
            -- Only data pins carry a Type Tag; an exec stub leaves it nil (matches real pins).
            dataType = (kind == "data") and ((op and op.dataType) or NEUTRAL_TYPE) or nil,
            label = name,
        }
    end

    for _, c in ipairs(graph:GetConnections()) do
        if c.toNode == nodeId then
            add(c.toPin, "in", c.fromNode, c.fromPin)
        end
        if c.fromNode == nodeId then
            add(c.fromPin, "out", c.toNode, c.toPin)
        end
    end

    table.sort(stubs, function(a, b)
        if a.direction ~= b.direction then return a.direction < b.direction end
        return a.name < b.name
    end)
    return stubs
end

return Placeholder
