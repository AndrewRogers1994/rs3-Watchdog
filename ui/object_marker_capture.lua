-- Capture on Examine of a LOC only. A full-screen overlay would block MiniMenu hover.

local Util = require("util")

-- MiniMenuActionVerbType.EXAMINE / MiniMenuEntryType.LOC as bare numeric literals (the client
-- enum globals are absent under the bare interpreter, same reason popup.lua inlines its sprite
-- ids). Kept as named locals so the predicate reads against the docs, not magic numbers.
local VERB_EXAMINE = 1 -- MiniMenuActionVerbType.EXAMINE
local ENTRY_LOC    = 3 -- MiniMenuEntryType.LOC

local SUBSCRIBE_NAME = "watchdog_object_marker_capture"

-- The `object` param a capture stores on the node (and the effect later re-projects). `coordGrid`
-- is a plain {x,z,level} table, not a client CoordGrid — level defaults to plane 0 (build-verify).
---@class Watchdog.ObjectMarker.Object
---@field name string|nil          # the LOC's display name (locData.config.name)
---@field coordGrid { x: integer|nil, z: integer|nil, level: integer } # the marked tile
---@field subjectHash integer|nil  # the selection's subject hash

local ObjectMarkerCapture = {}
ObjectMarkerCapture.__index = ObjectMarkerCapture

-- `eventSource` stands in for the client `Event` global (defaults to it); tests inject a fake.
function ObjectMarkerCapture.new(eventSource)
    return setmetatable({
        eventSource = eventSource or Event,
        armed = false,
        nodeId = nil,
        pinName = nil,
        onCommit = nil,
    }, ObjectMarkerCapture)
end

--- Pure predicate + extraction -------------------------------------------------------------

-- True for an indexable API value. Live client API objects (the MiniMenu payload, its entry,
-- locData/config) arrive as `userdata`, NOT `table`, so a bare `type(x) == "table"` check
-- silently rejects real data — the class of bug that made capture "not work" even after the
-- crash was fixed. The standalone test harness can only fabricate `table`s, so both must pass.
local function isApiTable(v)
    return type(v) == "userdata" or type(v) == "table"
end

-- Normalizes the MiniMenuEntrySelected callback arg to the MiniMenuEntry itself, unwrapping the
-- docs' `.entry` wrapper when the payload carries one (see the header BUILD-VERIFY note). Returns
-- nil for a non-indexable arg. This is the single seam both ShouldCapture and Extract read through,
-- so either real payload shape works without changing their bodies.
local function entryOf(raw)
    if not isApiTable(raw) then
        return nil
    end
    if isApiTable(raw.entry) then
        return raw.entry
    end
    return raw
end
ObjectMarkerCapture._entryOf = entryOf -- exposed for tests

-- True iff the selection is an Examine of a LOC — the only capture-worthy MiniMenu selection (#40).
-- Nil-safe, and shape-agnostic (accepts the wrapper or the bare entry via entryOf).
---@param raw any  # the MiniMenuEntrySelected callback arg (wrapper or bare entry)
---@return boolean
function ObjectMarkerCapture.ShouldCapture(raw)
    local entry = entryOf(raw)
    if entry == nil then
        return false
    end
    return entry.actionVerbType == VERB_EXAMINE and entry.actionEntryType == ENTRY_LOC
end

-- Shapes a captured LOC selection into the `object` param stored on the node:
-- `{ name = locData.config.name, coordGrid = { x, z, level }, subjectHash }`, or nil if it has no
-- LOC config to name (a malformed selection is dropped rather than stored half-formed). Coord
-- fields are read from the entry or nested under `locData`, and level falls back to plane 0 — see
-- the header BUILD-VERIFY note.
---@param raw any  # the MiniMenuEntrySelected callback arg (wrapper or bare entry)
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

--- Arm / commit / disarm -------------------------------------------------------------------

-- Arms select mode for one node/pin: the next Examine-of-a-LOC captures. `onCommit(object)` fires
-- once, on that capture, with the shaped param table. Re-arming just retargets (unsubscribe +
-- resubscribe), so a second "Select object" click before finishing never stacks subscriptions.
function ObjectMarkerCapture:Arm(nodeId, pinName, onCommit)
    self:_unsubscribe()
    self.armed = true
    self.nodeId, self.pinName, self.onCommit = nodeId, pinName, onCommit
    local capture = self
    local channel = self.eventSource and self.eventSource.MiniMenuEntrySelected
    -- LOAD-BEARING print() — do NOT remove (undocumented client quirk): a same-scope print() is
    -- required before touching an event-source channel + :Subscribe, or the client hard-crashes.
    -- See CLAUDE.md "Three ways to hard-crash the client" (#3) / memory client-event-param-crash.
    print()
    if channel ~= nil and channel.Subscribe ~= nil then
        if not self._subscribed then
            channel.Subscribe(SUBSCRIBE_NAME, function(entrySelected) capture:_onEntry(entrySelected) end)
        end
        self._subscribed = true
    end
end

function ObjectMarkerCapture:IsArmed()
    return self.armed
end

-- Aborts an armed capture with no commit (the editor's Esc / re-click path). Safe when idle.
function ObjectMarkerCapture:Cancel()
    self:_unsubscribe()
    self.armed = false
    self.nodeId, self.pinName, self.onCommit = nil, nil, nil
end

-- Capture Banner while armed (#71). Drawn on the always-on overlay Canvas from main.lua —
-- non-interactive (a full-screen overlay would block MiniMenu hover).
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
    local channel = self.eventSource and self.eventSource.MiniMenuEntrySelected
    if channel ~= nil and channel.Unsubscribe ~= nil then
        pcall(function()
            -- LOAD-BEARING print() — do NOT remove. Same client quirk as the Subscribe side: a
            -- same-scope print() is required before touching the channel + :Unsubscribe.
            -- See CLAUDE.md "Three ways to hard-crash the client" (#3) / memory client-event-param-crash.
            print()
            channel.Unsubscribe(SUBSCRIBE_NAME)
        end)
    end
    self._subscribed = false
end

-- The MiniMenuEntrySelected handler (`raw` is the callback arg — wrapper or bare entry, normalized
-- inside ShouldCapture/Extract): ignore anything but an Examine of a LOC (stay armed), and on a
-- match commit the extracted param once, then disarm (single-shot). A bad onCommit can't leave the
-- mode stuck armed — the disarm happens first, guarded.
function ObjectMarkerCapture:_onEntry(raw)
    if not self.armed then
        return
    end
    if not ObjectMarkerCapture.ShouldCapture(raw) then
        return
    end
    local object = ObjectMarkerCapture.Extract(raw)
    if object == nil then
        return -- a LOC with no config name: nothing usable to store, stay armed
    end
    local onCommit = self.onCommit
    self:Cancel()
    if onCommit ~= nil then
        Util.CallOrLog("object_marker_capture", "onCommit error", onCommit, object)
    end
end

return ObjectMarkerCapture
