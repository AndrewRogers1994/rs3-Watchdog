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
--   { version, current = <name|nil>, graphs = { { name, graph, layout, view }, ... } }
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

local function buildEntry(name, graph, layout, view)
    return {
        name = name,
        graph = LibNodeGraph.Serialize(graph),
        layout = layoutToArray(layout),
        view = viewToTable(view),
    }
end

-- Inserts or replaces the named graph entry and marks it the current one. Mutates and
-- returns `doc`.
function Store.UpsertCurrent(doc, name, graph, layout, view)
    doc.graphs = doc.graphs or {}
    local entry = buildEntry(name, graph, layout, view)
    local i = indexOf(doc, name)
    if i ~= nil then
        doc.graphs[i] = entry
    else
        doc.graphs[#doc.graphs + 1] = entry
    end
    doc.current = name
    return doc
end

-- Rebuilds a live Graph + Layout + View from the named entry (defaults to doc.current).
-- Returns graph, layout, view, name — or nil if there's no such entry to restore.
function Store.Restore(doc, registry, name)
    name = name or doc.current
    if name == nil then return nil end
    local i = indexOf(doc, name)
    if i == nil then return nil end
    local entry = doc.graphs[i]
    local graph = LibNodeGraph.Deserialize(entry.graph, registry)
    return graph, layoutFromArray(entry.layout), entry.view, entry.name
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
