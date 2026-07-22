-- text_field.lua — the text-field Widget (ADR-0005): a generic input primitive that owns only the
-- value CODEC (Format/Parse). Unlike number_field an EMPTY box is a MEANINGFUL value (how the user
-- clears a field), so Parse returns "" verbatim rather than nil — there is no empty-box guard here.

---@class TextField
local TextField = {}

-- Renders a stored value as the text an editor field shows. A nil value (a Control never set)
-- formats to the empty string, so the box reads as empty rather than showing "nil".
---@param value any
---@return string
function TextField.Format(value)
    if value == nil then return "" end
    return tostring(value)
end

-- Interprets an edited field into a committable string. Unlike the number codec there is NO
-- empty-box guard: an empty or whitespace box is a real value (clearing the field), committed
-- verbatim. `quantity` (a numeric field's pre-parsed number) is meaningless for text and ignored.
---@param raw string
---@param _quantity number|nil
---@return string
function TextField.Parse(raw, _quantity)
    if type(raw) ~= "string" then return "" end
    return raw
end

return TextField
