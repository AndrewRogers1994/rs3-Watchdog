---@class Watchdog.MatcherValue
---@field needle string             # text to look for; empty/nil matches every haystack
---@field mode "substring"|"pattern" # "substring" = case-insensitive literal; "pattern" = case-sensitive Lua pattern

local Matcher = {}

---@param value Watchdog.MatcherValue|nil
---@param haystack string|nil
---@return boolean
function Matcher.Test(value, haystack)
    local needle = value and value.needle
    if needle == nil or needle == "" then
        return true
    end

    haystack = haystack or ""

    if value.mode == "pattern" then
        return string.find(haystack, needle) ~= nil
    end

    -- `true` disables Lua pattern magic so substring mode is literal and case-insensitive.
    return string.find(haystack:lower(), needle:lower(), 1, true) ~= nil
end

return Matcher
