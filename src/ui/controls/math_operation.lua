local Enum = require("src/ui/controls/enum")
local Theme = require("src/ui/theme")

-- Words plus the operator. None of these labels contain "<" or ">", which the
-- client would read as a formatting tag. Each label maps to its stored operator.
local CHOICES = {
    { value = "+",   label = "Add (+)" },
    { value = "-",   label = "Subtract (-)" },
    { value = "*",   label = "Multiply (*)" },
    { value = "/",   label = "Divide (/)" },
    { value = "%",   label = "Modulo (%)" },
    { value = "min", label = "Min" },
    { value = "max", label = "Max" },
}
local MathOperation = Enum.new(CHOICES)
-- mathOperation is an enum. The kind table records these choices at registration.
MathOperation.choices = CHOICES

-- Use the node's width so the English labels fit.
MathOperation.Inline = false
function MathOperation.ReservedHeight(_pin)
    return Theme.CONTROL_H
end
function MathOperation.Layout(band)
    return { { kind = "field", x = band.x, y = band.y, w = band.w, h = Theme.CONTROL_H } }
end

return MathOperation
