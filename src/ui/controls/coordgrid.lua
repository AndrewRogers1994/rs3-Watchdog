local Theme       = require("src/ui/theme")
local Util        = require("src/util")
local NumberField = require("src/ui/widgets/number_field")
local Button      = require("src/ui/widgets/button")
local Box         = require("src/ui/widgets/box")

---@class CoordGridPinControl
local CoordGrid = {}

-- Left to right: Level, X, Y. Y is the stored `z`. The table stays { x, z, level }.
local AXES = { "level", "x", "z" }
local CAPTION = { level = "Level", x = "X", z = "Y" }
local grabButton = Button.new("Set to current position")

---@return number
function CoordGrid.ReservedHeight(_pin)
    return Theme.COORDGRID_BAND_H
end

---@param band { x: number, y: number, w: number, h: number }
---@return table[]
function CoordGrid.Layout(band)
    local fieldY = band.y + Theme.COORDGRID_TOP_GAP + Theme.COORDGRID_CAPTION_H
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

---@param ctrl table
---@return string
function CoordGrid.Display(ctrl)
    if ctrl.kind == "action" then return grabButton:Label() end
    local v = ctrl.value
    local axisVal = (type(v) == "table") and v[ctrl.axis] or nil
    return NumberField.Format(axisVal)
end

-- Empty/unparsable edit: (current, false) so a mid-edit blank cannot clobber sibling axes.
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

---@param host ControlHost
---@param ctrl table
function CoordGrid.Press(host, ctrl)
    if ctrl.kind == "action" then
        CoordGrid.GrabCurrentPosition(host)
    elseif ctrl.kind == "field" then
        CoordGrid.EditAxis(host, ctrl)
    end
end

-- Re-read stored table from the host so concurrent edits to other axes are preserved.
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

-- ADR-0005: Player position is a client-API call, not a host capability. Guard IsAvailable()
-- only (state check, not a global-existence check; Player is present at load).
---@param host ControlHost
function CoordGrid.GrabCurrentPosition(host)
    if not Player.IsAvailable() then return end
    local entity = Player.GetEntity()
    host:Commit({
        x = entity.coordGrid.x, z = entity.coordGrid.z, level = entity.coordGrid.level,
    })
end

---@param canvas any
---@param rect { x: number, y: number, w: number, h: number }
---@param ctrl table
---@param dctx DrawContext
function CoordGrid.Draw(canvas, rect, ctrl, dctx)
    if ctrl.kind == "action" then
        Button.Draw(canvas, rect, ctrl, dctx)
        return
    end
    local caption = CAPTION[ctrl.axis]
    if caption ~= nil and dctx.font ~= nil then
        local scale = dctx.scale
        local tw = Theme.TextWidth(11 * dctx.zoom, caption) or (#caption * scale(7))
        canvas:AddText(rect.x, rect.y - scale(Theme.COORDGRID_CAPTION_H), tw, 0, caption,
            Box.TextData(dctx.font, Theme.Vec4(Theme.COL_PIN_LABEL)))
    end
    NumberField.Draw(canvas, rect, ctrl, dctx)
end

return CoordGrid
