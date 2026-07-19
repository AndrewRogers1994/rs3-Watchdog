-- Watchdog-wide text helpers for client strings (#55). The client hands nodes lines carrying
-- formatting tags — `<col=…>`, `<shad=…>`, `</col>`, `<br>`, … — that a user never sees
-- rendered. `StripTags` removes them so every node matches and emits clean, what-you-see text
-- instead of raw markup. Shared here (rather than per node) so stripping stays consistent
-- across chat triggers, entity-name matching, toast/TTS outputs, and anything else.

local Text = {}

-- Removes every `<…>` formatting tag from `s`, returning the visible text. A tag is any run
-- from `<` to the next `>`; adjacent and mid-string tags are all removed. A string with no
-- tags (including the empty string) comes back unchanged.
---@param s string
---@return string
function Text.StripTags(s)
    if type(s) ~= "string" then
        return s
    end
    -- Parenthesized so gsub's second return (the substitution count) is dropped.
    return (s:gsub("<[^>]*>", ""))
end

return Text
