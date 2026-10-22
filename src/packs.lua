-- In-memory Pack registry. Not a PersistentDB document: a Watchdog reload starts empty.
-- Packs call in; Watchdog does not scan plugins. Registration does not write the
-- Preset library and does not mint a Preset id.

local Presets = require("src/presets")

---@class Watchdog.PackRefusal
---@field kind "soundEffects"|"audioFiles"|"alertPresets"
---@field authorId any

---@class Watchdog.PackSoundEffect
---@field authorId string
---@field label string
---@field soundId number

--- `loaded` lives on PluginResource. The audio stub does not repeat it, and
--- registration reads that flag without calling Load.
---@class PluginAudioResource
---@field loaded boolean

---@class Watchdog.PackAudioFile
---@field authorId string
---@field label string
---@field audio PluginAudioResource

---@class Watchdog.PackAlertPreset
---@field authorId string
---@field name string
---@field graph table
---@field layout Watchdog.LayoutArray
---@field variables Watchdog.PresetVariable[]

---@class Watchdog.PackRegistration
---@field token any
---@field soundEffects table<string, Watchdog.PackSoundEffect>
---@field audioFiles table<string, Watchdog.PackAudioFile>
---@field alertPresets table<string, Watchdog.PackAlertPreset>

---@class Watchdog.PackAudioHold
---@field instance { isPlaying: boolean }
---@field resource PluginAudioResource

---@class Watchdog.AlertPresetGroup
---@field packName string
---@field presets Watchdog.PackAlertPreset[]

---@class Watchdog.PackRegistry
---@field private byName table<string, Watchdog.PackRegistration>
---@field private pendingAudio PluginAudioResource|nil
---@field private audioHolds Watchdog.PackAudioHold[]|nil
local Packs = {}
Packs.__index = Packs

local LIST_FIELDS = { "soundEffects", "audioFiles", "alertPresets" }
-- The 80-character cap is the Preset name rule. Trim is the Preset trim.
local NAME_MAX = Presets.NAME_MAX

---@param name string|nil
---@return string
local function trim(name)
    return Presets.trim(name)
end

-- authorId on a refusal is the value the Pack passed, not the trimmed text.
---@param entry any
---@return any
local function rawAuthorId(entry)
    if type(entry) ~= "table" then return nil end
    return entry.authorId
end

---@param entry any
---@return string|nil
local function acceptedAuthorId(entry)
    if type(entry) ~= "table" or type(entry.authorId) ~= "string" then return nil end
    local authorId = trim(entry.authorId)
    if authorId == "" then return nil end
    return authorId
end

-- A bad entry is a refusal. The first accepted author id in this kind wins.
---@param list table|nil
---@param kind string
---@param accept fun(entry: table, authorId: string): table|nil
---@return table stored
---@return table refusals
local function collect(list, kind, accept)
    local stored = {}
    local taken = {}
    local refusals = {}
    if type(list) ~= "table" then return stored, refusals end
    for _, entry in ipairs(list) do
        local authorId = acceptedAuthorId(entry)
        local record = nil
        if authorId ~= nil and not taken[authorId] then
            record = accept(entry, authorId)
        end
        if record == nil then
            refusals[#refusals + 1] = { kind = kind, authorId = rawAuthorId(entry) }
        else
            taken[authorId] = true
            stored[authorId] = record
        end
    end
    return stored, refusals
end

---@param entry table
---@param authorId string
---@return Watchdog.PackSoundEffect|nil
local function acceptSound(entry, authorId)
    if type(entry.label) ~= "string" then return nil end
    local label = trim(entry.label)
    if label == "" or type(entry.soundId) ~= "number" then return nil end
    return { authorId = authorId, label = label, soundId = entry.soundId }
end

-- A PluginAudioResource may be a table or userdata. Anything else is not loaded.
-- Watchdog does not call Load; the Pack loads the resource before it registers.
---@param audio any
---@return boolean
local function resourceIsLoaded(audio)
    local kind = type(audio)
    if kind ~= "table" and kind ~= "userdata" then return false end
    return audio.loaded == true
end

---@param entry table
---@param authorId string
---@return Watchdog.PackAudioFile|nil
local function acceptAudio(entry, authorId)
    if type(entry.label) ~= "string" then return nil end
    local label = trim(entry.label)
    if label == "" or not resourceIsLoaded(entry.audio) then return nil end
    return { authorId = authorId, label = label, audio = entry.audio }
end

-- A sequence has no keys past the nil hole ipairs stops at, and no map fields.
---@param value any
---@return boolean
local function isSequence(value)
    if type(value) ~= "table" then return false end
    local n = 0
    for _ in ipairs(value) do n = n + 1 end
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    return count == n
end

---@param value any
---@param seen table|nil
---@return any
local function deepCopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] ~= nil then return seen[value] end
    local copy = {}
    seen[value] = copy
    for key, item in pairs(value) do
        copy[deepCopy(key, seen)] = deepCopy(item, seen)
    end
    return copy
end

-- Missing layout is empty. A bad entry refuses the whole Alert Preset.
---@param layout table|nil
---@return table|nil
local function copyLayout(layout)
    if layout == nil then return {} end
    if not isSequence(layout) then return nil end
    local out = {}
    for _, entry in ipairs(layout) do
        if type(entry) ~= "table" or type(entry.id) ~= "number" then return nil end
        if entry.x ~= nil and type(entry.x) ~= "number" then return nil end
        if entry.y ~= nil and type(entry.y) ~= "number" then return nil end
        out[#out + 1] = { id = entry.id, x = entry.x or 0, y = entry.y or 0 }
    end
    return out
end

-- Missing Variables means none. A repeated node id and pin name keeps the first.
-- List order is the order the player will be asked, so this copy does not sort.
---@param variables table|nil
---@return table|nil
local function copyVariables(variables)
    if variables == nil then return {} end
    if not isSequence(variables) then return nil end
    local seen = {}
    local out = {}
    for _, entry in ipairs(variables) do
        if type(entry) ~= "table" or type(entry.nodeId) ~= "number" or type(entry.pinName) ~= "string" then
            return nil
        end
        local pins = seen[entry.nodeId]
        if pins == nil then
            pins = {}
            seen[entry.nodeId] = pins
        end
        if not pins[entry.pinName] then
            pins[entry.pinName] = true
            out[#out + 1] = { nodeId = entry.nodeId, pinName = entry.pinName }
        end
    end
    return out
end

---@param entry table
---@param authorId string
---@return Watchdog.PackAlertPreset|nil
local function acceptPreset(entry, authorId)
    local name = trim(entry.name)
    -- Same 80-character rule as Presets.Add: length is the byte length of the trimmed name.
    if name == "" or #name > NAME_MAX or type(entry.graph) ~= "table" then return nil end
    local layout = copyLayout(entry.layout)
    if layout == nil then return nil end
    local variables = copyVariables(entry.variables)
    if variables == nil then return nil end
    return {
        authorId = authorId,
        name = name,
        graph = deepCopy(entry.graph),
        layout = layout,
        variables = variables,
    }
end

---@param into table
---@param extra table
local function appendAll(into, extra)
    for _, item in ipairs(extra) do
        into[#into + 1] = item
    end
end

---@return Watchdog.PackRegistry
function Packs.new()
    return setmetatable({ byName = {} }, Packs)
end

--- Claims a Pack name and copies the contributions Watchdog accepts.
--- A blank name, a non-table contributions value, or a list field that is not a
--- table raises before the name is claimed. A bad entry is a refusal, and the
--- name stays claimed.
---@param name string
---@param contributions table|nil
---@return any token
---@return Watchdog.PackRefusal[] refusals
function Packs:RegisterDataPack(name, contributions)
    local packName = trim(name)
    if packName == "" then
        error("Pack name is blank.", 2)
    end
    if contributions ~= nil and type(contributions) ~= "table" then
        error("Contributions must be a table.", 2)
    end
    if type(contributions) == "table" then
        for _, field in ipairs(LIST_FIELDS) do
            local list = contributions[field]
            if list ~= nil and type(list) ~= "table" then
                error(field .. " must be a list.", 2)
            end
        end
    end
    if self.byName[packName] ~= nil then
        error("Pack name is already held.", 2)
    end
    local token = {}
    local lists = type(contributions) == "table" and contributions or {}
    local soundEffects, soundRefusals = collect(lists.soundEffects, "soundEffects", acceptSound)
    local audioFiles, audioRefusals = collect(lists.audioFiles, "audioFiles", acceptAudio)
    local alertPresets, presetRefusals = collect(lists.alertPresets, "alertPresets", acceptPreset)
    local refusals = {}
    appendAll(refusals, soundRefusals)
    appendAll(refusals, audioRefusals)
    appendAll(refusals, presetRefusals)
    self.byName[packName] = {
        token = token,
        soundEffects = soundEffects,
        audioFiles = audioFiles,
        alertPresets = alertPresets,
    }
    return token, refusals
end

---@param packName string
---@param authorId string
---@param field string
---@return table|nil
local function lookup(self, packName, authorId, field)
    local registration = self.byName[trim(packName)]
    if registration == nil or registration[field] == nil then return nil end
    local id = trim(authorId)
    if id == "" then return nil end
    return registration[field][id]
end

---@param packName string
---@param authorId string
---@return Watchdog.PackSoundEffect|nil
function Packs:GetSoundEffect(packName, authorId)
    return lookup(self, packName, authorId, "soundEffects")
end

---@param packName string
---@param authorId string
---@return Watchdog.PackAudioFile|nil
function Packs:GetAudioFile(packName, authorId)
    return lookup(self, packName, authorId, "audioFiles")
end

---@param packName string
---@param authorId string
---@return Watchdog.PackAlertPreset|nil
function Packs:GetAlertPreset(packName, authorId)
    return lookup(self, packName, authorId, "alertPresets")
end

-- Releases only the registration this token holds. Any other value leaves the holder.
---@param token any
function Packs:Clear(token)
    for name, registration in pairs(self.byName) do
        if registration.token == token then
            self.byName[name] = nil
            return
        end
    end
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
---@return { pack: string, authorId: string, label: string }[]
local function packAudioOffers(self)
    local offers = {}
    for packName, registration in pairs(self.byName) do
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

--- The open list for Custom Sound, captured here. A later call reads the live registry again.
--- None, then each Watchdog audio file name, then each pack audio file.
---@param watchdogNames string[]|nil
---@param stored any
---@return Watchdog.AudioChoiceList
function Packs:OpenAudioChoices(watchdogNames, stored)
    local rows = { { label = "None", value = nil } }
    for _, name in ipairs(watchdogFileNames(watchdogNames)) do
        rows[#rows + 1] = { label = name, value = name }
    end
    local offers = packAudioOffers(self)
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
---@param stored any
---@return string
function Packs:AudioClosedLabel(stored)
    if stored == nil then return "None" end
    if type(stored) == "string" then return stored end
    if type(stored) ~= "table" or type(stored.pack) ~= "string" or type(stored.authorId) ~= "string" then
        return tostring(stored)
    end
    for _, row in ipairs(self:OpenAudioChoices(nil, stored):Rows()) do
        local value = row.value
        if type(value) == "table" and value.pack == stored.pack and value.authorId == stored.authorId then
            return row.label
        end
    end
    return stored.pack .. " / " .. stored.authorId .. " (missing)"
end

-- A play already handed to audio.Play can keep its resource after Clear. That reference
-- is not a registration: ResolveAudioPlay never reads it. Drop it once the instance
-- is no longer playing. Do not call Stop; the loop count it started with runs out.
local function releaseFinishedAudioHolds(self)
    local holds = self.audioHolds
    if holds == nil then return end
    local kept = {}
    for _, hold in ipairs(holds) do
        if hold.instance ~= nil and hold.instance.isPlaying == true then
            kept[#kept + 1] = hold
        end
    end
    self.audioHolds = kept
end

--- A new play. A string is a Watchdog audio file name. A pack record asks the live registry only.
--- A miss returns nil. This does not call Load, and it does not return a privately held resource.
---@param stored any
---@param watchdogAudio table<string, PluginAudioResource>|nil
---@return PluginAudioResource|nil
function Packs:ResolveAudioPlay(stored, watchdogAudio)
    releaseFinishedAudioHolds(self)
    self.pendingAudio = nil
    if type(stored) == "string" then
        if type(watchdogAudio) ~= "table" then return nil end
        return watchdogAudio[stored]
    end
    if type(stored) ~= "table" or type(stored.pack) ~= "string" or type(stored.authorId) ~= "string" then
        return nil
    end
    local file = self:GetAudioFile(stored.pack, stored.authorId)
    if file == nil then return nil end
    self.pendingAudio = file.audio
    return file.audio
end

--- The node reports the instance audio.Play returned. The resource just resolved stays
--- reachable until that instance is finished. This does not stop the instance.
---@param instance { isPlaying: boolean }|nil
function Packs:NoteAudioPlay(instance)
    releaseFinishedAudioHolds(self)
    local resource = self.pendingAudio
    self.pendingAudio = nil
    if instance == nil or resource == nil then return end
    local holds = self.audioHolds
    if holds == nil then
        holds = {}
        self.audioHolds = holds
    end
    holds[#holds + 1] = { instance = instance, resource = resource }
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
---@return Watchdog.PackSoundRow[]
function Packs:SoundEffectRows()
    local rows = {}
    for packName, registration in pairs(self.byName) do
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

---@class Watchdog.PackSoundRecord
---@field pack string
---@field authorId string
---@field soundId number

---@param value any
---@return boolean
local function isPackSoundRecord(value)
    return type(value) == "table"
        and type(value.pack) == "string"
        and type(value.authorId) == "string"
        and type(value.soundId) == "number"
end

--- Closed Sound Effect text. A live offer uses the same text as its open row,
--- plus " (outdated)" when the stored builtin sound id is not the one registered
--- now. A missing offer shows the stored id, Pack name, and author id.
--- A raw builtin sound id shows the number alone.
---@param value any
---@return string
function Packs:SoundEffectClosedLabel(value)
    if type(value) == "number" then
        return tostring(value)
    end
    if not isPackSoundRecord(value) then
        return ""
    end
    for _, row in ipairs(self:SoundEffectRows()) do
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
function Packs:SoundEffectSelectedRow(rows, value)
    if type(rows) ~= "table" or not isPackSoundRecord(value) then return nil end
    for i, row in ipairs(rows) do
        if row.pack == value.pack and row.authorId == value.authorId then
            return i
        end
    end
    return nil
end

--- What the Sound Effect control stores after a player action.
--- A row commit copies that row and does not consult the live registry.
--- A different number replaces a pack record. The same number leaves it.
--- Highlighting or dismissing does not write.
---@param stored any
---@param action "row"|"number"|"highlight"|"dismiss"
---@param choice Watchdog.PackSoundRow|number|nil
---@return any
function Packs:CommitSoundEffect(stored, action, choice)
    if action == "highlight" or action == "dismiss" then
        return stored
    end
    if action == "row" then
        if type(choice) ~= "table"
            or type(choice.pack) ~= "string"
            or type(choice.authorId) ~= "string"
            or type(choice.soundId) ~= "number" then
            return stored
        end
        return { pack = choice.pack, authorId = choice.authorId, soundId = choice.soundId }
    end
    if action == "number" then
        if type(choice) ~= "number" then return stored end
        local current = nil
        if type(stored) == "number" then
            current = stored
        elseif isPackSoundRecord(stored) then
            current = stored.soundId
        end
        if current ~= nil and choice == current then return stored end
        return choice
    end
    return stored
end

--- Builtin sound id to play. A number is that id. A pack record is the id it
--- stored. Anything else is silent. The Pack does not have to be registered,
--- and a changed live id is not substituted. A pack sound effect has no
--- private hold.
---@param value any
---@return number|nil
function Packs:ResolveSoundEffect(value)
    if type(value) == "number" then return value end
    if isPackSoundRecord(value) then return value.soundId end
    return nil
end

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
---@return Watchdog.AlertPresetGroup[]
function Packs:AlertPresetGroups()
    local groups = {}
    for packName, registration in pairs(self.byName) do
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

local liveRegistry = nil

---@param registry Watchdog.PackRegistry|nil
function Packs.install(registry)
    liveRegistry = registry
end

---@return Watchdog.PackRegistry|nil
function Packs.live()
    return liveRegistry
end

return Packs
