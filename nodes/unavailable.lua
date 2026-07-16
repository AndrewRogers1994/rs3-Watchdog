-- unavailable.lua — nodes that can't be built on the current RS3 API (see TODO.md, the
-- feasibility source of truth). A plain data table of { displayName, category, reason }
-- entries the Palette (ui/palette.lua) reads to render dimmed, inert rows interleaved
-- among live Node Types on an unfiltered open, so the gap is visible instead of silent.
--
-- Nothing here is registered with the Registry, instantiated as a Node, or serialized —
-- these are display-only. RuneLite-specific cross-plugin nodes (Notification Fired, Tray
-- Notification, Dink, Shortest Path, Plugin Message/Toggle, Notification Event) have no
-- RS3 equivalent to even gesture at, so they're omitted entirely rather than listed here.

return {
    { displayName = "Overhead Text",   category = "trigger", reason = "no overhead-text event" },
    { displayName = "Sound Fired",     category = "trigger", reason = "no sound-played event" },
    { displayName = "Inventory",       category = "trigger", reason = "no inventory-read API" },
    { displayName = "Game Message",    category = "action",  reason = "no chat-injection API" },
    { displayName = "Overhead",        category = "action",  reason = "no overhead-text API" },
    { displayName = "Request Focus",   category = "action",  reason = "no focus-request API" },
    { displayName = "Text to Speech",  category = "action",  reason = "needs file write" },
}
