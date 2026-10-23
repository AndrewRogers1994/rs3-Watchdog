-- Variable dialog for a Sound Effect mark: the sound id field plus the pack list.

_G.id = _G.id or {}
_G.id.Sound = _G.id.Sound or { TOWN_CRIER_BELL_RING_1 = 2608 }

local luaunit = require("luaunit")

local Serialize = require("serialize")
local Json = require("json")
LibNodeGraph = {
    NewGraph = require("graph").new,
    Serialize = Serialize.Serialize,
    Deserialize = Serialize.Deserialize,
    Json = Json,
    UNKNOWN_TYPE = require("registry").UNKNOWN_TYPE,
}

local Packs = require("src/packs")
local Dialog = require("src/ui/dialog")
local PresetDialogs = require("src/ui/preset_dialogs")
local Registry = require("registry")
require("src/nodes/actions/sound")

local function labelsOf(entries)
    local labels = {}
    for i, entry in ipairs(entries) do
        labels[i] = entry.label
    end
    return labels
end

local function click(buttons, label)
    for _, button in ipairs(buttons) do
        if button.label == label then
            button.action()
            return
        end
    end
    error("missing button " .. label)
end

TestPresetVariableSound = {}

function TestPresetVariableSound:setUp()
    self.saved = { ui = _G.ui, prettyui = _G.prettyui, Vector4 = _G.Vector4 }
    self.packs = Packs.new()
    Packs.install(self.packs)
    self.parent = { height = 800 }
    self.texts = {}
    self.fields = {}
    self.combos = {}
    self.buttons = {}
    local texts, fields, combos, buttons = self.texts, self.fields, self.combos, self.buttons
    local body = {}
    function body:AddText(text)
        local widget = { content = text }
        texts[#texts + 1] = widget
        return widget
    end
    function body:AddTextField(opts)
        local field = { text = opts.text, opts = opts }
        function field:GetText()
            return self.text
        end
        function field:SetText(value, notify)
            self.text = tostring(value or "")
            if notify == true and opts.onChange ~= nil then
                opts.onChange(self)
            end
        end
        fields[#fields + 1] = field
        return field
    end
    function body:AddComboBox(opts)
        local combo = { opts = opts, selectedID = opts.selectedID }
        function combo:Select(entryID, notify)
            self.selectedID = entryID
            if notify == true and opts.onChange ~= nil then
                local label = nil
                for _, entry in ipairs(opts.entries) do
                    if entry.id == entryID then label = entry.label end
                end
                opts.onChange(self, entryID, label)
            end
        end
        combos[#combos + 1] = combo
        return combo
    end
    local function component()
        return {
            SetPos = function() end,
            SetSize = function() end,
            MoveToFront = function() end,
            Destroy = function() end,
        }
    end
    _G.Vector4 = { new = function() return {} end }
    _G.ui = {
        Layer = { new = component },
        Rectangle = { new = component },
        Hook = {},
    }
    _G.prettyui = {
        FancyButton = { getSize = function() return 80, 27 end },
        Window = {
            new = function(_, options)
                local win = {
                    title = options.title,
                    content = {},
                    onClose = options.onClose,
                }
                function win:SetScrollable() end
                function win:Show() end
                function win:MoveToFront() end
                function win:AddFancyButton(label, action, opts)
                    local button = { label = label, action = action, opts = opts or {} }
                    function button:SetDisabled(disabled)
                        self.disabled = disabled == true
                    end
                    buttons[#buttons + 1] = button
                    return button
                end
                function win:Destroy() end
                return win
            end,
        },
        SimpleView = { new = function() return body end },
    }
    self.registry = Registry.new()
    require("src/nodes/actions/sound").Register(self.registry)
    self.registry:RegisterNodeType("fixture.hold", {
        category = "action",
        pins = {
            { name = "hold", kind = "data", direction = "in", dataType = "number", default = 4 },
        },
        run = function() end,
    })
end

function TestPresetVariableSound:tearDown()
    Dialog.dismissAll(self.parent)
    Packs.install(nil)
    _G.ui = self.saved.ui
    _G.prettyui = self.saved.prettyui
    _G.Vector4 = self.saved.Vector4
end

---@param soundId any
---@return Watchdog.Preset
function TestPresetVariableSound:preset(soundId)
    local graph = LibNodeGraph.NewGraph(self.registry)
    local soundNode = graph:AddNode("action.sound", { soundId = soundId })
    local holdNode = graph:AddNode("fixture.hold", { hold = 4 })
    return {
        name = "Callout",
        graph = LibNodeGraph.Serialize(graph),
        variables = {
            { nodeId = soundNode, pinName = "soundId" },
            { nodeId = holdNode, pinName = "hold" },
        },
    }
end

function TestPresetVariableSound:mount(preset, onCreate)
    PresetDialogs.mountVariables(self.parent, {
        preset = preset,
        registry = self.registry,
        onCreate = onCreate or function() return 1 end,
    })
end

function TestPresetVariableSound:testSoundIdOffersEveryPackSoundAndAPlainNumberDoesNot()
    self.packs:RegisterDataPack("Voice", {
        soundEffects = {
            { authorId = "horn", label = "Horn", soundId = 222 },
            { authorId = "bell", label = "Bell", soundId = 111 },
        },
    })
    self:mount(self:preset(50))
    luaunit.assertEquals(#self.fields, 2)
    luaunit.assertEquals(self.fields[1].text, "50")
    luaunit.assertEquals(self.fields[2].text, "4")
    luaunit.assertEquals(#self.combos, 1)
    luaunit.assertEquals(labelsOf(self.combos[1].opts.entries), {
        "None",
        "Voice / Bell",
        "Voice / Horn",
    })
    luaunit.assertEquals(self.combos[1].selectedID, 1)
end

function TestPresetVariableSound:testChoosingAPackSoundFillsTheSoundIdAndCreatesThatRecord()
    self.packs:RegisterDataPack("Voice", {
        soundEffects = {
            { authorId = "bell", label = "Bell", soundId = 111 },
            { authorId = "horn", label = "Horn", soundId = 222 },
        },
    })
    local answers
    self:mount(self:preset(50), function(got)
        answers = got
        return 1
    end)
    self.combos[1].opts.onChange(self.combos[1], 3, "Voice / Horn")
    luaunit.assertEquals(self.fields[1].text, "222")
    click(self.buttons, "Create")
    luaunit.assertEquals(answers[1], { pack = "Voice", authorId = "horn", soundId = 222 })
    luaunit.assertEquals(answers[2], { raw = "4", quantity = nil })
end

function TestPresetVariableSound:testAnUntouchedPackSoundEffectShowsItsBuiltinSoundId()
    self.packs:RegisterDataPack("Voice", {
        soundEffects = {
            { authorId = "bell", label = "Bell", soundId = 111 },
        },
    })
    local record = { pack = "Voice", authorId = "bell", soundId = 12345 }
    local answers
    self:mount(self:preset(record), function(got)
        answers = got
        return 1
    end)
    luaunit.assertEquals(self.fields[1].text, "12345")
    luaunit.assertEquals(self.combos[1].selectedID, 2)
    click(self.buttons, "Create")
    luaunit.assertEquals(answers[2], { raw = "4", quantity = nil })
end

function TestPresetVariableSound:testChoosingNoneLeavesTheTypedSoundId()
    self.packs:RegisterDataPack("Voice", {
        soundEffects = {
            { authorId = "bell", label = "Bell", soundId = 111 },
        },
    })
    local record = { pack = "Voice", authorId = "bell", soundId = 12345 }
    self:mount(self:preset(record))
    self.combos[1].opts.onChange(self.combos[1], 1, "None")
    luaunit.assertEquals(self.fields[1].text, "12345")
end

function TestPresetVariableSound:testTypingADifferentIdClearsThePackSelection()
    self.packs:RegisterDataPack("Voice", {
        soundEffects = {
            { authorId = "bell", label = "Bell", soundId = 111 },
        },
    })
    local record = { pack = "Voice", authorId = "bell", soundId = 12345 }
    self:mount(self:preset(record))
    self.fields[1].text = "99"
    self.fields[1].opts.onChange(self.fields[1])
    luaunit.assertEquals(self.combos[1].selectedID, 1)
end

function TestPresetVariableSound:testNoPackSoundsLeavesTheMessageInsteadOfADropdown()
    self:mount(self:preset(50))
    local sawMessage = false
    for _, text in ipairs(self.texts) do
        if text.content == "No pack sounds" then sawMessage = true end
    end
    luaunit.assertTrue(sawMessage)
    luaunit.assertEquals(#self.combos, 0)
    luaunit.assertEquals(#self.fields, 2)
end
