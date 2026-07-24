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

-- Normalizes a character display name into the stable form a per-character Bucket keys on (#89):
-- lowercased, every run of whitespace — ASCII *and* the non-breaking space (byte 0xA0) RS3 puts
-- between name words — folded to a single plain space, then trimmed. Keying the bucket on this
-- means a cosmetic case/whitespace difference in what `PlayerEntity.displayName` returns cannot
-- silently orphan a bucket (#77 §4). A non-string (never logged in / bad read) folds to "".
---@param name string|nil
---@return string
function Util.NormalizePlayerName(name)
    if type(name) ~= "string" then return "" end
    -- Collapse the non-breaking space in *either* encoding the client might hand back: UTF-8
    -- (the two bytes 0xC2 0xA0) folded first as a unit so its trailing byte can't be left behind,
    -- then the class folds ASCII whitespace and a lone Latin-1 0xA0. Doing only the single byte
    -- would leave a stray 0xC2 on a UTF-8 name — a different key, i.e. the orphan this prevents.
    name = name:gsub("\194\160", " ")
    name = name:gsub("[%s\160]+", " ")
    name = name:gsub("^ +", ""):gsub(" +$", "")
    return name:lower()
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
