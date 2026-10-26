-- Plugin Hub surfaces.
-- SettingsLayerReady fills a status page: how to open Watchdog (the shell toggle,
-- F8) and whether chat and HTTP permission are granted. No per-alert settings
-- and no key-capture control.
-- ContentLayerReady registers one button, labeled Toggle, that performs the
-- shell toggle. While RestrictedAreas reports Restricted, a line under that
-- button reads "In Restricted Area" in red, with a description under it.
-- Otherwise the panel is only the button.
-- The PrettyUI ribbon stays a separate entry point.
--
-- Neither event is in the stubs yet. The payload field is component: the page
-- parent the client passes in.

local SETTINGS_EVENT = "watchdog.settings_layer"
local CONTENT_EVENT = "watchdog.content_layer"
local DEPENDENCY_EVENT = "watchdog.restricted_areas"
-- One Watchdog-owned name on RestrictedAreas. Named, so a later Subscribe replaces it.
local RESTRICTED_LISTENER = "watchdog.restricted"

-- ui.Text draws nothing until rgb and rgba are set. Same packing as the
-- Alert Manager header labels (0xRRGGBBAA).
local TEXT_RGBA = 220 * 0x1000000 + 222 * 0x10000 + 230 * 0x100 + 255
local RESTRICTED_LINE = "In Restricted Area"
-- What Restricted means on this panel: those two triggers stay quiet, the rest do not.
local RESTRICTED_DETAIL = "Spawn and game-message triggers stay quiet. Other triggers still run."
-- Red, packed 0xRRGGBBAA like TEXT_RGBA. Only the restricted title uses it.
local RESTRICTED_RGBA = 255 * 0x1000000 + 48 * 0x10000 + 48 * 0x100 + 255
local RESTRICTED_DETAIL_H = 60

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
local contentLine = nil
local contentDetail = nil
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
    return line
end

-- The title and description exist only while Restricted. A second true leaves
-- both widgets in place so walking between Restricted areas does not flicker them.
---@param restricted boolean
local function paintRestricted(restricted)
    if contentParent == nil then return end
    if restricted then
        if contentLine ~= nil and contentDetail ~= nil then
            contentLine.content = RESTRICTED_LINE
            contentLine.rgb = RESTRICTED_RGBA
            contentLine.rgba = RESTRICTED_RGBA
            contentDetail.content = RESTRICTED_DETAIL
            return
        end
        if contentLine ~= nil then
            destroyOwned(contentLine)
            contentLine = nil
        end
        if contentDetail ~= nil then
            destroyOwned(contentDetail)
            contentDetail = nil
        end
        local titleY = INSET_X + BUTTON_H + 4
        contentLine = addLine(contentParent, titleY, STATUS_H, RESTRICTED_LINE, 1)
        contentLine.rgb = RESTRICTED_RGBA
        contentLine.rgba = RESTRICTED_RGBA
        -- Top-aligned so the paragraph starts under the title instead of centering in its box.
        contentDetail = addLine(contentParent, titleY + STATUS_H + 2, RESTRICTED_DETAIL_H, RESTRICTED_DETAIL, 3)
        contentDetail.alignVertical = ui.AlignMode.TOPLEFT
        return
    end
    if contentLine ~= nil then
        destroyOwned(contentLine)
        contentLine = nil
    end
    if contentDetail ~= nil then
        destroyOwned(contentDetail)
        contentDetail = nil
    end
end

local function unsubscribeRestricted()
    pcall(function()
        RestrictedAreas.Unsubscribe(RESTRICTED_LISTENER)
    end)
end

---@param restricted boolean
local function onRestrictedChanged(restricted)
    paintRestricted(restricted == true)
end

local function syncRestricted()
    paintRestricted(RestrictedAreas.IsRestricted() == true)
    RestrictedAreas.Subscribe(RESTRICTED_LISTENER, onRestrictedChanged)
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
    addLine(root, STATUS_Y + STATUS_GAP, STATUS_H, permissionLine("Tracking", PluginPermissions.trackingAccess), 1)
    -- addLine(root, STATUS_Y + STATUS_GAP, STATUS_H, permissionLine("HTTP", PluginPermissions.httpAccess), 1)
end

---@param parent ui.ComponentCollection
---@param onToggle fun()
local function fillContent(parent, onToggle)
    if contentButton ~= nil and contentParent == parent then
        destroyOwned(contentButton)
    end
    if contentLine ~= nil and contentParent == parent then
        destroyOwned(contentLine)
    end
    if contentDetail ~= nil and contentParent == parent then
        destroyOwned(contentDetail)
    end
    contentButton = nil
    contentLine = nil
    contentDetail = nil
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
    -- IsRestricted() first: Subscribe does not replay the current answer.
    syncRestricted()
end

---@param onToggle fun()
function HubLayers.Bind(onToggle)
    Event.SettingsLayerReady.Subscribe(SETTINGS_EVENT, function(event)
        if event == nil or event.component == nil then return end
        fillSettings(event.component)
    end)
    Event.ContentLayerReady.Subscribe(CONTENT_EVENT, function(event)
        if event == nil or event.component == nil then return end
        fillContent(event.component, onToggle)
    end)
    -- Reload of an optional dependency swaps the global. Only the open panel
    -- follows it; a closed panel must not subscribe and keep that plugin ticking.
    Event.OptionalDependencyChanged.Subscribe(DEPENDENCY_EVENT, function(dep)
        if contentParent == nil then return end
        local kind = type(dep)
        if kind ~= "table" and kind ~= "userdata" then return end
        if dep.pluginIdentifier ~= "RestrictedAreas" then return end
        syncRestricted()
    end)
end

function HubLayers.Unbind()
    Event.SettingsLayerReady.Unsubscribe(SETTINGS_EVENT)
    Event.ContentLayerReady.Unsubscribe(CONTENT_EVENT)
    Event.OptionalDependencyChanged.Unsubscribe(DEPENDENCY_EVENT)
    -- Clear the parent before Unsubscribe so a callback cannot Destroy the
    -- line. PluginShutdown must not Destroy this page; the client does.
    contentParent = nil
    unsubscribeRestricted()
    settingsRoot = nil
    settingsParent = nil
    contentButton = nil
    contentLine = nil
    contentDetail = nil
end

-- Live re-exec only. PluginShutdown must not Destroy these; the client tears
-- the page down itself and crashes if they are already gone.
function HubLayers.Stop()
    destroyOwned(settingsRoot)
    destroyOwned(contentButton)
    destroyOwned(contentLine)
    destroyOwned(contentDetail)
    HubLayers.Unbind()
end

return HubLayers
