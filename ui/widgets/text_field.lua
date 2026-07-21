-- text_field.lua — the text-field Widget (ADR-0005): a generic, engine-agnostic input primitive
-- that edits a single free-text value. Like number_field it owns nothing but the value CODEC —
-- how a stored value renders as text (Format) and how typed text becomes a stored value (Parse).
-- The one behavioral difference from number_field is what an EMPTY box means: for text, empty is
-- a MEANINGFUL value (it's how the user clears a field, e.g. an InfoBox `title`), so Parse returns
-- the empty string verbatim rather than nil — there is no empty-box guard here. A Pin Control
-- composes it (the string scalar) and maps its text to/from the Pin's stored Control value.
--
-- Like every Widget it knows nothing of Pins, Nodes, the Graph, the Store, or the engine, and may
-- depend only on Theme/Color/`ui.*` — the codec below needs none of those, so it requires nothing.

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
