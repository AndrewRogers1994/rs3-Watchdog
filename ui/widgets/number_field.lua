-- number_field.lua — the number-field Widget (ADR-0005): a generic input primitive that owns only
-- the value CODEC — how a number renders as text (Format) and how typed text becomes a number
-- (Parse). The real ui.InputField that captures keystrokes is host-mounted; this supplies only the
-- codec that seeds it and interprets its result.

---@class NumberField
local NumberField = {}

-- Renders a numeric value as the text an editor field shows. A nil value (an unseeded axis, a
-- Control never set) formats to the empty string rather than "nil", so the box reads as empty.
---@param value number|nil
---@return string
function NumberField.Format(value)
    if value == nil then return "" end
    return tostring(value)
end

-- Interprets an edited field into a committable number, or nil for "nothing to commit".
--
-- `quantity` is the field's own pre-parsed number (a real `ui.InputField`'s `contentQuantity`,
-- which honors magnitude suffixes like `1K`/`1M` that `tonumber` cannot) and is preferred over
-- re-parsing `raw` when present. An empty or whitespace-only box returns nil — the empty-box
-- guard from ADR-0005: a caller must leave its stored value untouched rather than overwrite it
-- with 0 when the user opens then closes a field without typing. An unparsable string is nil
-- for the same reason.
---@param raw string
---@param quantity number|nil
---@return number|nil
function NumberField.Parse(raw, quantity)
    if type(raw) == "string" and raw:match("^%s*$") then return nil end
    if quantity ~= nil then return quantity end
    return tonumber(raw)
end

return NumberField
