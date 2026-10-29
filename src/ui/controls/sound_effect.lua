local Dropdown = require("src/ui/widgets/dropdown")
local NumberField = require("src/ui/widgets/number_field")
local Theme = require("src/ui/theme")
local Packs = require("src/packs")
local PackRows = require("src/pack_rows")
local SoundEffectValue = require("src/sound_effect_value")

local SoundEffect = {}

SoundEffect.EMPTY_PACK = "Another plugin can register sounds"
SoundEffect.BUILTIN_PLACEHOLDER = "Sound name"

-- id.Sound is userdata in the client and a table in tests. pairs sees the
-- names either way. Built once per source so a draw does not walk them again.
local catalogSource = nil
local catalog = nil

local function soundCatalog()
    local source = id.Sound
    if catalog ~= nil and catalogSource == source then return catalog end
    catalogSource = source
    local rows = {}
    if type(source) == "table" or type(source) == "userdata" then
        for name, soundId in pairs(source) do
            if type(name) == "string" and type(soundId) == "number" then
                rows[#rows + 1] = { name = name, id = soundId }
            end
        end
    end
    table.sort(rows, function(a, b) return a.name < b.name end)
    local byName = {}
    local byId = {}
    local labels = {}
    local ids = {}
    for i, row in ipairs(rows) do
        labels[i] = row.name
        ids[i] = row.id
        byName[row.name] = row.id
        byId[row.id] = row.name
    end
    catalog = { labels = labels, ids = ids, byName = byName, byId = byId }
    return catalog
end

---@param _pin table|nil
---@return number
function SoundEffect.ReservedHeight(_pin)
    return Theme.SOUND_BAND_H
end

---@return boolean
function SoundEffect.HasPackRows()
    local packs = Packs.live() or Packs.new()
    return #PackRows.SoundEffectRows(packs) > 0
end

--- Number row, then every builtin sound name, then the pack row
---@param band { x: number, y: number, w: number, h: number }
---@return table[]
function SoundEffect.Layout(band)
    local y = band.y + Theme.SOUND_TOP_GAP
    local rowH = Theme.SOUND_ROW_H
    local step = rowH + Theme.SOUND_ROW_GAP
    local packPlaceholder = SoundEffect.HasPackRows() and "None" or SoundEffect.EMPTY_PACK
    return {
        { kind = "number", x = band.x, y = y, w = band.w, h = rowH },
        { kind = "builtin", placeholder = SoundEffect.BUILTIN_PLACEHOLDER,
          x = band.x, y = y + step, w = band.w, h = rowH },
        { kind = "pack", placeholder = packPlaceholder,
          x = band.x, y = y + step * 2, w = band.w, h = rowH },
    }
end

---@param ctrl table
---@return string
function SoundEffect.Display(ctrl)
    local packs = Packs.live() or Packs.new()
    if ctrl.kind == "number" then
        return NumberField.Format(packs:ResolveSoundEffect(ctrl.value))
    end
    if ctrl.kind == "builtin" then
        local current = packs:ResolveSoundEffect(ctrl.value)
        if type(current) ~= "number" then return "" end
        return soundCatalog().byId[current] or ""
    end
    -- A raw builtin id has no pack offer. The number row already shows it.
    if type(ctrl.value) == "number" then return "" end
    return PackRows.SoundEffectClosedLabel(packs, ctrl.value)
end

-- Rows are the set captured at open. The combo narrows them; this does not
-- define a match. The number row is the stored builtin sound id. Typing still
-- commits on Enter; the arrows commit each step.
---@param host ControlHost
---@param ctrl table
function SoundEffect.Press(host, ctrl)
    if ctrl.kind == "number" then
        SoundEffect.EditNumber(host, ctrl)
    elseif ctrl.kind == "builtin" then
        SoundEffect.EditBuiltin(host, ctrl)
    else
        SoundEffect.EditPack(host, ctrl)
    end
end

-- One filtering combo of every id.Sound name. The entry id is the sound id.
-- The pick comes back as a label because the combo may reorder; names are
-- unique, so the label is the id. The number row stays for a raw id.
---@param host ControlHost
---@param ctrl table
function SoundEffect.EditBuiltin(host, ctrl)
    local names = soundCatalog()
    if #names.labels == 0 then return end
    local packs = Packs.live() or Packs.new()
    local current = packs:ResolveSoundEffect(ctrl.value)
    local initial = nil
    if type(current) == "number" then initial = names.byId[current] end
    host:MountDropdown(ctrl, {
        labels = names.labels,
        ids = names.ids,
        initial = initial,
    }, function(label)
        local soundId = names.byName[label]
        if soundId == nil then return end
        local stored = host:GetControl()
        host:Commit(SoundEffectValue.apply(stored, "number", soundId))
    end)
end

---@param host ControlHost
---@param ctrl table
function SoundEffect.EditNumber(host, ctrl)
    local packs = Packs.live() or Packs.new()
    host:MountField(ctrl, {
        filter = "NUMERIC", maxLen = 16, spinner = true,
        initial = NumberField.Format(packs:ResolveSoundEffect(ctrl.value)),
    }, function(raw, quantity)
        local parsed = NumberField.Parse(raw, quantity)
        if parsed == nil then return end
        local stored = host:GetControl()
        host:Commit(SoundEffectValue.apply(stored, "number", parsed))
    end)
end

---@param host ControlHost
---@param ctrl table
function SoundEffect.EditPack(host, ctrl)
    local packs = Packs.live() or Packs.new()
    local rows = PackRows.SoundEffectRows(packs)
    if #rows == 0 then return end
    local labels = {}
    for i, row in ipairs(rows) do
        labels[i] = row.label
    end
    local index = PackRows.SoundEffectSelectedRow(rows, ctrl.value)
    local initial = nil
    if index ~= nil then initial = labels[index] end
    host:MountDropdown(ctrl, {
        labels = labels,
        initial = initial,
    }, function(label)
        for _, row in ipairs(rows) do
            if row.label == label then
                local stored = host:GetControl()
                host:Commit(SoundEffectValue.apply(stored, "row", row))
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
    if ctrl.kind == "builtin" then
        if #soundCatalog().labels == 0 then
            NumberField.Draw(canvas, rect, ctrl, dctx)
        else
            Dropdown:Draw(canvas, rect, ctrl, dctx)
        end
        return
    end
    if ctrl.kind == "number" or not SoundEffect.HasPackRows() then
        NumberField.Draw(canvas, rect, ctrl, dctx)
    else
        Dropdown:Draw(canvas, rect, ctrl, dctx)
    end
end

return SoundEffect
