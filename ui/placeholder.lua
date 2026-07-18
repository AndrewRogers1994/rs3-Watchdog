-- placeholder.lua — display-only pin stubs for a `__unknown__` placeholder node (#53).
--
-- A placeholder stands in for a node whose real type isn't registered (usually a dependency
-- plugin that didn't load — see store.lua / LibNodeGraph's lenient Deserialize). It has NO
-- real pins (graph:GetPins returns []), yet its saved wires still carry the pin names they
-- attach to. So the editor can't read pin geometry off the node type — it reconstructs
-- ephemeral stubs from the graph's connections instead: every wire touching the placeholder
-- contributes the placeholder's own endpoint as a stub (a `toPin` -> input, a `fromPin` ->
-- output).
--
-- These stubs exist ONLY as editor geometry for this frame — they're never stored on the node
-- and never serialized (the wires already carry the pin names for a lossless round-trip). Their
-- kind (exec/data) and dataType are inferred from the OTHER end of each wire when that node is
-- known, purely so the stub glyph/wire draws in the right shape and color; when the other end
-- is itself a placeholder (or its pin can't be resolved) the stub is neutral.

local Placeholder = {}

-- Neutral shape when the other endpoint can't tell us what the pin really is (both ends are
-- placeholders, or the resolved node has no such pin): a plain "any" data stub — a grey square.
local NEUTRAL_KIND = "data"
local NEUTRAL_TYPE = "any"

-- Builds the stub pin list for placeholder `nodeId`, in the same shape `graph:GetPins` returns
-- (name/kind/direction/dataType/label) so Node.BuildGeometry can lay them out unchanged.
-- Deduped by (direction, name) — several wires off one output pin yield a single stub — and
-- sorted (inputs before outputs, then by name) so the pin rows are stable frame to frame
-- despite `GetConnections` iteration order.
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

    local seen = {}   -- (direction .. ":" .. name) -> true, for dedupe
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
