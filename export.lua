-- export.lua — Alert Manager copy-paste transfer (#94 / #79 / #84).
--
-- One envelope for every export shape: `{ schemaVersion, pluginVersion, entries }`, where
-- `entries` is a list of TreeEntries with `id` omitted. Every Encode path runs a uniform
-- 2,500-byte pre-flight guard. Import is append-only (never merge-by-name): decode → reject a
-- forward schemaVersion → mint ids → migrate → append at the active scope root.

local Store = require("store")

local Export = {}

-- Envelope schema version. The sole import gate: refuse only if the payload's schemaVersion is
-- greater than this build understands. Older payloads migrate forward.
Export.SCHEMA_VERSION = 1

-- Written on every export; never read, never branched on (#79).
Export.PLUGIN_VERSION = "0.1.0"

-- ui.InputField hard cap measured in #83. Guarded as UTF-8 *bytes* (#json) with no margin (#84).
Export.MAX_BYTES = 2500

---@class Watchdog.ExportEntry
---@field kind "alert"|"group"
---@field name string
---@field enabled boolean
---@field graph LibNodeGraph.SerializedGraph|nil
---@field layout Watchdog.LayoutArray|nil
---@field children Watchdog.ExportEntry[]|nil

---@class Watchdog.ExportEnvelope
---@field schemaVersion integer
---@field pluginVersion string
---@field entries Watchdog.ExportEntry[]

---@class Watchdog.ImportReport
---@field entryCount integer
---@field unknownCount integer
---@field unknownTypes string[]
---@field message string|nil

---@return LibNodeGraph.Codec|nil
local function codec()
    if LibNodeGraph ~= nil and LibNodeGraph.Json ~= nil then
        return LibNodeGraph.Json.Default
    end
    return nil
end

-- Deep-copies an Entry (or ExportEntry) subtree with TreeEntry `id` fields removed. Graph /
-- layout node ids are left untouched — they are graph-local and referenced by layout.
---@param entry Watchdog.Entry|Watchdog.ExportEntry
---@return Watchdog.ExportEntry
function Export.StripIds(entry)
    local copy = {
        kind = entry.kind,
        name = entry.name,
        enabled = entry.enabled ~= false,
        graph = entry.graph,
        layout = entry.layout,
    }
    if entry.children ~= nil then
        copy.children = {}
        for i, child in ipairs(entry.children) do
            copy.children[i] = Export.StripIds(child)
        end
    end
    return copy
end

---@param entries Watchdog.Entry[]|Watchdog.ExportEntry[]|nil
---@return Watchdog.ExportEnvelope
function Export.BuildEnvelope(entries)
    local out = {}
    for i, entry in ipairs(entries or {}) do
        out[i] = Export.StripIds(entry)
    end
    return {
        schemaVersion = Export.SCHEMA_VERSION,
        pluginVersion = Export.PLUGIN_VERSION,
        entries = out,
    }
end

---@param n integer
---@return string
local function oversizeMessage(n)
    return string.format(
        "Too large to export by copy-paste (%d of 2,500 characters). A file-based export is planned.",
        n)
end

-- Serialize `entries` into the export envelope. Returns ok, json on success; ok=false, err when
-- the codec is missing or the UTF-8 byte length exceeds MAX_BYTES (export nothing).
---@param entries Watchdog.Entry[]|Watchdog.ExportEntry[]|nil
---@return boolean ok
---@return string jsonOrErr
function Export.Encode(entries)
    local c = codec()
    if c == nil then
        return false, "JSON codec unavailable"
    end
    local envelope = Export.BuildEnvelope(entries)
    local ok, text = pcall(function() return c.encode(envelope) end)
    if not ok or type(text) ~= "string" then
        return false, "failed to encode export envelope"
    end
    if #text > Export.MAX_BYTES then
        return false, oversizeMessage(#text)
    end
    return true, text
end

---@param value any
---@return boolean
local function isEnvelope(value)
    if type(value) ~= "table" then return false end
    if type(value.schemaVersion) ~= "number" then return false end
    if type(value.pluginVersion) ~= "string" then return false end
    if type(value.entries) ~= "table" then return false end
    return true
end

-- Decode paste text into an envelope table. Rejects non-JSON and wrong-shape payloads before
-- any write. Does not yet gate on schemaVersion (Import does).
---@param text string
---@return boolean ok
---@return Watchdog.ExportEnvelope|string envelopeOrErr
function Export.Decode(text)
    if type(text) ~= "string" or text == "" then
        return false, "paste is empty"
    end
    local c = codec()
    if c == nil then
        return false, "JSON codec unavailable"
    end
    local ok, value = pcall(function() return c.decode(text) end)
    if not ok or not isEnvelope(value) then
        return false, "not a Watchdog export envelope"
    end
    ---@cast value Watchdog.ExportEnvelope
    return true, value
end

-- Mint ids for one ExportEntry without inserting. `used` is a set of already-claimed ids so
-- nested mints stay unique even before the tree is appended to `doc` (mint-before-migrate, #79).
---@param doc Watchdog.Bucket
---@param used table<integer, boolean>
---@param exportEntry Watchdog.ExportEntry
---@return Watchdog.Entry
local function materializeEntry(doc, used, exportEntry)
    local function nextId()
        local id = Store.MintId(doc)
        while used[id] do id = id + 1 end
        used[id] = true
        return id
    end
    local id = nextId()
    if exportEntry.kind == "group" then
        local children = {}
        for i, child in ipairs(exportEntry.children or {}) do
            children[i] = materializeEntry(doc, used, child)
        end
        return {
            id = id,
            kind = "group",
            name = type(exportEntry.name) == "string" and exportEntry.name or "Group",
            enabled = exportEntry.enabled ~= false,
            children = children,
        }
    end
    return {
        id = id,
        kind = "alert",
        name = type(exportEntry.name) == "string" and exportEntry.name or "Alert",
        enabled = exportEntry.enabled ~= false,
        graph = exportEntry.graph,
        layout = exportEntry.layout,
    }
end

-- Apply the same defaults the bucket loader does (schema migration seam). Today that's just
-- filling missing version / entries; real migrators land here later (#81).
---@param version integer|nil
---@param entries Watchdog.Entry[]
---@return Watchdog.Entry[]
local function migrateEntries(version, entries)
    -- schemaVersion on the envelope already gated; entry-level migration is a no-op until a
    -- real migrator exists. Keep the hook so Import's pipeline matches #79's order.
    local _ = version
    return entries
end

---@param entry Watchdog.Entry
---@param registry LibNodeGraph.Registry
---@param types table<string, boolean>
---@param counts integer[]  # counts[1] = total unknown nodes
local function collectUnknown(entry, registry, types, counts)
    if entry.kind == "alert" and entry.graph ~= nil and LibNodeGraph ~= nil then
        local ok, graph = pcall(function()
            return LibNodeGraph.Deserialize(entry.graph, registry, { onUnknown = "placeholder" })
        end)
        if ok and graph ~= nil then
            for _, node in pairs(graph.nodes or {}) do
                if node.typeKey == LibNodeGraph.UNKNOWN_TYPE and node.unknown ~= nil then
                    counts[1] = counts[1] + 1
                    local t = node.unknown.type
                    if type(t) == "string" then types[t] = true end
                end
            end
        end
    end
    for _, child in ipairs(entry.children or {}) do
        collectUnknown(child, registry, types, counts)
    end
end

---@param entryCount integer
---@param unknownCount integer
---@param unknownTypes string[]
---@return string|nil
local function formatReportMessage(entryCount, unknownCount, unknownTypes)
    if unknownCount <= 0 then
        return string.format("Imported %d entr%s.", entryCount, entryCount == 1 and "y" or "ies")
    end
    local listed = table.concat(unknownTypes, ", ")
    return string.format(
        "Imported %d entr%s. %d unrecognized node type%s (%s) will not run those steps.",
        entryCount,
        entryCount == 1 and "y" or "ies",
        unknownCount,
        unknownCount == 1 and "" or "s",
        listed)
end

-- Full import pipeline. Mutates `doc` only after every gate passes (atomic). Options:
-- `registry` — when provided, unknown node types are counted for the non-blocking report.
---@param doc Watchdog.Bucket
---@param text string
---@param opts { registry: LibNodeGraph.Registry|nil }|nil
---@return boolean ok
---@return Watchdog.ImportReport|string reportOrErr
function Export.Import(doc, text, opts)
    local ok, envelopeOrErr = Export.Decode(text)
    if not ok then
        return false, tostring(envelopeOrErr)
    end
    ---@cast envelopeOrErr Watchdog.ExportEnvelope
    local envelope = envelopeOrErr

    if envelope.schemaVersion > Export.SCHEMA_VERSION then
        return false, "exported from a newer version of Watchdog than you have"
    end

    local used = {}
    -- Claim every id already in the destination so mints never collide.
    local function claim(entries)
        for _, e in ipairs(entries or {}) do
            if type(e.id) == "number" then used[e.id] = true end
            if e.children ~= nil then claim(e.children) end
        end
    end
    claim(doc.entries)

    local minted = {}
    for i, exportEntry in ipairs(envelope.entries or {}) do
        if type(exportEntry) ~= "table" or (exportEntry.kind ~= "alert" and exportEntry.kind ~= "group") then
            return false, "envelope entry " .. tostring(i) .. " is not a valid Entry"
        end
        minted[i] = materializeEntry(doc, used, exportEntry)
    end

    minted = migrateEntries(envelope.schemaVersion, minted)

    -- Append only after materialize+migrate succeed — import is atomic.
    for _, entry in ipairs(minted) do
        Store.InsertEntry(doc, entry, nil)
    end

    local unknownTypesSet = {}
    local counts = { 0 }
    local registry = opts and opts.registry
    if registry ~= nil then
        for _, entry in ipairs(minted) do
            collectUnknown(entry, registry, unknownTypesSet, counts)
        end
    end
    local unknownTypes = {}
    for t in pairs(unknownTypesSet) do
        unknownTypes[#unknownTypes + 1] = t
    end
    table.sort(unknownTypes)

    local report = {
        entryCount = #minted,
        unknownCount = counts[1],
        unknownTypes = unknownTypes,
        message = formatReportMessage(#minted, counts[1], unknownTypes),
    }
    return true, report
end

return Export
