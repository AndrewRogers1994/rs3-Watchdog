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

---@param color table|nil  -- expects { r = 0-255, g = 0-255, b = 0-255, a = 0-255 (optional, default=255) }
---@return integer|nil
function Util.ColorToInt(color)
    if type(color) ~= "table" then return nil end
    local r = tonumber(color.r) or 0
    local g = tonumber(color.g) or 0
    local b = tonumber(color.b) or 0
    local a = tonumber(color.a) or 255
    if r < 0 or r > 255 or g < 0 or g > 255 or b < 0 or b > 255 or a < 0 or a > 255 then
        return nil
    end
    return (r << 24) | (g << 16) | (b << 8) | a
end

-- Half away from zero. floor(n + 0.5) turns -1.5 into -1.
---@param n number
---@return number
function Util.RoundHalfAway(n)
    if n >= 0 then
        return math.floor(n + 0.5)
    end
    return -math.floor(-n + 0.5)
end

-- RestrictedAreas owns the area predicate.
---@return boolean
function Util.PlayerIsRestricted()
    return RestrictedAreas.IsRestricted() == true
end


return Util
