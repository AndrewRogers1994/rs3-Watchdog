local Inline = require("src/ui/controls/inline")
local Dropdown = require("src/ui/widgets/dropdown")
local NumberField = require("src/ui/widgets/number_field")
local Packs = require("src/packs")

-- Sound Effect's pin stays dataType "number" so a number output can still wire
-- in. This module is registered for that pin only.

local SoundEffect = {}

---@param packs Watchdog.PackRegistry|nil
---@return Watchdog.PackRegistry
local function registryOrEmpty(packs)
    if packs ~= nil then return packs end
    return Packs.new()
end

--- The closed control is one box. Opening places the number field in that box
--- and the choice list directly under it. The editor mounts those rects; it
--- does not decide the offset.
---@param x number
---@param y number
---@param w number
---@param h number
---@return { x: number, y: number, w: number, h: number } numberBox
---@return { x: number, y: number, w: number, h: number } listBox
function SoundEffect.OpenLayout(x, y, w, h)
    return
        { x = x, y = y, w = w, h = h },
        { x = x, y = y + h, w = w, h = h }
end

---@param box { x: number, y: number, w: number, h: number }
---@return table[]
function SoundEffect.Layout(box)
    return { { kind = "field", x = box.x, y = box.y, w = box.w, h = box.h } }
end

---@param ctrl table
---@return string
function SoundEffect.Display(ctrl)
    local packs = registryOrEmpty(Packs.live())
    return packs:SoundEffectClosedLabel(ctrl.value)
end

-- Rows are the set captured at open. The combo narrows them; this does not
-- define a match. The number field is the stored builtin sound id.
---@param host ControlHost
---@param ctrl table
function SoundEffect.Press(host, ctrl)
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
        openLayout = SoundEffect.OpenLayout,
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
function SoundEffect.Draw(canvas, rect, ctrl, dctx)
    Dropdown:Draw(canvas, rect, ctrl, dctx)
end

Inline.apply(SoundEffect)

return SoundEffect
