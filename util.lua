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

return Util
