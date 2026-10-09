-- Why a registered Node Type is Unavailable right now, keyed by type.
-- The registry keeps a copy of the type definition and drops fields it does not
-- know, so the Palette cannot read a gate off that copy. The node module binds
-- a function that closes over the same flag its run uses.

local Gates = {}

---@type table<string, fun(): string|nil>
local byKey = {}

---@param typeKey string
---@param reasonFn fun(): string|nil
function Gates.Bind(typeKey, reasonFn)
    byKey[typeKey] = reasonFn
end

---@param typeKey string
---@return string|nil
function Gates.Reason(typeKey)
    local reasonFn = byKey[typeKey]
    if type(reasonFn) ~= "function" then return nil end
    local reason = reasonFn()
    if type(reason) ~= "string" or reason == "" then return nil end
    return reason
end

return Gates
