-- The reusable Matcher (#55): a text-match specification carried by a Data Pin (Type Tag
-- `matcher`) plus the shared `Test` helper. Every node that filters text — chat message, chat
-- sender, entity name, … — reuses this one value shape and this one matching function rather
-- than reimplementing "contains" per node, so match semantics stay identical everywhere.

-- The value shape a `matcher` pin carries. `mode` selects the matching semantics; a nil/empty
-- `needle` is a no-op filter (matches everything).
---@class Watchdog.MatcherValue
---@field needle string             # text to look for; empty/nil matches every haystack
---@field mode "substring"|"pattern" # "substring" = case-insensitive literal; "pattern" = case-sensitive Lua pattern

local Matcher = {}

-- Tests `haystack` against the Matcher `value`, returning whether it matches:
--   * empty/nil needle (or nil value) — always true; the filter is a no-op.
--   * "substring" (default) — case-insensitive, literal: special characters match themselves.
--   * "pattern" — case-sensitive, with Lua magic characters (`.`, `%d`, `^`, …) active.
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

    -- Substring (default): plain find on lowercased text, so it is case-insensitive and takes
    -- the needle literally (the `true` argument disables Lua pattern magic).
    return string.find(haystack:lower(), needle:lower(), 1, true) ~= nil
end

return Matcher
