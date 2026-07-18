-- store.lua — Watchdog's graph persistence backend: saves and restores graphs.
--
-- LibNodeGraph deliberately never touches persistentdb (ADR-0007): the library only
-- produces/consumes tables + strings, and the *consumer* owns actual persistence. This
-- module is that consumer half for Watchdog. It bundles the two things a saved graph
-- needs — the engine's serialized structure (nodes + Connections), plus the one piece
-- of UI-only state the engine has no concept of: the Layout (nodeId -> Graph-space
-- position) — into one document, and stores it under a single persistentdb key as one
-- JSON string (SetString/GetString), the flat-scalar shape persistentdb is happiest with.
-- (The View — pan/zoom — is deliberately NOT persisted: the editor resets it to a default
-- origin on every open, so there's nothing worth carrying across sessions.)
--
-- Multi-graph from day one: the document holds an *array* of named graph entries plus a
-- `current` pointer, even though the editor only shows one today. Adding the "new graph /
-- switch graph" UI later is purely additive — the backend already keys everything by name.
--
--   { version, current = <name|nil>, graphs = { { name, graph, layout, enabled }, ... } }
--
-- Each entry also carries a persistent `enabled` flag (#27): a saved graph *is* an "alert", and
-- disabling one silences its triggers without deleting it. The flag defaults to true and is
-- carried additively — old documents (written before it existed) load with a missing flag, which
-- Restore/RestoreAll treat as enabled so a pre-#27 save keeps firing after upgrade.
--
-- `graph` is exactly what LibNodeGraph.Serialize produces (the same shareable structure a
-- user would export), so there is no separate saved-vs-shared representation. Layout is
-- stored as an array of { id, x, y } rather than an id-keyed map because JSON object keys
-- must be strings; it round-trips back to a nodeId-keyed map on load. That mapping only
-- stays valid because LibNodeGraph.Deserialize preserves node ids.

local Store = {}

local DB_KEY = "watchdog_graphs"
local DOC_VERSION = 1

--- Persisted schema -----------------------------------------------------------------------
-- These describe exactly what lives under the DB_KEY JSON string. `Watchdog.StoreDocument` is
-- the single shape that round-trips: it's what `Store.Load` returns and what `Store.Save`,
-- `Store.Encode`, and `Store.UpsertCurrent` consume — so the type *is* the persistence contract.

---One saved graph == one "alert" (#27). This is the on-disk form: the graph is the flat
---`LibNodeGraph.SerializedGraph` (not a live Graph), the layout is the array form (not the
---id-keyed map), and `enabled` is always a strict boolean once written.
---@class Watchdog.StoredGraphEntry
---@field name string                              # unique key within the document
---@field graph LibNodeGraph.SerializedGraph       # LibNodeGraph.Serialize output
---@field layout Watchdog.LayoutArray              # node positions, on-disk array form
---@field enabled boolean                          # whether this alert's triggers fire

---The whole persisted document: an array of named graph entries plus a `current` pointer and
---the shared InfoBox anchor. The one type that survives a save -> load round-trip intact.
---@class Watchdog.StoreDocument
---@field version integer                          # schema version (DOC_VERSION), for migrations
---@field current string|nil                       # name of the entry the editor last showed
---@field graphs Watchdog.StoredGraphEntry[]       # every saved alert, in stored order
---@field infoboxAnchor Watchdog.Point|nil         # shared InfoBox strip position (#41); nil until moved

---A saved entry rebuilt into live objects (the return shape of Restore/RestoreAll). Mirrors a
---StoredGraphEntry but with the runtime forms: a live `LibNodeGraph.Graph` and the id-keyed
---`Watchdog.Layout`.
---@class Watchdog.RestoredAlert
---@field name string
---@field graph LibNodeGraph.Graph
---@field layout Watchdog.Layout
---@field enabled boolean

-- The JSON codec and the graph (de)serializers live in the LibNodeGraph plugin, injected
-- as a global (same as main.lua reaches LibNodeGraph.NewGraph). Fetched lazily so this
-- module can load even if the lib isn't present yet.
---@return LibNodeGraph.Codec|nil
local function codec()
    if LibNodeGraph ~= nil and LibNodeGraph.Json ~= nil then
        return LibNodeGraph.Json.Default
    end
    return nil
end

--- Layout <-> JSON-safe shapes ------------------------------------------------------------

---A node's on-canvas position, in Graph-space (the pan/zoom-independent coordinate the View
---transform maps to the screen). Top-left corner of the node box.
---@class Watchdog.Point
---@field x number
---@field y number

---The editor's Layout: where each node sits on the canvas, keyed by its LibNodeGraph node id.
---Purely UI state — the engine has no concept of node position, so Watchdog owns this and
---persists it alongside the serialized graph (see store.lua's module comment). A node id with
---no entry falls back to a default placement when first drawn.
---@alias Watchdog.Layout table<integer, Watchdog.Point>

---The on-disk form of a Layout: an array of { id, x, y } records. JSON object keys must be
---strings, so the id can't be a table key here — it rides as a field and round-trips back to a
---nodeId-keyed Watchdog.Layout on load. Sorted by id purely so saved files diff cleanly.
---@alias Watchdog.LayoutArray { id: integer, x: number, y: number }[]

---@param layout Watchdog.Layout|nil
---@return Watchdog.LayoutArray
local function layoutToArray(layout)
    local arr = {}
    for id, pos in pairs(layout or {}) do
        arr[#arr + 1] = { id = id, x = pos.x, y = pos.y }
    end
    table.sort(arr, function(a, b) return a.id < b.id end)
    return arr
end

---@param arr Watchdog.LayoutArray|nil
---@return Watchdog.Layout
local function layoutFromArray(arr)
    local layout = {}
    for _, e in ipairs(arr or {}) do
        if e.id ~= nil then
            layout[e.id] = { x = e.x or 0, y = e.y or 0 }
        end
    end
    return layout
end

--- Document construction ------------------------------------------------------------------

---@return Watchdog.StoreDocument
function Store.Empty()
    return { version = DOC_VERSION, current = nil, graphs = {}, infoboxAnchor = nil }
end

--- InfoBox Area anchor (#41) --------------------------------------------------------------
-- The shared InfoBox strip's draggable anchor lives at the document's top level (it's not
-- per-graph state, unlike an alert's `enabled` flag) — one strip position for the whole
-- plugin, the same way runtime.lua's persistence hook already wires a per-alert flag through
-- Store.SetEnabled. Not persisted through Store.UpsertCurrent's autosave loop; the InfoBox
-- Area's own EndDrag calls this hook directly (main.lua wires it), same seam shape as
-- Runtime:SetPersistence.

---@param doc Watchdog.StoreDocument
---@param x number
---@param y number
function Store.SetInfoBoxAnchor(doc, x, y)
    doc.infoboxAnchor = { x = x, y = y }
end

-- Returns x, y, or nil, nil if no anchor was ever saved (a fresh install; the caller keeps
-- ui/infobox.lua's own default top-left anchor).
---@param doc Watchdog.StoreDocument
---@return number|nil x
---@return number|nil y
function Store.GetInfoBoxAnchor(doc)
    local a = doc.infoboxAnchor
    if a == nil then return nil, nil end
    return a.x, a.y
end

---@param doc Watchdog.StoreDocument
---@param name string
---@return integer|nil  # array index of the entry with that name, or nil if absent
local function indexOf(doc, name)
    for i, entry in ipairs(doc.graphs or {}) do
        if entry.name == name then return i end
    end
    return nil
end

-- Normalizes any stored/passed enabled value to a strict boolean, treating nil (a pre-#27
-- entry, or an omitted argument already resolved by the caller) as enabled.
---@param enabled boolean|nil
---@return boolean
local function normalizeEnabled(enabled)
    return enabled ~= false
end

---@param name string
---@param graph LibNodeGraph.Graph            # a live graph; serialized into the entry here
---@param layout Watchdog.Layout|nil
---@param enabled boolean|nil
---@return Watchdog.StoredGraphEntry
local function buildEntry(name, graph, layout, enabled)
    return {
        name = name,
        graph = LibNodeGraph.Serialize(graph),
        layout = layoutToArray(layout),
        enabled = normalizeEnabled(enabled),
    }
end

-- Inserts or replaces the named graph entry and marks it the current one. Mutates and
-- returns `doc`. `enabled` is optional: when omitted (nil) an existing entry keeps its current
-- flag — so the editor autosave loop, which re-upserts the current graph without knowing its
-- enabled state, never silently re-arms an alert the user disabled — and a brand-new entry
-- defaults to enabled.
---@param doc Watchdog.StoreDocument
---@param name string
---@param graph LibNodeGraph.Graph
---@param layout Watchdog.Layout|nil
---@param enabled boolean|nil                 # omit to preserve an existing entry's flag
---@return Watchdog.StoreDocument doc          # the same doc, mutated in place
function Store.UpsertCurrent(doc, name, graph, layout, enabled)
    doc.graphs = doc.graphs or {}
    local i = indexOf(doc, name)
    if enabled == nil then
        -- Preserve the existing flag (may be false — can't use `x and y or z` here), default
        -- true for a new entry.
        if i ~= nil then enabled = doc.graphs[i].enabled else enabled = true end
    end
    local entry = buildEntry(name, graph, layout, enabled)
    if i ~= nil then
        doc.graphs[i] = entry
    else
        doc.graphs[#doc.graphs + 1] = entry
    end
    doc.current = name
    return doc
end

-- Flips a saved entry's enabled flag in place (the runtime's persistence hook for
-- SetEnabled/Toggle). Returns true if the named entry existed, false otherwise (a stale name,
-- e.g. after a rename — accepted per #27). Does not persist; the caller runs Store.Save.
---@param doc Watchdog.StoreDocument
---@param name string
---@param enabled boolean
---@return boolean  # true if an entry with that name existed and was updated
function Store.SetEnabled(doc, name, enabled)
    local i = indexOf(doc, name)
    if i == nil then return false end
    doc.graphs[i].enabled = normalizeEnabled(enabled)
    return true
end

-- Rebuilds a live Graph + Layout from the named entry (defaults to doc.current).
-- Returns graph, layout, name, enabled — or a lone nil if there's no such entry to restore.
---@param doc Watchdog.StoreDocument
---@param registry LibNodeGraph.Registry
---@param name string|nil                    # entry to restore; defaults to doc.current
---@return LibNodeGraph.Graph|nil graph       # nil (and nothing else) when no entry matched
---@return Watchdog.Layout|nil layout
---@return string|nil name
---@return boolean|nil enabled
function Store.Restore(doc, registry, name)
    name = name or doc.current
    if name == nil then return nil end
    local i = indexOf(doc, name)
    if i == nil then return nil end
    local entry = doc.graphs[i]
    local graph = LibNodeGraph.Deserialize(entry.graph, registry)
    return graph, layoutFromArray(entry.layout), entry.name, normalizeEnabled(entry.enabled)
end

-- Rebuilds *every* saved graph into a live instance (#27: all saved graphs instantiate live at
-- startup, not just the current one, so triggers in every enabled alert fire). Returns an array
-- of { name, graph, layout, enabled } in stored order. An entry that fails to deserialize
-- (a node type no longer registered, a corrupt structure) is logged and skipped rather than
-- aborting the whole set, so one bad alert can't take the others down.
---@param doc Watchdog.StoreDocument
---@param registry LibNodeGraph.Registry
---@return Watchdog.RestoredAlert[]  # one live alert per restorable entry, in stored order
function Store.RestoreAll(doc, registry)
    local restored = {}
    for _, entry in ipairs((doc or {}).graphs or {}) do
        local ok, graph = pcall(function() return LibNodeGraph.Deserialize(entry.graph, registry) end)
        if ok and graph ~= nil then
            restored[#restored + 1] = {
                name = entry.name,
                graph = graph,
                layout = layoutFromArray(entry.layout),
                enabled = normalizeEnabled(entry.enabled),
            }
        elseif log ~= nil then
            log("Watchdog: skipping unrestorable graph '" .. tostring(entry.name) .. "' — " .. tostring(graph))
        end
    end
    return restored
end

---@param doc Watchdog.StoreDocument
---@return string[]  # every saved graph's name, in stored order
function Store.ListNames(doc)
    local names = {}
    for _, entry in ipairs((doc or {}).graphs or {}) do
        names[#names + 1] = entry.name
    end
    return names
end

--- persistentdb I/O -----------------------------------------------------------------------

-- Encodes the whole document to its JSON string. Exposed so a caller can cheaply diff the
-- current document against the last-saved string before deciding to persist.
---@param doc Watchdog.StoreDocument
---@return string|nil  # the JSON text, or nil if no codec is available / encoding failed
function Store.Encode(doc)
    local c = codec()
    if c == nil then return nil end
    local ok, text = pcall(function() return c.encode(doc) end)
    if ok then return text end
    return nil
end

-- Reads the saved document, or an empty one if there's nothing saved / it can't be parsed.
-- Never returns nil, so callers always get a document to upsert into.
---@return Watchdog.StoreDocument  # the same shape Store.Save persists (the round-trip contract)
function Store.Load()
    if PersistentDB == nil then return Store.Empty() end
    local text
    pcall(function() text = PersistentDB:GetString(DB_KEY) end)
    if type(text) ~= "string" or text == "" then return Store.Empty() end
    local c = codec()
    if c == nil then return Store.Empty() end
    local ok, doc = pcall(function() return c.decode(text) end)
    if not ok or type(doc) ~= "table" then
        if log ~= nil then log("Watchdog: saved graphs unreadable, starting fresh — " .. tostring(doc)) end
        return Store.Empty()
    end
    doc.version = doc.version or DOC_VERSION
    doc.graphs = doc.graphs or {}
    return doc
end

-- Persists the document as one JSON string. Returns true on success.
---@param doc Watchdog.StoreDocument  # the same shape Store.Load returns (the round-trip contract)
---@return boolean  # true if the document was encoded and written
function Store.Save(doc)
    if PersistentDB == nil then return false end
    local text = Store.Encode(doc)
    if text == nil then
        if log ~= nil then log("Watchdog: failed to encode graphs for save") end
        return false
    end
    local ok = pcall(function() PersistentDB:SetString(DB_KEY, text) end)
    return ok
end

return Store
