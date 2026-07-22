-- Small shared helpers used by more than one top-level Watchdog module.

local Util = {}

-- pcalls `fn`, logging (and swallowing) any error under "Watchdog <label>: <context>". Used
-- for any node/effect-authored callback (transform/filter/update/draw/onDone, ...) so one bad
-- callback can't break dispatch/advancement for everything else sharing the same loop.
function Util.CallOrLog(label, context, fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok and log ~= nil then
        log("Watchdog " .. label .. ": " .. context .. " — " .. tostring(result))
    end
    return ok, result
end

-- Shallow-copies `tbl` (or `{}` when it isn't a table) into a fresh table, then sets one field.
-- The read-modify-write a table Control uses to change one key without dropping its siblings.
---@param tbl table|nil
---@param key any
---@param value any
---@return table
function Util.CopyWithField(tbl, key, value)
    local out = {}
    if type(tbl) == "table" then
        for k, v in pairs(tbl) do out[k] = v end
    end
    out[key] = value
    return out
end

return Util
