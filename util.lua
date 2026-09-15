local Util = {}

-- pcall-guard node/effect callbacks so one error can't break the shared dispatch loop.
function Util.CallOrLog(label, context, fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok and log ~= nil then
        log("Watchdog " .. label .. ": " .. context .. " - " .. tostring(result))
    end
    return ok, result
end

---@param name string|nil
---@return string
function Util.NormalizePlayerName(name)
    if type(name) ~= "string" then return "" end
    -- RS3 may insert a non-breaking space between name words. Fold UTF-8 NBSP
    -- (C2 A0) first so a lone-byte fold cannot leave a stray C2 and orphan the key.
    name = name:gsub("\194\160", " ")
    name = name:gsub("[%s\160]+", " ")
    name = name:gsub("^ +", ""):gsub(" +$", "")
    return name:lower()
end

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
