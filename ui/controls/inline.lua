-- inline.lua — shared mixin for inline Pin Controls (ADR-0005). An inline control fills the single
-- value-column box on its own pin row and reserves no band, so it answers Inline/ReservedHeight
-- identically. Applied by scalar, enum, swatch, and capture.

local Inline = {}

-- Marks `M` as an inline Pin Control (Inline flag + zero ReservedHeight). Returns M.
---@param M table
---@return table
function Inline.apply(M)
    M.Inline = true
    ---@return number
    function M.ReservedHeight(_pin) return 0 end
    return M
end

return Inline
