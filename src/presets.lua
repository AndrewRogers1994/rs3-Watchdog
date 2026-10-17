-- Preset library. One plugin-wide document under the PersistentDB key `presets`
-- (no watchdog_ prefix). Not a Scope Bucket: Store.Save / SaveTo never write this key.
-- Instantiate inserts an Alert into a caller-supplied Bucket; it does not save that Bucket.

local Store = require("src/store")

local Presets = {}

local DB_KEY = "presets"
local DOC_VERSION = 1
local NAME_MAX = 80

---@class Watchdog.PresetVariable
---@field nodeId integer
---@field pinName string

---@class Watchdog.Preset
---@field id integer
---@field name string
---@field graph LibNodeGraph.SerializedGraph
---@field layout Watchdog.LayoutArray
---@field variables Watchdog.PresetVariable[]

---@class Watchdog.PresetDoc
---@field version integer
---@field presets Watchdog.Preset[]

---@return Watchdog.PresetDoc
function Presets.Empty()
    return { version = DOC_VERSION, presets = {} }
end

---@return LibNodeGraph.Codec|nil
local function codec()
    if LibNodeGraph ~= nil and LibNodeGraph.Json ~= nil then
        return LibNodeGraph.Json.Default
    end
    return nil
end

-- Reported, not overwritten. A bad document stays on disk until a version-1 read succeeds.
---@param message string
local function report(message)
    if type(log) == "function" then
        log("Watchdog: " .. message)
    end
end

-- A missing key is an empty version-1 library. Load does not create the key.
-- Unreadable JSON, or any version other than 1, is reported and left on disk.
---@return Watchdog.PresetDoc|nil doc
---@return string|nil err
function Presets.Load()
    if PersistentDB == nil then return Presets.Empty(), nil end
    local text
    local got, getErr = pcall(function() text = PersistentDB:GetString(DB_KEY) end)
    if not got then
        report("presets document unreadable, left on disk - " .. tostring(getErr))
        return nil, "Presets could not be read."
    end
    if type(text) ~= "string" or text == "" then
        return Presets.Empty(), nil
    end
    local c = codec()
    if c == nil then
        report("presets document unreadable, left on disk - no JSON codec")
        return nil, "Presets could not be read."
    end
    local ok, doc = pcall(function() return c.decode(text) end)
    if not ok or type(doc) ~= "table" then
        report("presets document unreadable, left on disk - " .. tostring(doc))
        return nil, "Presets could not be read."
    end
    if doc.version ~= DOC_VERSION or type(doc.presets) ~= "table" then
        report("presets document version " .. tostring(doc.version) .. " is not supported, left on disk")
        return nil, "Presets could not be read."
    end
    return doc, nil
end

---@param name string|nil
---@return string
local function trim(name)
    if type(name) ~= "string" then return "" end
    return (name:match("^%s*(.-)%s*$"))
end

-- Same on-disk shape an Alert entry uses: `{ id, x, y }` sorted by node id.
---@param layout Watchdog.Layout|nil
---@return Watchdog.LayoutArray
local function layoutToArray(layout)
    local arr = {}
    for id, pos in pairs(layout or {}) do
        arr[#arr + 1] = { id = id, x = pos.x or 0, y = pos.y or 0 }
    end
    table.sort(arr, function(a, b) return a.id < b.id end)
    return arr
end

-- One past the highest id still in the list, or 1 when the list is empty. No nextId.
---@param doc Watchdog.PresetDoc
---@return integer
local function mintId(doc)
    local maxId = 0
    for _, preset in ipairs(doc.presets or {}) do
        if type(preset.id) == "number" and preset.id > maxId then
            maxId = preset.id
        end
    end
    return maxId + 1
end

---@param doc Watchdog.PresetDoc
---@return boolean
local function write(doc)
    if PersistentDB == nil then return false end
    local c = codec()
    if c == nil then
        report("failed to encode presets document - no JSON codec")
        return false
    end
    local ok, text = pcall(function() return c.encode(doc) end)
    if not ok or type(text) ~= "string" then
        report("failed to encode presets document - " .. tostring(text))
        return false
    end
    return pcall(function() PersistentDB:SetString(DB_KEY, text) end)
end

-- Always adds. Never replaces. Duplicate names are kept. variables is empty until marking exists.
-- Refuses to write until a version-1 document can be read, and refuses a blank name.
---@param name string
---@param graph LibNodeGraph.Graph
---@param layout Watchdog.Layout|nil
---@return Watchdog.Preset|nil preset
---@return string|nil err
function Presets.Add(name, graph, layout)
    local trimmed = trim(name)
    if trimmed == "" or #trimmed > NAME_MAX then
        return nil, "Enter a preset name."
    end
    if graph == nil or LibNodeGraph == nil or LibNodeGraph.Serialize == nil then
        return nil, "Could not copy the graph."
    end
    local doc, err = Presets.Load()
    if doc == nil then
        return nil, err
    end
    local ok, serialized = pcall(LibNodeGraph.Serialize, graph)
    if not ok or type(serialized) ~= "table" then
        report("could not copy the alert graph - " .. tostring(serialized))
        return nil, "Could not copy the graph."
    end
    local preset = {
        id = mintId(doc),
        name = trimmed,
        graph = serialized,
        layout = layoutToArray(layout),
        variables = {},
    }
    doc.presets[#doc.presets + 1] = preset
    if not write(doc) then
        return nil, "Could not save the preset."
    end
    return preset, nil
end

-- Martin Pool's natural order, the case-insensitive form PHP calls strnatcasecmp.
-- Spaces are skipped the way that algorithm skips them. A leading zero run uses
-- left-to-right digit comparison; other numbers use the longer-run comparison.

local function isDigit(ch)
    return ch ~= nil and ch >= "0" and ch <= "9"
end

local function isSpace(ch)
    return ch == " " or ch == "\t" or ch == "\n" or ch == "\r" or ch == "\v" or ch == "\f"
end

local function upper(ch)
    local b = string.byte(ch)
    if b >= 97 and b <= 122 then
        return string.char(b - 32)
    end
    return ch
end

---@param a string
---@param b string
---@return integer  # -1 when a < b, 0 when equal, 1 when a > b
local function natcasecmp(a, b)
    a = type(a) == "string" and a or ""
    b = type(b) == "string" and b or ""
    local aLen, bLen = #a, #b
    if aLen == 0 or bLen == 0 then
        if aLen == bLen then return 0 end
        if aLen > bLen then return 1 end
        return -1
    end

    local ap, bp = 1, 1
    local function charAt(s, len, i)
        if i > len then return nil end
        return s:sub(i, i)
    end
    local ca = charAt(a, aLen, ap)
    local cb = charAt(b, bLen, bp)

    while ca == "0" and ap < aLen and isDigit(a:sub(ap + 1, ap + 1)) do
        ap = ap + 1
        ca = charAt(a, aLen, ap)
    end
    while cb == "0" and bp < bLen and isDigit(b:sub(bp + 1, bp + 1)) do
        bp = bp + 1
        cb = charAt(b, bLen, bp)
    end

    local function compareRight()
        local bias = 0
        while true do
            local aEnd = ap > aLen or not isDigit(charAt(a, aLen, ap))
            local bEnd = bp > bLen or not isDigit(charAt(b, bLen, bp))
            if aEnd and bEnd then return bias end
            if aEnd then return -1 end
            if bEnd then return 1 end
            local da = charAt(a, aLen, ap)
            local db = charAt(b, bLen, bp)
            if da < db then
                if bias == 0 then bias = -1 end
            elseif da > db then
                if bias == 0 then bias = 1 end
            end
            ap = ap + 1
            bp = bp + 1
        end
    end

    local function compareLeft()
        while true do
            local aEnd = ap > aLen or not isDigit(charAt(a, aLen, ap))
            local bEnd = bp > bLen or not isDigit(charAt(b, bLen, bp))
            if aEnd and bEnd then return 0 end
            if aEnd then return -1 end
            if bEnd then return 1 end
            local da = charAt(a, aLen, ap)
            local db = charAt(b, bLen, bp)
            if da < db then return -1 end
            if da > db then return 1 end
            ap = ap + 1
            bp = bp + 1
        end
    end

    while true do
        while ca ~= nil and isSpace(ca) do
            ap = ap + 1
            ca = charAt(a, aLen, ap)
        end
        while cb ~= nil and isSpace(cb) do
            bp = bp + 1
            cb = charAt(b, bLen, bp)
        end

        if isDigit(ca) and isDigit(cb) then
            local result
            if ca == "0" or cb == "0" then
                result = compareLeft()
            else
                result = compareRight()
            end
            if result ~= 0 then return result end
            if ap > aLen and bp > bLen then return 0 end
            if ap > aLen then return -1 end
            if bp > bLen then return 1 end
            ca = charAt(a, aLen, ap)
            cb = charAt(b, bLen, bp)
        end

        if ca == nil and cb == nil then return 0 end
        if ca == nil then return -1 end
        if cb == nil then return 1 end

        local ua, ub = upper(ca), upper(cb)
        if ua < ub then return -1 end
        if ua > ub then return 1 end

        ap = ap + 1
        bp = bp + 1
        if ap > aLen and bp > bLen then return 0 end
        if ap > aLen then return -1 end
        if bp > bLen then return 1 end
        ca = charAt(a, aLen, ap)
        cb = charAt(b, bLen, bp)
    end
end

-- Sorted copy. The stored array keeps insertion order; nothing persists a display order.
---@return Watchdog.Preset[]|nil presets
---@return string|nil err
function Presets.List()
    local doc, err = Presets.Load()
    if doc == nil then return nil, err end
    local copy = {}
    for i, preset in ipairs(doc.presets) do
        copy[i] = preset
    end
    table.sort(copy, function(left, right)
        local cmp = natcasecmp(left.name, right.name)
        if cmp ~= 0 then return cmp < 0 end
        return (left.id or 0) < (right.id or 0)
    end)
    return copy, nil
end

---@param arr Watchdog.LayoutArray|nil
---@return Watchdog.Layout
local function layoutFromArray(arr)
    local layout = {}
    for _, entry in ipairs(arr or {}) do
        if entry.id ~= nil then
            layout[entry.id] = { x = entry.x or 0, y = entry.y or 0 }
        end
    end
    return layout
end

-- Empty variables only. A Preset with marks is left for the Variable dialog; this does not
-- create an Alert and does not write the Bucket or the library. The new Alert is enabled
-- because a snapshot has no enabled flag to copy. Node ids stay the snapshot's ids.
---@param bucket Watchdog.Bucket
---@param presetId integer
---@param registry LibNodeGraph.Registry
---@return Watchdog.Entry|nil entry
---@return LibNodeGraph.Graph|nil graph
---@return Watchdog.Layout|nil layout
---@return string|nil err
function Presets.Instantiate(bucket, presetId, registry)
    if type(bucket) ~= "table" or registry == nil then
        return nil, nil, nil, "No scope to create the alert in."
    end
    local doc, err = Presets.Load()
    if doc == nil then
        return nil, nil, nil, err
    end
    local preset
    for _, candidate in ipairs(doc.presets) do
        if candidate.id == presetId then
            preset = candidate
            break
        end
    end
    if preset == nil then
        return nil, nil, nil, "Preset not found."
    end
    if type(preset.variables) == "table" and #preset.variables > 0 then
        return nil, nil, nil, "variables"
    end
    if LibNodeGraph == nil or LibNodeGraph.Deserialize == nil then
        return nil, nil, nil, "Could not copy the preset graph."
    end
    local ok, graph = pcall(function()
        return LibNodeGraph.Deserialize(preset.graph, registry, { onUnknown = "placeholder" })
    end)
    if not ok or graph == nil then
        report("could not instantiate preset " .. tostring(presetId) .. " - " .. tostring(graph))
        return nil, nil, nil, "Could not copy the preset graph."
    end
    local layout = layoutFromArray(preset.layout)
    local entry = Store.NewAlertEntry(Store.MintId(bucket), preset.name, graph, layout, true)
    if not Store.InsertEntry(bucket, entry) then
        return nil, nil, nil, "Could not create the alert."
    end
    return entry, graph, layout, nil
end

return Presets
