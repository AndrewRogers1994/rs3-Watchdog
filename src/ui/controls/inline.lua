local Inline = {}

---@param M table
---@return table
function Inline.apply(M)
    M.Inline = true
    ---@return number
    function M.ReservedHeight(_pin) return 0 end
    return M
end

return Inline
