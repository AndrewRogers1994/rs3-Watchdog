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
local Presets = require("src/presets")
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

local function newFakePersistentDB()
    local db = { data = {} }
    function db:GetString(key) return self.data[key] end
    function db:SetString(key, value) self.data[key] = value end
    return db
end

local function live(widgets)
    local out = {}
    for _, widget in ipairs(widgets) do
        if not widget.destroyed then out[#out + 1] = widget end
    end
    return out
end

local function labels(widgets)
    local out = {}
    for i, widget in ipairs(widgets) do
        out[i] = widget.label or widget.content
    end
    return out
end

TestNewAlertDialog = {}

function TestNewAlertDialog:setUp()
    self.saved = {
        ui = _G.ui,
        prettyui = _G.prettyui,
        Vector4 = _G.Vector4,
        PersistentDB = _G.PersistentDB,
    }
    self.packs = Packs.new()
    Packs.install(self.packs)
    PersistentDB = newFakePersistentDB()
    self.parent = { height = 800 }
    self.windows = {}
    self.rows = {}
    self.sprites = {}
    self.rowTexts = {}
    local windows, rows, sprites, rowTexts = self.windows, self.rows, self.sprites, self.rowTexts
    local body = {}
    function body:AddText(text)
        local widget = { content = text }
        function widget:Destroy() self.destroyed = true end
        rowTexts[#rowTexts + 1] = widget
        return widget
    end
    function body:AddTextField(opts)
        local field = { text = opts and opts.text or "" }
        function field:GetText() return self.text end
        function field:SetText(value) self.text = tostring(value or "") end
        function field:Destroy() self.destroyed = true end
        return field
    end
    function body:AddComboBox()
        return { Destroy = function() end }
    end
    function body:AddSimpleButton(label, action, opts)
        local widget = { label = label, action = action, opts = opts }
        function widget:Destroy() self.destroyed = true end
        rows[#rows + 1] = widget
        return widget
    end
    function body:AddSpriteButton(sprite, action, opts)
        local widget = { sprite = sprite, action = action, opts = opts }
        function widget:Destroy() self.destroyed = true end
        sprites[#sprites + 1] = widget
        return widget
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
                    buttons = {},
                    fields = {},
                }
                function win:SetScrollable() end
                function win:Show() end
                function win:MoveToFront() end
                function win:AddText(text)
                    local widget = { content = text }
                    function widget:Destroy() self.destroyed = true end
                    return widget
                end
                function win:AddTextField(opts)
                    local field = { text = opts and opts.text or "" }
                    function field:GetText() return self.text end
                    function field:SetText(value) self.text = tostring(value or "") end
                    self.fields[#self.fields + 1] = field
                    return field
                end
                function win:AddFancyButton(label, action)
                    local button = { label = label, action = action }
                    function button:SetDisabled(disabled) self.disabled = disabled == true end
                    self.buttons[#self.buttons + 1] = button
                    return button
                end
                function win:Destroy() self.destroyed = true end
                windows[#windows + 1] = win
                return win
            end,
        },
        SimpleView = { new = function() return body end },
    }
    self.registry = Registry.new()
    self.registry:RegisterNodeType("fixture.hold", {
        category = "action",
        pins = {
            { name = "hold", kind = "data", direction = "in", dataType = "number", default = 4 },
        },
        run = function() end,
    })
end

function TestNewAlertDialog:tearDown()
    Dialog.dismissAll(self.parent)
    Packs.install(nil)
    _G.ui = self.saved.ui
    _G.prettyui = self.saved.prettyui
    _G.Vector4 = self.saved.Vector4
    _G.PersistentDB = self.saved.PersistentDB
end

function TestNewAlertDialog:button(win, label)
    for _, button in ipairs(win.buttons) do
        if button.label == label then return button end
    end
    error("missing button " .. label)
end

function TestNewAlertDialog:row(label)
    for _, row in ipairs(live(self.rows)) do
        if row.label == label then return row end
    end
    error("missing row " .. label)
end

function TestNewAlertDialog:testFromScratchReportsOpen()
    local opened
    PresetDialogs.mountNewAlert(self.parent, {
        onFromScratch = function()
            return { kind = "open", scopeKey = "global", alertId = 4 }, 4
        end,
        onCreated = function(result) opened = result end,
    })
    self:button(self.windows[1], "From scratch").action()
    luaunit.assertEquals(opened.kind, "open")
    luaunit.assertEquals(opened.scopeKey, "global")
    luaunit.assertEquals(opened.alertId, 4)
end

function TestNewAlertDialog:testEmptyLibrarySaysThereAreNoPresets()
    PresetDialogs.mountNewAlert(self.parent, {})
    luaunit.assertEquals(labels(live(self.rowTexts)), { "There are no presets.", "" })
end

function TestNewAlertDialog:testPackRowsStayInAlertPresetGroupOrderAndIgnoreALaterRegistration()
    self.packs:RegisterDataPack("Mango", {
        alertPresets = {
            { authorId = "z", name = "Zulu", graph = {} },
            { authorId = "b", name = "Bravo", graph = {} },
        },
    })
    self.packs:RegisterDataPack("Alpha", {
        alertPresets = {
            { authorId = "a", name = "Able", graph = {} },
        },
    })
    PresetDialogs.mountNewAlert(self.parent, {})
    luaunit.assertEquals(labels(live(self.rows)), { "Able", "Bravo", "Zulu" })
    luaunit.assertEquals(labels(live(self.rowTexts)), { "Alpha", "Mango", "" })

    self.packs:RegisterDataPack("Later", {
        alertPresets = {
            { authorId = "n", name = "Newcomer", graph = {} },
        },
    })
    luaunit.assertEquals(labels(live(self.rows)), { "Able", "Bravo", "Zulu" })
    luaunit.assertNil(self:findText("Later"))
    luaunit.assertNil(self:findText("Newcomer"))
end

function TestNewAlertDialog:findText(content)
    for _, widget in ipairs(live(self.rowTexts)) do
        if widget.content == content then return widget end
    end
    return nil
end

function TestNewAlertDialog:testVariablePresetDoesNotCreateUntilAnswersExist()
    local graph = LibNodeGraph.NewGraph(self.registry)
    local nodeId = graph:AddNode("fixture.hold", { hold = 4 })
    local preset, err = Presets.Add("Callout", graph, {}, {
        { nodeId = nodeId, pinName = "hold" },
    })
    luaunit.assertNotNil(preset, err)
    local calls = 0
    PresetDialogs.mountNewAlert(self.parent, {
        registry = self.registry,
        onFromPreset = function()
            calls = calls + 1
            return { kind = "open", scopeKey = "global", alertId = 1 }, 1, nil
        end,
    })
    self:row("Callout").action()
    luaunit.assertEquals(calls, 0)
    luaunit.assertEquals(self.windows[2].title, "Callout")
end

function TestNewAlertDialog:testRenameAndDeleteRefreshTheLibraryRow()
    local graph = LibNodeGraph.NewGraph(self.registry)
    graph:AddNode("fixture.hold", { hold = 1 })
    local preset, err = Presets.Add("Siren", graph, {})
    luaunit.assertNotNil(preset, err)
    PresetDialogs.mountNewAlert(self.parent, {})

    live(self.sprites)[1].action()
    local rename = self.windows[2]
    luaunit.assertEquals(rename.title, "Rename preset")
    rename.fields[1].text = "Horn"
    self:button(rename, "Rename").action()
    luaunit.assertEquals(labels(live(self.rows)), { "Horn" })

    local trash
    for _, sprite in ipairs(live(self.sprites)) do
        if sprite.sprite == "TRASH" then trash = sprite end
    end
    trash.action()
    local confirm = self.windows[3]
    luaunit.assertEquals(confirm.title, "CONFIRM DELETE")
    self:button(confirm, "DELETE").action()
    luaunit.assertEquals(labels(live(self.rows)), {})
    luaunit.assertEquals(self:findText("There are no presets.").content, "There are no presets.")
end

-- Save as preset, through the same front door the Editor calls.
TestSavePresetDialog = {}

function TestSavePresetDialog:setUp()
    self.saved = {
        ui = _G.ui,
        prettyui = _G.prettyui,
        Vector4 = _G.Vector4,
    }
    self.packs = Packs.new()
    Packs.install(self.packs)
    self.parent = { height = 800 }
    self.windows = {}
    self.texts = {}
    self.rows = {}
    local windows, texts, rows = self.windows, self.texts, self.rows
    local body = {}
    function body:AddText(text)
        local widget = { content = text }
        texts[#texts + 1] = widget
        return widget
    end
    function body:AddTextField(opts)
        local field = { text = opts and opts.text or "" }
        function field:GetText() return self.text end
        function field:SetText(value) self.text = tostring(value or "") end
        return field
    end
    function body:AddSimpleButton(label, action)
        local widget = { label = label, action = action }
        rows[#rows + 1] = widget
        return widget
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
                    buttons = {},
                }
                function win:SetScrollable() end
                function win:Show() end
                function win:MoveToFront() end
                function win:AddFancyButton(label, action)
                    local button = { label = label, action = action }
                    function button:SetDisabled(disabled) self.disabled = disabled == true end
                    self.buttons[#self.buttons + 1] = button
                    return button
                end
                function win:Destroy() self.destroyed = true end
                windows[#windows + 1] = win
                return win
            end,
        },
        SimpleView = { new = function() return body end },
    }
    self.registry = Registry.new()
    self.registry:RegisterNodeType("fixture.hold", {
        category = "action",
        displayName = "Hold",
        pins = {
            { name = "hold", kind = "data", direction = "in", dataType = "number", default = 4 },
        },
        run = function() end,
    })
end

function TestSavePresetDialog:tearDown()
    Dialog.dismissAll(self.parent)
    Packs.install(nil)
    _G.ui = self.saved.ui
    _G.prettyui = self.saved.prettyui
    _G.Vector4 = self.saved.Vector4
end

function TestSavePresetDialog:openWindow()
    local open
    for _, win in ipairs(self.windows) do
        if not win.destroyed then open = win end
    end
    if open == nil then error("no open dialog") end
    return open
end

function TestSavePresetDialog:button(win, label)
    for _, button in ipairs(win.buttons) do
        if button.label == label then return button end
    end
    error("missing button " .. label)
end

function TestSavePresetDialog:row(label)
    for _, row in ipairs(self.rows) do
        if row.label == label then return row end
    end
    error("missing row " .. label)
end

function TestSavePresetDialog:findText(content)
    for _, widget in ipairs(self.texts) do
        if widget.content == content then return widget end
    end
    return nil
end

function TestSavePresetDialog:holdGraph()
    local graph = LibNodeGraph.NewGraph(self.registry)
    local nodeId = graph:AddNode("fixture.hold", { hold = 4 })
    return graph, nodeId
end

function TestSavePresetDialog:testABlankNameDoesNotCallSave()
    local graph = LibNodeGraph.NewGraph(self.registry)
    local calls = 0
    PresetDialogs.mountSave(self.parent, {
        graph = graph,
        initialName = "",
        onSave = function()
            calls = calls + 1
            return { id = 1 }
        end,
    })
    local win = self:openWindow()
    self:button(win, "Save").action()
    luaunit.assertEquals(calls, 0)
    luaunit.assertNil(win.destroyed)
    luaunit.assertEquals(win.title, "Save as preset")
end

function TestSavePresetDialog:testANameAndNoMarksSavesWithNoVariableList()
    local graph = self:holdGraph()
    local savedName, savedMarks
    PresetDialogs.mountSave(self.parent, {
        graph = graph,
        initialName = "Siren",
        onSave = function(name, marks)
            savedName, savedMarks = name, marks
            return { id = 1 }
        end,
    })
    self:button(self:openWindow(), "Save").action()
    luaunit.assertEquals(savedName, "Siren")
    luaunit.assertNil(savedMarks)
end

function TestSavePresetDialog:testANameAndOneMarkSavesThatMark()
    local graph, nodeId = self:holdGraph()
    local savedName, savedMarks
    PresetDialogs.mountSave(self.parent, {
        graph = graph,
        initialName = "Siren",
        onSave = function(name, marks)
            savedName, savedMarks = name, marks
            return { id = 1 }
        end,
    })
    self:row("Mark Variable").action()
    self:row("Hold - New Hold").action()
    self:row("hold").action()
    self:button(self:openWindow(), "Save").action()
    luaunit.assertEquals(savedName, "Siren")
    luaunit.assertEquals(savedMarks, { { nodeId = nodeId, pinName = "hold" } })
end

function TestSavePresetDialog:testARefusedSaveLeavesTheDialogOpenAndShowsTheReason()
    local graph = self:holdGraph()
    local calls = 0
    PresetDialogs.mountSave(self.parent, {
        graph = graph,
        initialName = "Siren",
        onSave = function()
            calls = calls + 1
            return nil, "Could not copy the graph."
        end,
    })
    local win = self:openWindow()
    self:button(win, "Save").action()
    luaunit.assertEquals(calls, 1)
    luaunit.assertNil(win.destroyed)
    luaunit.assertEquals(win.title, "Save as preset")
    luaunit.assertEquals(self:findText("Could not copy the graph.").content, "Could not copy the graph.")
end
