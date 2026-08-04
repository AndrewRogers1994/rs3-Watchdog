-- iface_scale.lua — converts Mouse.GetPosition() into interface units.
--
-- Native ui.* layout/hit-testing already respects game.options.InterfaceScale; Canvas
-- draw and component .x/.y/.width are in interface units. Mouse.GetPosition() returns
-- denser (unscaled) coordinates, so manual hit-tests must divide by InterfaceScale/100
-- or clicks drift down-right as scale rises. See .memory/watchdog-coordinate-model.md.

local IfaceScale = {}

-- Current interface scale as a multiplier (1.0 = 100%). Missing/invalid → 1.
---@return number
function IfaceScale.Factor()
    local ok, setting = pcall(function()
        return game.options.InterfaceScale.setting
    end)
    if ok and type(setting) == "number" and setting > 0 then
        return setting / 100
    end
    return 1
end

-- Mouse (or any absolute) point → interface units for Canvas / toLocal math.
---@param mx number
---@param my number
---@return number, number
function IfaceScale.ToInterface(mx, my)
    local f = IfaceScale.Factor()
    return mx / f, my / f
end

return IfaceScale
