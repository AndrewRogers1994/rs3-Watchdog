-- mode.lua — the mode multi-select Pin Control (ADR-0005 / #61): the per-Type-Tag module for a
-- composite BAND of one checkbox row per mode (object_marker's #40 Tile/Hull/Outline/Clickbox).
-- Only ENABLED rows toggle; disabled rows are the unavailable-node idiom — shown but inert, with a
-- "needs render API" reason appended to the label. The stored Control is a `{ [key] = boolean }`
-- table; a click flips one key read-modify-write so the other rows survive.
--
-- Built from the tag's `modes` list ({ { key, label, enabled, reason? }, ... }), so a new mode
-- multi-select is one Controls.Register(tag, { widget = "mode", modes = ... }) call with no Pin
-- Control code of its own (controls.lua wires this factory in automatically). Like coordgrid/matcher
-- it is a composite band (not Inline); each Layout sub-rect bakes its row's `enabled` flag so the
-- Node's checkbox draw needs no descriptor lookup. It reaches the Editor only through the passed
-- `host` (read + commit the stored table); its test adapter is the fake host in
-- tests/test_mode_control.lua, driving the toggle through press->commit headless.

local Theme = require("ui/theme")

---@class ModePinControl
local Mode = {}

-- Builds a mode Pin Control over a modes list. Returns a plain module table (dot-functions, like
-- coordgrid) with the list captured in the closures.
---@param modes { key: string, label: string, enabled: boolean, reason: string|nil }[]
---@return table
function Mode.new(modes)
    modes = modes or {}
    local M = {}

    -- The mode descriptor for a row's key, or nil. Drives the label/enabled/reason projection.
    local function descriptor(key)
        for _, m in ipairs(modes) do
            if m.key == key then return m end
        end
        return nil
    end

    -- (a) The band height reserved below the pin row for the checkbox rows — one place, keyed off
    -- the row count so an added/removed mode resizes the band automatically.
    ---@return number
    function M.ReservedHeight(_pin)
        return Theme.ModeBandH(#modes)
    end

    -- (b) One "mode" checkbox row per mode, stacked top-to-bottom within the reserved `band`
    -- (graph-space, relative to the node origin). Each row bakes its `enabled` flag so the Node's
    -- checkbox draw can dim/gate it without re-resolving the descriptor.
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

    -- (c) A row's label. Enabled rows show the plain label; a disabled row appends its reason
    -- (" — needs render API"), the unavailable-node idiom the Node draws dimmed. `ctrl` is one
    -- sub-rect from Layout, its axis naming the row.
    ---@param ctrl table
    ---@return string
    function M.Display(ctrl)
        local m = descriptor(ctrl.axis)
        if m == nil then return tostring(ctrl.axis) end
        if not m.enabled and m.reason then
            return m.label .. " — " .. m.reason
        end
        return m.label
    end

    -- (d) Click: flip one enabled row's boolean, read-modify-write against the whole stored table so
    -- the sibling rows survive. A disabled row is inert (commits nothing). The flip is based on
    -- ctrl.value (the default-resolved value the row actually shows) so the first click on a box that
    -- reads ticked only because of the pin default clears it (nil -> false) rather than re-ticking.
    ---@param host ControlHost
    ---@param ctrl table
    function M.Press(host, ctrl)
        local m = descriptor(ctrl.axis)
        if m == nil or not m.enabled then return end
        local updated = {}
        if type(ctrl.value) == "table" then
            for k, v in pairs(ctrl.value) do updated[k] = v end
        end
        updated[ctrl.axis] = not (updated[ctrl.axis] == true)
        host:Commit(updated)
    end

    return M
end

return Mode
