-- Oldest first. A version with no entry never pops.
-- { version = "1.2.0", paragraphs = { "..." } }

---@type Watchdog.ReleaseNote[]
local catalog = {
    {
        version = "1.0.0",
        paragraphs = {
            "This is the first release of the Watchdog plugin.",
        }
    },
}

return catalog
