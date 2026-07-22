-- coordgrid.lua — the coordgrid Pin Control (ADR-0005): the composite BAND that binds three number
-- fields + a grab button to a `coordgrid` Pin's stored `{x, z, level}` value. The ADR-0005
-- proof-of-concept — it exercises the most mechanics at once: composite band, self-owned layout,
-- multiple Widgets, per-axis read-modify-write, a host-mounted field, and a one-shot action. Reading
-- the live player position for the grab button is a plain client-API call (per ADR-0005 not a host
-- capability); everything Editor-side goes through the passed `host`.

local Theme       = require("ui/theme")
local Util        = require("util")
local NumberField = require("ui/widgets/number_field")
local Button      = require("ui/widgets/button")

---@class CoordGridPinControl
local CoordGrid = {}

-- The three editable axes, left-to-right, and the one-shot grab button composed over them.
local AXES = { "x", "z", "level" }
local grabButton = Button.new("Set to current position")

-- (a) The band height reserved below the Pin's own row for the fields + button. Constant here;
-- the `pin` argument mirrors the interface (a Pin Control MAY size its band from the Pin).
---@return number
function CoordGrid.ReservedHeight(_pin)
    return Theme.COORDGRID_BAND_H
end

-- (b) Lays the three axis fields (one row) and the grab button (the row below) out within the
-- reserved `band` rect (graph-space, relative to the node origin: {x, y, w, h}). Each sub-rect
-- carries the Widget role that Display/Press branch on: "field" (with its `axis`) or "action".
---@param band { x: number, y: number, w: number, h: number }
---@return table[]
function CoordGrid.Layout(band)
    local fieldY = band.y + Theme.COORDGRID_TOP_GAP
    local buttonY = fieldY + Theme.COORDGRID_FIELD_H + Theme.COORDGRID_MID_GAP
    local gap = Theme.COORDGRID_FIELD_GAP
    local fieldW = (band.w - gap * 2) / 3
    local rects = {}
    for i, axis in ipairs(AXES) do
        rects[#rects + 1] = {
            kind = "field", axis = axis,
            x = band.x + (i - 1) * (fieldW + gap), y = fieldY,
            w = fieldW, h = Theme.COORDGRID_FIELD_H,
        }
    end
    rects[#rects + 1] = {
        kind = "action",
        x = band.x, y = buttonY, w = band.w, h = Theme.COORDGRID_BUTTON_H,
    }
    return rects
end

-- (c) The text a sub-rect shows. A "field" shows just its own axis of the whole {x,z,level}
-- table (empty when unset, via the number Widget's codec); the "action" shows the button label.
-- `ctrl` is one sub-rect from Layout with the default-resolved current value in `ctrl.value`.
---@param ctrl table
---@return string
function CoordGrid.Display(ctrl)
    if ctrl.kind == "action" then return grabButton:Label() end
    local v = ctrl.value
    local axisVal = (type(v) == "table") and v[ctrl.axis] or nil
    return NumberField.Format(axisVal)
end

-- (e) Engine binding: read-modify-write one axis of the stored table, preserving the others.
-- An empty/whitespace/unparsable edit yields (current, false) — the empty-box guard, so a
-- mid-edit blank field can't clobber sibling axes (the number Widget's Parse returns nil there).
-- `quantity` is the field's own suffix-aware number, preferred over re-parsing `raw`.
---@param current table|nil
---@param axis string
---@param raw string
---@param quantity number|nil
---@return table|nil, boolean
function CoordGrid.CommitAxis(current, axis, raw, quantity)
    local value = NumberField.Parse(raw, quantity)
    if value == nil then return current, false end
    return Util.CopyWithField(current, axis, value), true
end

-- (d) Click behavior. A "field" mounts a transient numeric editor (through the host) that
-- commits its own axis on every content change; the "action" button grabs the live position.
---@param host ControlHost
---@param ctrl table
function CoordGrid.Press(host, ctrl)
    if ctrl.kind == "action" then
        CoordGrid.GrabCurrentPosition(host)
    elseif ctrl.kind == "field" then
        CoordGrid.EditAxis(host, ctrl)
    end
end

-- Mounts a numeric field over the clicked axis box, seeded from the value the box currently
-- shows (default-resolved, in ctrl.value), and commits that axis on every change. The commit
-- re-reads the stored table fresh from the host so concurrent edits to other axes are preserved.
---@param host ControlHost
---@param ctrl table
function CoordGrid.EditAxis(host, ctrl)
    local axisVal = (type(ctrl.value) == "table") and ctrl.value[ctrl.axis] or nil
    host:MountField(ctrl, {
        filter = "NUMERIC", maxLen = 128, initial = NumberField.Format(axisVal),
    }, function(raw, quantity)
        local value, changed = CoordGrid.CommitAxis(host:GetControl(), ctrl.axis, raw, quantity)
        if changed then host:Commit(value) end
    end)
end

-- Overwrites the whole {x,z,level} table in one shot from the live player position. Reading the
-- position is a plain client-API call (ADR-0005: not a host capability); only IsAvailable() is
-- guarded — a documented state check, not a client-global existence check (Player is present at
-- load; see the pcall-defensive-style convention). Silent no-op when the player is unavailable.
---@param host ControlHost
function CoordGrid.GrabCurrentPosition(host)
    if not Player.IsAvailable() then return end
    local entity = Player.GetEntity()
    host:Commit({
        x = entity.coordGrid.x, z = entity.coordGrid.z, level = entity.coordGrid.level,
    })
end

-- (f) Draw one sub-rect: a "field" is a plain number box (NumberField), the "action" an action
-- button (Button). Same kind discriminator Display/Press use, now internal to this composite —
-- the Node calls this once per sub-rect with an already-projected screen rect + draw context.
---@param canvas any
---@param rect { x: number, y: number, w: number, h: number }
---@param ctrl table
---@param dctx DrawContext
function CoordGrid.Draw(canvas, rect, ctrl, dctx)
    if ctrl.kind == "action" then
        Button.Draw(canvas, rect, ctrl, dctx)
    else
        NumberField.Draw(canvas, rect, ctrl, dctx)
    end
end

return CoordGrid
