local Inline = require("src/ui/controls/inline")
local Dropdown = require("src/ui/widgets/dropdown")
local NumberField = require("src/ui/widgets/number_field")
local Packs = require("src/packs")

-- Sound Effect's pin stays dataType "number": a raw id and a pack record both
-- round-trip with no codec, and a number output can still wire in. The shared
-- number Pin Control dispatches this pin by name.

local SoundEffect = {}

---@param packs Watchdog.PackRegistry
---@return Watchdog.PackRegistry
local function registryOrEmpty(packs)
    if packs ~= nil then return packs end
    return Packs.new()
end

--- The number Pin Control, except the Sound Effect pin, which lists pack sound
--- effects and edits the stored builtin sound id.
---@param scalar table
---@return table
function SoundEffect.wrap(scalar)
    local M = Inline.apply({})

    ---@param box { x: number, y: number, w: number, h: number }
    ---@return table[]
    function M.Layout(box)
        return scalar.Layout(box)
    end

    ---@param ctrl table
    ---@return string
    function M.Display(ctrl)
        if ctrl.pinName ~= "soundId" then return scalar.Display(ctrl) end
        local packs = registryOrEmpty(Packs.live())
        return packs:SoundEffectClosedLabel(ctrl.value)
    end

    -- Rows are the set captured at open. ComboField narrows them; this does not
    -- define a match. The number field is the stored builtin sound id.
    ---@param host ControlHost
    ---@param ctrl table
    function M.Press(host, ctrl)
        if ctrl.pinName ~= "soundId" then return scalar.Press(host, ctrl) end
        local packs = registryOrEmpty(Packs.live())
        local rows = packs:SoundEffectRows()
        local labels = {}
        for i, row in ipairs(rows) do
            labels[i] = row.label
        end
        local index = packs:SoundEffectSelectedRow(rows, ctrl.value)
        local initial = nil
        if index ~= nil then initial = labels[index] end
        host:MountDropdown(ctrl, {
            labels = labels,
            initial = initial,
            numberField = true,
            number = packs:ResolveSoundEffect(ctrl.value),
            onNumber = function(raw, quantity)
                local parsed = NumberField.Parse(raw, quantity)
                if parsed == nil then return end
                local stored = host:GetControl()
                host:Commit(packs:CommitSoundEffect(stored, "number", parsed))
            end,
        }, function(label)
            for _, row in ipairs(rows) do
                if row.label == label then
                    local stored = host:GetControl()
                    host:Commit(packs:CommitSoundEffect(stored, "row", row))
                    return
                end
            end
        end)
    end

    ---@param canvas any
    ---@param rect { x: number, y: number, w: number, h: number }
    ---@param ctrl table
    ---@param dctx DrawContext
    function M.Draw(canvas, rect, ctrl, dctx)
        if ctrl.pinName ~= "soundId" then return scalar.Draw(canvas, rect, ctrl, dctx) end
        Dropdown:Draw(canvas, rect, ctrl, dctx)
    end

    return M
end

return SoundEffect
