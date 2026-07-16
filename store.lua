-- store.lua — Watchdog's graph persistence backend: saves and restores graphs.
--
-- LibNodeGraph deliberately never touches persistentdb (ADR-0007): the library only
-- produces/consumes tables + strings, and the *consumer* owns actual persistence. This
-- module is that consumer half for Watchdog. It bundles the three things a saved graph
-- needs — the engine's serialized structure (nodes + Connections), plus the two pieces
-- of UI-only state the engine has no concept of: the Layout (nodeId -> Graph-space
-- position) and the View (pan/zoom) — into one document, and stores it under a single
-- persistentdb key as one JSON string (SetString/GetString), the flat-scalar shape
-- persistentdb is happiest with.
--
-- Multi-graph from day one: the document holds an *array* of named graph entries plus a
-- `current` pointer, even though the editor only shows one today. Adding the "new graph /
-- switch graph" UI later is purely additive — the backend already keys everything by name.
--
--   { version, current = <name|nil>, graphs = { { name, graph, layout, view, enabled }, ... } }
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

-- The JSON codec and the graph (de)serializers live in the LibNodeGraph plugin, injected
-- as a global (same as main.lua reaches LibNodeGraph.NewGraph). Fetched lazily so this
-- module can load even if the lib isn't present yet.
local function codec()
    if LibNodeGraph ~= nil and LibNodeGraph.Json ~= nil then
        return LibNodeGraph.Json.Default
    end
    return nil
end

--- Layout / View <-> JSON-safe shapes ----------------------------------------------------

-- nodeId-keyed map -> sorted array of { id, x, y } (JSON needs string keys, so the id can't
-- live as a table key). Sorted by id purely so saved files diff cleanly.
local function layoutToArray(layout)
    local arr = {}
    for id, pos in pairs(layout or {}) do
        arr[#arr + 1] = { id = id, x = pos.x, y = pos.y }
    end
    table.sort(arr, function(a, b) return a.id < b.id end)
    return arr
end

local function layoutFromArray(arr)
    local layout = {}
    for _, e in ipairs(arr or {}) do
        if e.id ~= nil then
            layout[e.id] = { x = e.x or 0, y = e.y or 0 }
        end
    end
    return layout
end

local function viewToTable(view)
    if view == nil then return nil end
    return { panX = view.panX or 0, panY = view.panY or 0, zoom = view.zoom or 1 }
end

--- Document construction ------------------------------------------------------------------

function Store.Empty()
    return { version = DOC_VERSION, current = nil, graphs = {} }
end

local function indexOf(doc, name)
    for i, entry in ipairs(doc.graphs or {}) do
        if entry.name == name then return i end
    end
    return nil
end

-- Normalizes any stored/passed enabled value to a strict boolean, treating nil (a pre-#27
-- entry, or an omitted argument already resolved by the caller) as enabled.
local function normalizeEnabled(enabled)
    return enabled ~= false
end

local function buildEntry(name, graph, layout, view, enabled)
    return {
        name = name,
        graph = LibNodeGraph.Serialize(graph),
        layout = layoutToArray(layout),
        view = viewToTable(view),
        enabled = normalizeEnabled(enabled),
    }
end

-- Inserts or replaces the named graph entry and marks it the current one. Mutates and
-- returns `doc`. `enabled` is optional: when omitted (nil) an existing entry keeps its current
-- flag — so the editor autosave loop, which re-upserts the current graph without knowing its
-- enabled state, never silently re-arms an alert the user disabled — and a brand-new entry
-- defaults to enabled.
function Store.UpsertCurrent(doc, name, graph, layout, view, enabled)
    doc.graphs = doc.graphs or {}
    local i = indexOf(doc, name)
    if enabled == nil then
        -- Preserve the existing flag (may be false — can't use `x and y or z` here), default
        -- true for a new entry.
        if i ~= nil then enabled = doc.graphs[i].enabled else enabled = true end
    end
    local entry = buildEntry(name, graph, layout, view, enabled)
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
function Store.SetEnabled(doc, name, enabled)
    local i = indexOf(doc, name)
    if i == nil then return false end
    doc.graphs[i].enabled = normalizeEnabled(enabled)
    return true
end

-- Rebuilds a live Graph + Layout + View from the named entry (defaults to doc.current).
-- Returns graph, layout, view, name, enabled — or nil if there's no such entry to restore.
function Store.Restore(doc, registry, name)
    name = name or doc.current
    if name == nil then return nil end
    local i = indexOf(doc, name)
    if i == nil then return nil end
    local entry = doc.graphs[i]
    local graph = LibNodeGraph.Deserialize(entry.graph, registry)
    return graph, layoutFromArray(entry.layout), entry.view, entry.name, normalizeEnabled(entry.enabled)
end

-- Rebuilds *every* saved graph into a live instance (#27: all saved graphs instantiate live at
-- startup, not just the current one, so triggers in every enabled alert fire). Returns an array
-- of { name, graph, layout, view, enabled } in stored order. An entry that fails to deserialize
-- (a node type no longer registered, a corrupt structure) is logged and skipped rather than
-- aborting the whole set, so one bad alert can't take the others down.
function Store.RestoreAll(doc, registry)
    local restored = {}
    for _, entry in ipairs((doc or {}).graphs or {}) do
        local ok, graph = pcall(function() return LibNodeGraph.Deserialize(entry.graph, registry) end)
        if ok and graph ~= nil then
            restored[#restored + 1] = {
                name = entry.name,
                graph = graph,
                layout = layoutFromArray(entry.layout),
                view = entry.view,
                enabled = normalizeEnabled(entry.enabled),
            }
        elseif log ~= nil then
            log("Watchdog: skipping unrestorable graph '" .. tostring(entry.name) .. "' — " .. tostring(graph))
        end
    end
    return restored
end

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
function Store.Encode(doc)
    local c = codec()
    if c == nil then return nil end
    local ok, text = pcall(function() return c.encode(doc) end)
    if ok then return text end
    return nil
end

-- Reads the saved document, or an empty one if there's nothing saved / it can't be parsed.
-- Never returns nil, so callers always get a document to upsert into.
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
