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

return Text
