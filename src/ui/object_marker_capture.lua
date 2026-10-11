-- Select Object MiniMenu capture while armed. No full-screen overlay: it would block MiniMenu hover.

local Util = require("src/util")

local SELECT_PREFIX = "Select "
local SUBSCRIBE_NAME = "watchdog_object_marker_capture"

-- Stored on the node; coordGrid is a plain {x,z,level} table (level defaults to 0).
---@class Watchdog.ObjectMarker.Object
---@field name string|nil
---@field coordGrid { x: integer|nil, z: integer|nil, level: integer }
---@field subjectHash integer|nil

local ObjectMarkerCapture = {}
ObjectMarkerCapture.__index = ObjectMarkerCapture

function ObjectMarkerCapture.new(eventSource)
    return setmetatable({
        eventSource = eventSource or Event,
        armed = false,
        nodeId = nil,
        pinName = nil,
        onCommit = nil,
        -- Optional: fun(armed: boolean). Fires only on true transitions (Arm from idle,
        -- Cancel/select from armed). The Watchdog shell uses this to tuck itself so MiniMenu
        -- hover isn't covered by the editor window.
        onArmedChange = nil,
    }, ObjectMarkerCapture)
end

function ObjectMarkerCapture:_setArmed(armed)
    armed = not not armed
    if self.armed == armed then
        return
    end
    self.armed = armed
    if self.onArmedChange ~= nil then
        Util.CallOrLog("object_marker_capture", "onArmedChange error", self.onArmedChange, armed)
    end
end

-- Client API objects are userdata, not table; tests fabricate tables. Both must pass.
local function isApiTable(v)
    return type(v) == "userdata" or type(v) == "table"
end

local function menuOf(raw)
    if not isApiTable(raw) then
        return nil
    end
    if isApiTable(raw.miniMenu) then
        return raw.miniMenu
    end
    return raw
end

local function entryOf(raw)
    if not isApiTable(raw) then
        return nil
    end
    if isApiTable(raw.entry) then
        return raw.entry
    end
    return raw
end

local function menuLen(menu)
    local n = 0
    if type(menu.entryCount) == "number" then
        n = menu.entryCount
    end
    local entries = menu.entries
    if isApiTable(entries) then
        local len = #entries
        if len > n then
            n = len
        end
    end
    return n
end

-- MiniMenu:Add appends; docs only guarantee Swap(1, last) to reach the top. Bubble otherwise.
local function promoteLastTo(menu, target)
    local last = menuLen(menu)
    if last < 1 or target < 1 then
        return
    end
    if target == 1 then
        menu:Swap(1, last)
        return
    end
    local i = last
    while i > target do
        menu:Swap(i - 1, i)
        i = i - 1
    end
end

-- Same Loc across Process/Examine: LocType.id + tile. No id → subjectHash (tests / odd entries).
---@param entry any
---@return string|nil
function ObjectMarkerCapture.LocKey(entry)
    if not isApiTable(entry) then
        return nil
    end
    local locData = isApiTable(entry.locData) and entry.locData or {}
    local config = isApiTable(locData.config) and locData.config or {}
    local function coord(field)
        if entry[field] ~= nil then return entry[field] end
        return locData[field]
    end
    local x, z = coord("coordGridX"), coord("coordGridZ")
    local level = coord("coordGridLevel") or entry.level or 0
    if config.id ~= nil then
        return table.concat({ "id", tostring(config.id), tostring(x), tostring(z), tostring(level) }, ":")
    end
    if entry.subjectHash ~= nil then
        return "hash:" .. tostring(entry.subjectHash)
    end
    return nil
end

---@param menu any
---@return any[]
function ObjectMarkerCapture.FindLocEntries(menu)
    local out = {}
    if not isApiTable(menu) then
        return out
    end
    local entries = menu.entries
    if not isApiTable(entries) then
        return out
    end
    local n = menuLen(menu)
    if n < 1 then
        n = #entries
    end
    -- Walk top-first (last index is MiniMenu top); keep the first time we see each Loc.
    local topFirst = {}
    local seen = {}
    for i = n, 1, -1 do
        local entry = entries[i]
        if isApiTable(entry) and entry.locData ~= nil then
            local key = ObjectMarkerCapture.LocKey(entry)
            if key == nil or not seen[key] then
                if key ~= nil then
                    seen[key] = true
                end
                topFirst[#topFirst + 1] = entry
            end
        end
    end
    for i = #topFirst, 1, -1 do
        out[#out + 1] = topFirst[i]
    end
    return out
end

-- Last loc in menu.entries is MiniMenu top (reversed priority).
---@param menu any
---@return any|nil
function ObjectMarkerCapture.FindLocEntry(menu)
    local locs = ObjectMarkerCapture.FindLocEntries(menu)
    return locs[#locs]
end

local function nonempty(s)
    return type(s) == "string" and s ~= "" and s or nil
end

-- MiniMenu subjectText keeps <col> tags so "Select "..label colors the Loc name.
---@param entry any
---@return string|nil
function ObjectMarkerCapture.LocLabel(entry)
    if not isApiTable(entry) then
        return nil
    end
    local locData = isApiTable(entry.locData) and entry.locData or {}
    local config = isApiTable(locData.config) and locData.config or {}
    return nonempty(entry.subjectText)
        or nonempty(config.name)
        or nonempty(config.configName)
end

---@param raw any
---@return Watchdog.ObjectMarker.Object|nil
function ObjectMarkerCapture.Extract(raw)
    local entry = entryOf(raw)
    if entry == nil then
        return nil
    end
    local locData = isApiTable(entry.locData) and entry.locData or {}
    local config = isApiTable(locData.config) and locData.config or nil
    if config == nil then
        return nil
    end
    local function coord(field)
        if entry[field] ~= nil then return entry[field] end
        return locData[field]
    end
    return {
        name = ObjectMarkerCapture.LocLabel(entry),
        coordGrid = {
            x = coord("coordGridX"),
            z = coord("coordGridZ"),
            level = coord("coordGridLevel") or entry.level or 0,
        },
        subjectHash = entry.subjectHash,
    }
end

function ObjectMarkerCapture:Arm(nodeId, pinName, onCommit)
    self:_unsubscribe()
    self.nodeId, self.pinName, self.onCommit = nodeId, pinName, onCommit
    self:_setArmed(true)
    local capture = self
    local channel = self.eventSource and self.eventSource.MiniMenuReady
    -- LOAD-BEARING print() - do NOT remove (undocumented client quirk): a same-scope print() is
    -- required before touching an event-source channel + :Subscribe, or the client hard-crashes.
    -- See CLAUDE.md "Three ways to hard-crash the client" (#3) / memory client-event-param-crash.
    print()
    if channel ~= nil and channel.Subscribe ~= nil then
        if not self._subscribed then
            channel.Subscribe(SUBSCRIBE_NAME, function(ready) capture:_onReady(ready) end)
        end
        self._subscribed = true
    end
end

function ObjectMarkerCapture:IsArmed()
    return self.armed
end

function ObjectMarkerCapture:Cancel()
    self:_unsubscribe()
    self.nodeId, self.pinName, self.onCommit = nil, nil, nil
    self:_setArmed(false)
end

---@param canvas any
function ObjectMarkerCapture:Draw(canvas)
    if canvas == nil or not self.armed then
        return
    end
    local CaptureBanner = require("src/ui/capture_banner")
    local w = 1920
    pcall(function()
        if canvas.width and canvas.width > 0 then w = canvas.width end
    end)
    CaptureBanner.Draw(canvas, CaptureBanner.OBJECT_TEXT, w)
end

function ObjectMarkerCapture:_unsubscribe()
    if not self._subscribed then
        return
    end
    local channel = self.eventSource and self.eventSource.MiniMenuReady
    if channel ~= nil and channel.Unsubscribe ~= nil then
        pcall(function()
            -- LOAD-BEARING print() - do NOT remove. Same client quirk as the Subscribe side: a
            -- same-scope print() is required before touching the channel + :Unsubscribe.
            -- See CLAUDE.md "Three ways to hard-crash the client" (#3) / memory client-event-param-crash.
            print()
            channel.Unsubscribe(SUBSCRIBE_NAME)
        end)
    end
    self._subscribed = false
end

-- MiniMenuReady repeats every Logic tick
function ObjectMarkerCapture:_onReady(raw)
    if not self.armed then
        return
    end
    local menu = menuOf(raw)
    if menu == nil or menu.Add == nil then
        return
    end
    local locs = ObjectMarkerCapture.FindLocEntries(menu)
    if #locs == 0 then
        return
    end
    local capture = self
    for rank = #locs, 1, -1 do
        local locEntry = locs[rank]
        local label = SELECT_PREFIX .. (ObjectMarkerCapture.LocLabel(locEntry) or "Object")
        local pinned = locEntry
        menu:Add(label, function()
            capture:_onSelect(pinned)
        end)
        -- Only have to move the first one, subsequent adds will add after this one
        if rank == #locs then
            for i = 1, menu.entryCount - 1 do
                menu:Swap(i, i + 1)
            end
        end
    end
end

function ObjectMarkerCapture:_onSelect(locEntry)
    if not self.armed then
        return
    end
    local object = ObjectMarkerCapture.Extract(locEntry)
    if object == nil then
        return
    end
    local onCommit = self.onCommit
    self:Cancel()
    if onCommit ~= nil then
        Util.CallOrLog("object_marker_capture", "onCommit error", onCommit, object)
    end
end

return ObjectMarkerCapture
