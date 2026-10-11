local Theme    = require("src/ui/theme")
local Util     = require("src/util")
local Checkbox = require("src/ui/widgets/checkbox")

---@class ModePinControl
local Mode = {}

---@param modes { key: string, label: string, enabled: boolean, reason: string|nil }[]
---@return table
function Mode.new(modes)
    modes = modes or {}
    local M = {}

    ---@param key string
    ---@return { key: string, label: string, enabled: boolean, reason: string|nil }|nil
    local function descriptor(key)
        for _, m in ipairs(modes) do
            if m.key == key then return m end
        end
        return nil
    end

    ---@return number
    function M.ReservedHeight(_pin)
        return Theme.ModeBandH(#modes)
    end

    ---@param band { x: number, y: number, w: number, h: number }
    ---@return table[]
    function M.Layout(band)
        local rects = {}
        local y = band.y + Theme.MODE_TOP_GAP
        for _, m in ipairs(modes) do
            rects[#rects + 1] = {
                kind = "mode", axis = m.key, enabled = m.enabled,
                x = band.x, y = y, w = band.w, h = Theme.MODE_ROW_H,
            }
            y = y + Theme.MODE_ROW_H + Theme.MODE_ROW_GAP
        end
        return rects
    end

    ---@param ctrl table
    ---@return string
    function M.Display(ctrl)
        local m = descriptor(ctrl.axis)
        if m == nil then return tostring(ctrl.axis) end
        if not m.enabled and m.reason then
            return m.label .. " - " .. m.reason
        end
        return m.label
    end

    -- Flip from ctrl.value (default-resolved) so a default-ticked box first-click goes nil -> false.
    ---@param host ControlHost
    ---@param ctrl table
    function M.Press(host, ctrl)
        local m = descriptor(ctrl.axis)
        if m == nil or not m.enabled then return end
        local current = type(ctrl.value) == "table" and ctrl.value[ctrl.axis] == true
        host:Commit(Util.CopyWithField(ctrl.value, ctrl.axis, not current))
    end

    -- Enabled/checked logic lives in the checkbox Widget (#63).
    ---@param canvas any
    ---@param rect { x: number, y: number, w: number, h: number }
    ---@param ctrl table
    ---@param dctx DrawContext
    function M.Draw(canvas, rect, ctrl, dctx)
        Checkbox.Draw(canvas, rect, ctrl, dctx)
    end

    return M
end

return Mode
