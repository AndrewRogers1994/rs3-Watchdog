local Inline   = require("src/ui/controls/inline")
local Checkbox = require("src/ui/widgets/checkbox")

---@class BoolPinControl
---@field Inline boolean
---@field ReservedHeight fun(pin: any): number
local Bool = Inline.apply({})

---@param box { x: number, y: number, w: number, h: number }
---@return table[]
function Bool.Layout(box)
    return { {
        kind = "checkbox", enabled = true,
        x = box.x, y = box.y, w = box.w, h = box.h,
    } }
end

-- The pin label is already drawn on the row.
---@param _ctrl table
---@return string
function Bool.Display(_ctrl)
    return ""
end

-- ctrl.value is already default-resolved, so a default-ticked box stores false on the first click.
---@param host ControlHost
---@param ctrl table
function Bool.Press(host, ctrl)
    host:Commit(ctrl.value ~= true)
end

-- The checkbox Widget ticks value[axis]. A bool pin stores a scalar.
---@param canvas any
---@param rect { x: number, y: number, w: number, h: number }
---@param ctrl table
---@param dctx DrawContext
function Bool.Draw(canvas, rect, ctrl, dctx)
    Checkbox.Draw(canvas, rect, {
        enabled = true,
        display = ctrl.display,
        axis = "on",
        value = { on = ctrl.value == true },
    }, dctx)
end

return Bool
