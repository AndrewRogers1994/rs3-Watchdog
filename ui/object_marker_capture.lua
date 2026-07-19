-- object_marker_capture.lua — the global-modal "Select object" mode behind action.object_marker's
-- `object` Control (#40). Unlike Screen Marker's mouse-drag capture (ui/screen_marker_capture.lua),
-- the source here is an authoring-time *capture*, not a pin: arming subscribes to
-- Event.MiniMenuEntrySelected and captures on an **Examine of a LOC** — `actionVerbType == EXAMINE`
-- && `actionEntryType == LOC`. Examine is the only side-effect-free verb, so capturing on it never
-- perturbs the game; a capture *overlay* was ruled out because a full-screen layer would block the
-- game hover that populates the MiniMenu in the first place. Non-LOC / non-Examine entries are
-- ignored (the mode stays armed); a matching entry commits once and disarms (single-shot).
--
-- The event source is injectable (`ObjectMarkerCapture.new(eventSource)`, defaulting to the client
-- `Event` global) so the whole arm/commit/disarm flow runs under the standalone test harness
-- through tests/fake_event_source.lua, the same seam runtime.lua's dispatcher uses.
--
-- BUILD-VERIFY: the exact MiniMenuEntrySelected payload shape is unconfirmed against a live client.
-- The docs example reads `event.entry.actionEntryType` (the callback arg WRAPS the selected
-- MiniMenuEntry in an `.entry` field), while the scraped stub flattens everything onto MiniMenu, so
-- we can't tell statically whether the arg is the entry or a wrapper. Rather than guess, `_entryOf`
-- normalizes BOTH shapes: it unwraps `.entry` when present, else treats the arg as the entry. The
-- coord fields (`coordGridX`/`coordGridZ`) and the coord *level* are read defensively too — from the
-- entry, or nested under `locData`, with level falling back `coordGridLevel` -> `level` -> 0 — so a
-- differing real shape degrades gracefully instead of silently never capturing. Confirm the real
-- payload in-client and tighten this.

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

-- Normalizes the MiniMenuEntrySelected callback arg to the MiniMenuEntry itself, unwrapping the
-- docs' `.entry` wrapper when the payload carries one (see the header BUILD-VERIFY note). Returns
-- nil for a non-table arg. This is the single seam both ShouldCapture and Extract read through, so
-- either real payload shape works without changing their bodies.
local function entryOf(raw)
    if type(raw) ~= "table" then
        return nil
    end
    if type(raw.entry) == "table" then
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
    local locData = type(entry.locData) == "table" and entry.locData or {}
    local config = type(locData.config) == "table" and locData.config or nil
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
    if channel ~= nil and channel.Subscribe ~= nil then
        channel.Subscribe(SUBSCRIBE_NAME, function(entry) capture:_onEntry(entry) end)
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

function ObjectMarkerCapture:_unsubscribe()
    if not self._subscribed then
        return
    end
    local channel = self.eventSource and self.eventSource.MiniMenuEntrySelected
    if channel ~= nil and channel.Unsubscribe ~= nil then
        pcall(function() channel.Unsubscribe(SUBSCRIBE_NAME) end)
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
