local Text = {}

---@param s string
---@return string
function Text.StripTags(s)
    if type(s) ~= "string" then
        return s
    end
    -- Parenthesized so gsub's second return (the substitution count) is dropped.
    return (s:gsub("<[^>]*>", ""))
end

-- If the node has only tags, it will revert to default name.
---@param name string
---@return string|nil
local function stripNodeName(name)
    local stripped = Text.StripTags(name)
    if stripped == "" then return nil end
    return stripped
end

-- Strip string and matcher values.
---@param value any
---@return any
local function stripNodeControlValues(value)
    if type(value) == "string" then
        return Text.StripTags(value)
    end
    if type(value) == "table" and type(value.needle) == "string" then
        value.needle = Text.StripTags(value.needle)
    end
    return value
end

-- Strip text from graph.
---@param graph table|nil
function Text.StripGraphText(graph)
    if type(graph) ~= "table" or type(graph.nodes) ~= "table" then return end
    for _, node in pairs(graph.nodes) do
        if type(node) == "table" then
            if type(node.name) == "string" then
                node.name = stripNodeName(node.name)
            end
            local unknown = node.unknown
            if type(unknown) == "table" then
                if type(unknown.name) == "string" then
                    unknown.name = stripNodeName(unknown.name)
                end
            elseif type(node.controls) == "table" then
                for pin, value in pairs(node.controls) do
                    node.controls[pin] = stripNodeControlValues(value)
                end
            end
        end
    end
end

return Text
