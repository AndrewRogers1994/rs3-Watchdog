-- Select Object MiniMenu capture while armed. No full-screen overlay: it would block MiniMenu hover.

local Util = require("util")

local SELECT_LABEL = "Select Object"
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
    }, ObjectMarkerCapture)
end

-- Client API objects are userdata, not table; tests fabricate tables. Both must pass.
local function isApiTable(v)
    return type(v) == "userdata" or type(v) == "table"
end

-- entries is reversed priority: last index is the top of the MiniMenu.
local function reversediter(t, i)
    i = i - 1
    if i ~= 0 then
        return i, t[i]
    end
end

local function reversed(t)
    return reversediter, t, #t + 1
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

---@param menu any
---@return any|nil
function ObjectMarkerCapture.FindLocEntry(menu)
    if not isApiTable(menu) then
        return nil
    end
    local entries = menu.entries
    if not isApiTable(entries) then
        return nil
    end
    for _, entry in reversed(entries) do
        if isApiTable(entry) and entry.locData ~= nil then
            return entry
        end
    end
    return nil
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
        name = config.name,
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
    self.armed = true
    self.nodeId, self.pinName, self.onCommit = nodeId, pinName, onCommit
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
    self.armed = false
    self.nodeId, self.pinName, self.onCommit = nil, nil, nil
end

---@param canvas any
function ObjectMarkerCapture:Draw(canvas)
    if canvas == nil or not self.armed then
        return
    end
    local CaptureBanner = require("ui/capture_banner")
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

-- MiniMenuReady repeats every Logic tick; Add each time. Add() name is overrideText, not verbText.
function ObjectMarkerCapture:_onReady(raw)
    if not self.armed then
        return
    end
    local menu = menuOf(raw)
    if menu == nil or menu.Add == nil then
        return
    end
    local locEntry = ObjectMarkerCapture.FindLocEntry(menu)
    if locEntry == nil then
        return
    end
    local capture = self
    pcall(function()
        menu:Add(SELECT_LABEL, function()
            capture:_onSelect(locEntry)
        end)
        menu:Swap(1, #menu.entries)
    end)
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
