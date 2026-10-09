-- Plugin Hub surfaces.
-- SettingsLayerReady fills a status page: how to open Watchdog (the shell toggle,
-- F8) and whether chat and HTTP permission are granted. No per-alert settings
-- and no key-capture control.
-- ContentLayerReady registers one button, labeled Toggle, that performs the
-- shell toggle. The PrettyUI ribbon stays a separate entry point.
--
-- Neither event is in the stubs yet. The payload field is component: the page
-- parent the client passes in.

local SETTINGS_EVENT = "watchdog.settings_layer"
local CONTENT_EVENT = "watchdog.content_layer"

-- ui.Text draws nothing until rgb and rgba are set. Same packing as the
-- Alert Manager header labels (0xRRGGBBAA).
local TEXT_RGBA = 220 * 0x1000000 + 222 * 0x10000 + 230 * 0x100 + 255

local INTRO_Y = 12
local INTRO_H = 40
local STATUS_Y = 60
local STATUS_H = 24
local STATUS_GAP = 28
local INSET_X = 12
local BUTTON_H = 30

local HubLayers = {}

local settingsRoot = nil
local settingsParent = nil
local contentButton = nil
local contentParent = nil

local function granted(permission)
    return Plugin.HasPermission(permission) == true
end

local function permissionLine(name, permission)
    if granted(permission) then
        return name .. " permission: granted"
    end
    return name .. " permission: not granted"
end

-- The client may already have destroyed the previous page. A Lua error here
-- must not skip filling the new one; a dead component's Destroy is the case
-- that throws.
local function destroyOwned(node)
    if node == nil then return end
    pcall(function() node:Destroy() end)
end

local function addLine(parent, y, h, text, maxLines)
    local line = ui.Text.new(parent)
    line:SetPos(INSET_X, y)
    line:SetSize(-INSET_X * 2, h, 1)
    line.content = text
    line.font = id.Font.MUSEO_SANS_15PT_REGULAR
    line.maxLines = maxLines
    line.isShadowed = true
    line.clickthrough = true
    line.rgb = TEXT_RGBA
    line.rgba = TEXT_RGBA
    line.alignHorizontal = ui.AlignMode.TOPLEFT
    line.alignVertical = ui.AlignMode.CENTRE
end

---@param parent ui.ComponentCollection
local function fillSettings(parent)
    if settingsRoot ~= nil and settingsParent == parent then
        destroyOwned(settingsRoot)
    end
    settingsRoot = nil
    settingsParent = parent

    local root = ui.Layer.new(parent)
    root:SetSize(0, 0, 1, 1)
    settingsRoot = root

    addLine(root, INTRO_Y, INTRO_H, "Open Watchdog with the shell toggle (F8).", 2)
    addLine(root, STATUS_Y, STATUS_H, permissionLine("Chat", PluginPermissions.chatAccess), 1)
    addLine(root, STATUS_Y + STATUS_GAP, STATUS_H, permissionLine("HTTP", PluginPermissions.httpAccess), 1)
end

---@param parent ui.ComponentCollection
---@param onToggle fun()
local function fillContent(parent, onToggle)
    if contentButton ~= nil and contentParent == parent then
        destroyOwned(contentButton)
    end
    contentButton = nil
    contentParent = parent

    local button = ui.Button.new(parent)
    button:SetPos(INSET_X, INSET_X)
    button:SetSize(-INSET_X * 2, BUTTON_H, 1)
    button.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
    button.label = "Toggle"
    button:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
        onToggle()
    end)
    contentButton = button
end

---@param onToggle fun()
function HubLayers.Bind(onToggle)
    ---@diagnostic disable-next-line: undefined-field
    Event.SettingsLayerReady.Subscribe(SETTINGS_EVENT, function(event)
        if event == nil or event.component == nil then return end
        fillSettings(event.component)
    end)
    ---@diagnostic disable-next-line: undefined-field
    Event.ContentLayerReady.Subscribe(CONTENT_EVENT, function(event)
        if event == nil or event.component == nil then return end
        fillContent(event.component, onToggle)
    end)
end

function HubLayers.Unbind()
    ---@diagnostic disable-next-line: undefined-field
    Event.SettingsLayerReady.Unsubscribe(SETTINGS_EVENT)
    ---@diagnostic disable-next-line: undefined-field
    Event.ContentLayerReady.Unsubscribe(CONTENT_EVENT)
    settingsRoot = nil
    settingsParent = nil
    contentButton = nil
    contentParent = nil
end

-- Live re-exec only. PluginShutdown must not Destroy these; the client tears
-- the page down itself and crashes if they are already gone.
function HubLayers.Stop()
    destroyOwned(settingsRoot)
    destroyOwned(contentButton)
    HubLayers.Unbind()
end

return HubLayers
