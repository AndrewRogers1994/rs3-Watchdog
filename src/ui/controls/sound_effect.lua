local Dropdown = require("src/ui/widgets/dropdown")
local NumberField = require("src/ui/widgets/number_field")
local Theme = require("src/ui/theme")
local Packs = require("src/packs")

-- Sound Effect's pin stays dataType "number" so a number output can still wire
-- in. This module is registered for that pin only. The builtin id and the pack
-- list are separate rows: changing one must not cover the other.

local SoundEffect = {}

-- The pack row stays in the layout either way. Dropping it when a pack loads
-- would grow the node and overlap whatever is placed underneath.
SoundEffect.EMPTY_PACK = "No pack sounds"

---@param packs Watchdog.PackRegistry|nil
---@return Watchdog.PackRegistry
local function registryOrEmpty(packs)
    if packs ~= nil then return packs end
    return Packs.new()
end

---@param _pin table|nil
---@return number
function SoundEffect.ReservedHeight(_pin)
    return Theme.SOUND_BAND_H
end

---@return boolean
function SoundEffect.HasPackRows()
    return #registryOrEmpty(Packs.live()):SoundEffectRows() > 0
end

--- Number row, then the pack row, inside the band under the pin. The pack row
--- is always reserved. With no offers it is a message, not a dropdown.
---@param band { x: number, y: number, w: number, h: number }
---@return table[]
function SoundEffect.Layout(band)
    local y = band.y + Theme.SOUND_TOP_GAP
    local rowH = Theme.SOUND_ROW_H
    local packPlaceholder = SoundEffect.HasPackRows() and "None" or SoundEffect.EMPTY_PACK
    return {
        { kind = "number", x = band.x, y = y, w = band.w, h = rowH },
        { kind = "pack", placeholder = packPlaceholder,
          x = band.x, y = y + rowH + Theme.SOUND_ROW_GAP, w = band.w, h = rowH },
    }
end

---@param ctrl table
---@return string
function SoundEffect.Display(ctrl)
    local packs = registryOrEmpty(Packs.live())
    if ctrl.kind == "number" then
        return NumberField.Format(packs:ResolveSoundEffect(ctrl.value))
    end
    -- A raw builtin id has no pack offer. The number row already shows it.
    if type(ctrl.value) == "number" then return "" end
    return packs:SoundEffectClosedLabel(ctrl.value)
end

-- Rows are the set captured at open. The combo narrows them; this does not
-- define a match. The number row is the stored builtin sound id. Typing still
-- commits on Enter; the arrows commit each step.
---@param host ControlHost
---@param ctrl table
function SoundEffect.Press(host, ctrl)
    if ctrl.kind == "number" then
        SoundEffect.EditNumber(host, ctrl)
    else
        SoundEffect.EditPack(host, ctrl)
    end
end

---@param host ControlHost
---@param ctrl table
function SoundEffect.EditNumber(host, ctrl)
    local packs = registryOrEmpty(Packs.live())
    host:MountField(ctrl, {
        filter = "NUMERIC", maxLen = 16, spinner = true,
        initial = NumberField.Format(packs:ResolveSoundEffect(ctrl.value)),
    }, function(raw, quantity)
        local parsed = NumberField.Parse(raw, quantity)
        if parsed == nil then return end
        local stored = host:GetControl()
        host:Commit(packs:CommitSoundEffect(stored, "number", parsed))
    end)
end

---@param host ControlHost
---@param ctrl table
function SoundEffect.EditPack(host, ctrl)
    local packs = registryOrEmpty(Packs.live())
    local rows = packs:SoundEffectRows()
    if #rows == 0 then return end
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
function SoundEffect.Draw(canvas, rect, ctrl, dctx)
    -- No caret when there is nothing to open. A stored pack record still draws
    -- its closed label through the same plain box.
    if ctrl.kind == "number" or not SoundEffect.HasPackRows() then
        NumberField.Draw(canvas, rect, ctrl, dctx)
    else
        Dropdown:Draw(canvas, rect, ctrl, dctx)
    end
end

return SoundEffect
