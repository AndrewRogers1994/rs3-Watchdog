-- unavailable.lua — nodes that can't be built on the current RS3 API (see TODO.md, the
-- feasibility source of truth). A plain data table of { displayName, category, description }
-- entries the Palette (ui/palette.lua) reads to render dimmed, inert rows interleaved
-- among live Node Types on an unfiltered open, so the gap is visible instead of silent. The
-- `description` (the "why unavailable" blurb) is the same field a live Node Type can now
-- carry (#52), rendered the same inline dimmed-suffix way — one concept, not two.
--
-- Nothing here is registered with the Registry, instantiated as a Node, or serialized —
-- these are display-only. RuneLite-specific cross-plugin nodes (Notification Fired, Tray
-- Notification, Dink, Shortest Path, Plugin Message/Toggle, Notification Event) have no
-- RS3 equivalent to even gesture at, so they're omitted entirely rather than listed here.

return {
    { displayName = "Overhead Text",   category = "trigger", description = "no overhead-text event" },
    { displayName = "Sound Fired",     category = "trigger", description = "no sound-played event" },
    { displayName = "Game Message",    category = "action",  description = "no chat-injection API" },
    { displayName = "Overhead",        category = "action",  description = "no overhead-text API" },
    { displayName = "Request Focus",   category = "action",  description = "no focus-request API" },
    { displayName = "Text to Speech",  category = "action",  description = "needs file write" },
}
