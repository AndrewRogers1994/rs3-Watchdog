-- Native ui.* layout is in interface units; Mouse.GetPosition() is unscaled.
-- Divide by InterfaceScale/100 or hit-tests drift down-right as scale rises.
-- Measure() also folds in OS display scaling: raw pixels / hook interface position.
-- Nil means the sample is unusable, so callers keep the last good ratio.

local IfaceScale = {}

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

---@param mx number
---@param my number
---@return number, number
function IfaceScale.ToInterface(mx, my)
    local f = IfaceScale.Factor()
    return mx / f, my / f
end

---@param rawX number
---@param rawY number
---@param expectedX number
---@param expectedY number
---@return number|nil
function IfaceScale.Measure(rawX, rawY, expectedX, expectedY)
    local candidates = {}
    if math.abs(expectedX) >= 32 then
        candidates[#candidates + 1] = rawX / expectedX
    end
    if math.abs(expectedY) >= 32 then
        candidates[#candidates + 1] = rawY / expectedY
    end
    if #candidates == 2 then
        local difference = math.abs(candidates[1] - candidates[2])
        local average = (candidates[1] + candidates[2]) / 2
        if difference <= average * 0.1 then return average end
    elseif #candidates == 1 and candidates[1] >= 0.5 and candidates[1] <= 4 then
        return candidates[1]
    end
    return nil
end

return IfaceScale
