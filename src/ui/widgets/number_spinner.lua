local NumberField = require("src/ui/widgets/number_field")

--- Sound-id spin box. The open Sound Effect control keeps a numeric field and
--- puts up/down arrows in a column on its right. Split is that geometry; Step
--- is one click. The arrows are native sprites because the open control sits
--- above the editor's capture overlay — a canvas hit would close the editor.
---@class NumberSpinner
local NumberSpinner = {}

-- Scrollbar arrows are drawn at 16px. Two stacked set the open row's height.
NumberSpinner.COLUMN_W = 16
NumberSpinner.ARROW_H = 16
-- Editor logic ticks are ~20ms. 25 ticks is about 500ms between hold repeats.
NumberSpinner.REPEAT_TICKS = 25

---@return number
function NumberSpinner.OpenHeight()
    return NumberSpinner.ARROW_H * 2
end

---@param x number
---@param y number
---@param w number
---@param h number
---@return { x: number, y: number, w: number, h: number } field
---@return { x: number, y: number, w: number, h: number } up
---@return { x: number, y: number, w: number, h: number } down
function NumberSpinner.Split(x, y, w, h)
    local col = math.min(NumberSpinner.COLUMN_W, math.max(0, w - 1))
    local fieldW = math.max(1, w - col)
    local upH = math.floor(h / 2)
    local downH = h - upH
    return
        { x = x, y = y, w = fieldW, h = h },
        { x = x + fieldW, y = y, w = col, h = upH },
        { x = x + fieldW, y = y + upH, w = col, h = downH }
end

--- One arrow click. An empty or unparsable field starts from 0, then the
--- delta applies. The result never goes below 0. Fractional input is floored
--- first so the stored sound id stays an integer.
---@param raw string|nil
---@param quantity number|nil
---@param delta number
---@return number
function NumberSpinner.Step(raw, quantity, delta)
    local parsed = NumberField.Parse(raw, quantity)
    local base = 0
    if type(parsed) == "number" then base = math.floor(parsed) end
    local nextValue = base + delta
    if nextValue < 0 then nextValue = 0 end
    return nextValue
end

--- The stepped id, or nil when the click would not change the parsed value
--- (holding Down on 0). Callers skip the commit in that case.
---@param raw string|nil
---@param quantity number|nil
---@param delta number
---@return number|nil
function NumberSpinner.Apply(raw, quantity, delta)
    local nextValue = NumberSpinner.Step(raw, quantity, delta)
    if NumberField.Parse(raw, quantity) == nextValue then return nil end
    return nextValue
end

--- True when a held arrow may step again. The first event has no `last`.
---@param now number
---@param last number|nil
---@return boolean
function NumberSpinner.Due(now, last)
    if last == nil then return true end
    return now - last >= NumberSpinner.REPEAT_TICKS
end

--- One arrow event. A press always steps, so a quick click is exactly one.
--- Repeats while held wait REPEAT_TICKS. A repeat in the same tick as release
--- does not, so the burst at the end of a click cannot add another step.
--- `event` is "press", "repeat", or "release".
---@param state { held: boolean, last: number|nil, closed: boolean, closedAt: number|nil }|nil
---@param event "press"|"repeat"|"release"
---@param now number
---@return boolean step
---@return { held: boolean, last: number|nil, closed: boolean, closedAt: number|nil } state
function NumberSpinner.Gate(state, event, now)
    local held = state ~= nil and state.held or false
    local last = state ~= nil and state.last or nil
    local closed = state ~= nil and state.closed or false
    local closedAt = state ~= nil and state.closedAt or nil
    if event == "release" then
        return false, { held = false, last = last, closed = true, closedAt = now }
    end
    if event == "press" then
        return true, { held = true, last = now, closed = false }
    end
    if closed then
        if closedAt == now then
            return false, { held = false, last = last, closed = true, closedAt = closedAt }
        end
        return true, { held = true, last = now, closed = false }
    end
    if not held then
        return true, { held = true, last = now, closed = false }
    end
    if not NumberSpinner.Due(now, last) then
        return false, { held = true, last = last, closed = false }
    end
    return true, { held = true, last = now, closed = false }
end

--- Native scrollbar arrow sprites. Nil when the client id table is absent, so
--- the editor can keep a plain number field.
---@return number|nil up
---@return number|nil down
function NumberSpinner.ArrowSprites()
    if id == nil or id.Sprite == nil then return nil, nil end
    return id.Sprite.SCROLLBAR_V2_0, id.Sprite.SCROLLBAR_V2_1
end

return NumberSpinner
