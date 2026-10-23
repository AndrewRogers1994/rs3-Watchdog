-- Picker rows and closed text for one Pack registry the caller passes in.
-- Does not register Packs, clear tokens, resolve playback, or hold audio.
-- Does not call Packs.live(). An open list is the rows captured at that call.
-- Does not decide what a Sound Effect Control stores.

local SoundEffectValue = require("src/sound_effect_value")
local Presets = require("src/presets")

local PackRows = {}

--- "Pack name / label", or that text plus the author id when it repeats inside one Pack.
---@param pack string
---@param label string
---@param authorId string
---@param repeated boolean
---@return string
local function rowLabel(pack, label, authorId, repeated)
    local text = pack .. " / " .. label
    if repeated then
        return text .. " (" .. authorId .. ")"
    end
    return text
end

-- The registrations the registry holds. Rows are derived from this map.
-- Packs does not build them.
---@param registry Watchdog.PackRegistry
---@return table<string, Watchdog.PackRegistration>
local function registrations(registry)
    -- byName stays private on the registry. This module is the reader that used
    -- to live on Packs; other callers ask the row builder.
    ---@diagnostic disable-next-line: invisible
    return registry.byName
end

---@class Watchdog.PackSoundRow
---@field pack string
---@field authorId string
---@field soundId number
---@field label string

--- One open of the Sound Effect list. The tables are a copy, so a later
--- register or clear does not change rows the player already has open.
--- A repeated "Pack name / label" inside one Pack shows the author id on
--- each of those rows. The same label in two Packs does not: the Pack name
--- is already part of the text.
---@param registry Watchdog.PackRegistry
---@return Watchdog.PackSoundRow[]
function PackRows.SoundEffectRows(registry)
    local rows = {}
    for packName, registration in pairs(registrations(registry)) do
        local effects = registration.soundEffects
        if type(effects) == "table" then
            local labelCount = {}
            for _, effect in pairs(effects) do
                labelCount[effect.label] = (labelCount[effect.label] or 0) + 1
            end
            for authorId, effect in pairs(effects) do
                rows[#rows + 1] = {
                    pack = packName,
                    authorId = authorId,
                    soundId = effect.soundId,
                    label = rowLabel(packName, effect.label, authorId, labelCount[effect.label] > 1),
                }
            end
        end
    end
    return rows
end

--- Closed Sound Effect text. A live offer uses the same text as its open row,
--- plus " (outdated)" when the stored builtin sound id is not the one registered
--- now. A missing offer shows the stored id, Pack name, and author id.
--- A raw builtin sound id shows the number alone.
---@param registry Watchdog.PackRegistry
---@param value any
---@return string
function PackRows.SoundEffectClosedLabel(registry, value)
    if type(value) == "number" then
        return tostring(value)
    end
    if not SoundEffectValue.isPackSoundEffect(value) then
        return ""
    end
    for _, row in ipairs(PackRows.SoundEffectRows(registry)) do
        if row.pack == value.pack and row.authorId == value.authorId then
            if row.soundId ~= value.soundId then
                return row.label .. " (outdated)"
            end
            return row.label
        end
    end
    return tostring(value.soundId) .. " (" .. value.pack .. " / " .. value.authorId .. ")"
end

--- The row for the stored Pack name and author id. A raw number selects
--- nothing, including when some row's builtin sound id is that number.
---@param rows Watchdog.PackSoundRow[]
---@param value any
---@return integer|nil
function PackRows.SoundEffectSelectedRow(rows, value)
    if type(rows) ~= "table" or not SoundEffectValue.isPackSoundEffect(value) then return nil end
    for i, row in ipairs(rows) do
        if row.pack == value.pack and row.authorId == value.authorId then
            return i
        end
    end
    return nil
end

--- Same choice value, or the same pack identity. Table identity is not required.
--- A pack audio file matches on Pack name and author id. When either value stores
--- a builtin sound id, those ids must match too, so a pack sound effect is not
--- a pack audio file.
---@param left any
---@param right any
---@return boolean
local function sameChoice(left, right)
    if left == right then return true end
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    if type(left.pack) ~= "string" or type(right.pack) ~= "string" then return false end
    if type(left.authorId) ~= "string" or type(right.authorId) ~= "string" then return false end
    if left.pack ~= right.pack or left.authorId ~= right.authorId then return false end
    if left.soundId ~= nil or right.soundId ~= nil then
        return left.soundId == right.soundId
    end
    return true
end

--- Index of the choice whose value is this stored value. Nil when none matches.
--- A raw number matches a choice whose value is that number. It does not match
--- a pack sound effect row: those rows are not choices, and SoundEffectSelectedRow
--- is the pack sound effect match.
---@param rows { value: any, label: string }[]|nil
---@param stored any
---@return integer|nil
function PackRows.MatchingChoice(rows, stored)
    if type(rows) ~= "table" then return nil end
    for i, row in ipairs(rows) do
        if type(row) == "table" and sameChoice(row.value, stored) then
            return i
        end
    end
    return nil
end

-- A Watchdog file named None is the clear choice, so it is not also a file row.
---@param watchdogNames string[]|nil
---@return string[]
local function watchdogFileNames(watchdogNames)
    local names = {}
    if type(watchdogNames) ~= "table" then return names end
    for _, name in ipairs(watchdogNames) do
        if type(name) == "string" and name ~= "None" then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

-- Row text is "Pack name / label". A repeat of that text inside one Pack
-- puts the author id on each of those rows so the player can tell them apart.
---@param registry Watchdog.PackRegistry
---@return { pack: string, authorId: string, label: string }[]
local function packAudioOffers(registry)
    local offers = {}
    for packName, registration in pairs(registrations(registry)) do
        for authorId, file in pairs(registration.audioFiles) do
            offers[#offers + 1] = {
                pack = packName,
                authorId = authorId,
                label = file.label,
            }
        end
    end
    table.sort(offers, function(a, b)
        if a.pack ~= b.pack then return a.pack < b.pack end
        return a.authorId < b.authorId
    end)
    return offers
end

---@param offers { pack: string, authorId: string, label: string }[]
---@return table<string, table<string, number>>
local function rowTextCounts(offers)
    local counts = {}
    for _, offer in ipairs(offers) do
        local byPack = counts[offer.pack]
        if byPack == nil then
            byPack = {}
            counts[offer.pack] = byPack
        end
        local text = offer.pack .. " / " .. offer.label
        byPack[text] = (byPack[text] or 0) + 1
    end
    return counts
end

---@class Watchdog.AudioChoiceRow
---@field label string
---@field value nil|string|{ pack: string, authorId: string }

---@class Watchdog.AudioChoiceList
---@field rows Watchdog.AudioChoiceRow[]
---@field stored any
---@field highlighted string
local AudioChoiceList = {}
AudioChoiceList.__index = AudioChoiceList

---@return Watchdog.AudioChoiceRow[]
function AudioChoiceList:Rows()
    return self.rows
end

--- The row for the stored identity, or None when nothing in this open matches.
--- A highlight is not a stored value.
---@param rows Watchdog.AudioChoiceRow[]
---@param stored any
---@return string
local function highlightedLabel(rows, stored)
    if type(stored) == "string" then
        for _, row in ipairs(rows) do
            if row.value == stored then return row.label end
        end
    elseif type(stored) == "table" then
        for _, row in ipairs(rows) do
            local value = row.value
            if type(value) == "table" and value.pack == stored.pack and value.authorId == stored.authorId then
                return row.label
            end
        end
    end
    return "None"
end

---@return string
function AudioChoiceList:HighlightedLabel()
    return self.highlighted
end

--- Moves which row is highlighted. The stored identity stays until Commit.
---@param label string
function AudioChoiceList:Highlight(label)
    for _, row in ipairs(self.rows) do
        if row.label == label then
            self.highlighted = label
            return
        end
    end
end

--- The identity this open was given. Opening does not replace it.
---@return any
function AudioChoiceList:Stored()
    return self.stored
end

--- Stores the captured row's identity. None is nil. A pack row is pack and author id only.
---@param label string
---@return any value
---@return boolean found
function AudioChoiceList:Commit(label)
    for _, row in ipairs(self.rows) do
        if row.label == label then
            if type(row.value) == "table" then
                return { pack = row.value.pack, authorId = row.value.authorId }, true
            end
            return row.value, true
        end
    end
    return nil, false
end

--- The open list for Custom Sound, captured here. A later call reads the registry again.
--- None, then each Watchdog audio file name, then each pack audio file.
--- The row builder does not read Plugin.resources. The caller passes the names.
---@param registry Watchdog.PackRegistry
---@param watchdogNames string[]|nil
---@param stored any
---@return Watchdog.AudioChoiceList
function PackRows.OpenAudioChoices(registry, watchdogNames, stored)
    local rows = { { label = "None", value = nil } }
    for _, name in ipairs(watchdogFileNames(watchdogNames)) do
        rows[#rows + 1] = { label = name, value = name }
    end
    local offers = packAudioOffers(registry)
    local counts = rowTextCounts(offers)
    for _, offer in ipairs(offers) do
        local text = offer.pack .. " / " .. offer.label
        rows[#rows + 1] = {
            label = rowLabel(offer.pack, offer.label, offer.authorId, counts[offer.pack][text] > 1),
            value = { pack = offer.pack, authorId = offer.authorId },
        }
    end
    return setmetatable({
        rows = rows,
        stored = stored,
        highlighted = highlightedLabel(rows, stored),
    }, AudioChoiceList)
end

--- Closed Custom Sound text. A live pack audio file uses the same text as its
--- open row ("Pack / label", plus the author id when that text repeats).
--- A missing one reads "{pack} / {authorId} (missing)". Pack audio files do not use " (outdated)".
---@param registry Watchdog.PackRegistry
---@param stored any
---@return string
function PackRows.AudioClosedLabel(registry, stored)
    if stored == nil then return "None" end
    if type(stored) == "string" then return stored end
    if type(stored) ~= "table" or type(stored.pack) ~= "string" or type(stored.authorId) ~= "string" then
        return tostring(stored)
    end
    for _, row in ipairs(PackRows.OpenAudioChoices(registry, nil, stored):Rows()) do
        local value = row.value
        if type(value) == "table" and value.pack == stored.pack and value.authorId == stored.authorId then
            return row.label
        end
    end
    return stored.pack .. " / " .. stored.authorId .. " (missing)"
end

---@class Watchdog.AlertPresetGroup
---@field packName string
---@field presets Watchdog.PackAlertPreset[]

--- Natural compare, then the raw string, then the author id when the names match.
---@param left Watchdog.PackAlertPreset
---@param right Watchdog.PackAlertPreset
---@return boolean
local function presetBefore(left, right)
    local cmp = Presets.natcasecmp(left.name, right.name)
    if cmp ~= 0 then return cmp < 0 end
    if left.name ~= right.name then return left.name < right.name end
    return left.authorId < right.authorId
end

--- Groups captured from the registrations held now. Pack order is the Preset
--- library's case-insensitive natural compare, then Lua `<` on the pack name
--- when that compare ties. Inside a group the same compare runs on the trimmed
--- name, then `<` on the raw name, then `<` on the author id when the names
--- match including case. A Pack with no Alert Preset is omitted. A later
--- registration does not rewrite the arrays this call already returned.
--- The Preset library does not read this module.
---@param registry Watchdog.PackRegistry
---@return Watchdog.AlertPresetGroup[]
function PackRows.AlertPresetGroups(registry)
    local groups = {}
    for packName, registration in pairs(registrations(registry)) do
        local presets = {}
        for _, preset in pairs(registration.alertPresets) do
            presets[#presets + 1] = preset
        end
        if #presets > 0 then
            table.sort(presets, presetBefore)
            groups[#groups + 1] = { packName = packName, presets = presets }
        end
    end
    table.sort(groups, function(left, right)
        local cmp = Presets.natcasecmp(left.packName, right.packName)
        if cmp ~= 0 then return cmp < 0 end
        return left.packName < right.packName
    end)
    return groups
end

return PackRows
