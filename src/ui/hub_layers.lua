-- Plugin Hub surfaces.
-- SettingsLayerReady fills a status page: the shell key, the overlay lock, what
-- stays quiet in a restricted area, and whether chat and tracking permission
-- are granted. No per-alert settings.
-- ContentLayerReady registers one button, labeled Toggle, that performs the
-- shell toggle. While RestrictedAreas reports Restricted, a line under that
-- button reads "In Restricted Area" in red, with a description under it.
-- Otherwise the panel is only the button.
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
-- What Restricted means on this panel: those triggers stay quiet, the rest do not.
local RESTRICTED_DETAIL = "Spawn, game-message, and location triggers stay quiet. Other triggers still run."
-- Red, packed 0xRRGGBBAA like TEXT_RGBA. Only the restricted title uses it.
local RESTRICTED_RGBA = 255 * 0x1000000 + 48 * 0x10000 + 48 * 0x100 + 255
local RESTRICTED_DETAIL_H = 60

local SHELL_LABEL_Y = 12
local SHELL_FIELD_Y = 36
local SHELL_HINT_Y = 70
local SHELL_HINT_H = 40
local LOCK_Y = 114
local DETAIL_Y = 144
local DETAIL_H = 48
local STATUS_Y = 200
local STATUS_H = 24
local STATUS_GAP = 28
local INSET_X = 12
local BUTTON_H = 30
local FIELD_W = 240
local SHELL_KEY_DB = "watchdog_shell_key"
local LOCK_DB = "watchdog_position_lock"
local SHELL_HINT = "Clear the shell key to leave that key free. The content panel Toggle still opens Watchdog."

local HubLayers = {}

local settingsRoot = nil
local settingsParent = nil
local keybindField = nil
local lockBox = nil
local shellKeys = nil
local positionsLocked = false
local prefsLoaded = false
local contentButton = nil
local contentLine = nil
local contentDetail = nil
local contentParent = nil

local function copyKeys(keys)
    local out = {}
    if type(keys) ~= "table" then return out end
    for _, key in ipairs(keys) do
        if type(key) == "number" then
            out[#out + 1] = key
        end
    end
    return out
end

local function defaultShellKeys()
    if GameKey ~= nil and type(GameKey.F8) == "number" then
        return { GameKey.F8 }
    end
    return {}
end

local function readString(key)
    if PersistentDB == nil then return nil end
    local text
    local ok = pcall(function()
        text = PersistentDB:GetString(key)
    end)
    if ok and type(text) == "string" then return text end
    return nil
end

local function writeString(key, value)
    if PersistentDB == nil then return end
    pcall(function()
        PersistentDB:SetString(key, value)
    end)
end

-- Missing shell-key text means F8. A saved empty list means the shell key is off.
function HubLayers.LoadPrefs(force)
    if prefsLoaded and force ~= true then return end
    prefsLoaded = true
    shellKeys = defaultShellKeys()
    positionsLocked = false
    local text = readString(SHELL_KEY_DB)
    if text ~= nil and text ~= "" and LibNodeGraph ~= nil and LibNodeGraph.Json ~= nil then
        local ok, decoded = pcall(function()
            return LibNodeGraph.Json.Default.decode(text)
        end)
        if ok and type(decoded) == "table" then
            shellKeys = copyKeys(decoded)
        end
    end
    positionsLocked = readString(LOCK_DB) == "1"
end

function HubLayers.ShellKeys()
    HubLayers.LoadPrefs()
    return copyKeys(shellKeys)
end

function HubLayers.SetShellKeys(keys)
    HubLayers.LoadPrefs()
    shellKeys = copyKeys(keys)
    if LibNodeGraph == nil or LibNodeGraph.Json == nil then return end
    local ok, text = pcall(function()
        return LibNodeGraph.Json.Default.encode(shellKeys)
    end)
    if ok and type(text) == "string" then
        writeString(SHELL_KEY_DB, text)
    end
end

function HubLayers.PositionsLocked()
    HubLayers.LoadPrefs()
    return positionsLocked == true
end

function HubLayers.SetPositionsLocked(locked)
    HubLayers.LoadPrefs()
    positionsLocked = locked == true
    writeString(LOCK_DB, positionsLocked and "1" or "0")
end

local function releaseSettingsWidgets()
    if keybindField ~= nil and keybindField.Destroy ~= nil then
        pcall(function() keybindField:Destroy() end)
    end
    keybindField = nil
    if lockBox ~= nil and lockBox.Destroy ~= nil then
        pcall(function() lockBox:Destroy() end)
    end
    lockBox = nil
end

local function mountShellKey(root)
    if prettyui == nil or prettyui.KeybindField == nil then return end
    local defaultKeys = defaultShellKeys()
    local options = {
        x = INSET_X,
        y = SHELL_FIELD_Y,
        width = FIELD_W,
        value = HubLayers.ShellKeys(),
        onChange = function(_, value)
            HubLayers.SetShellKeys(value)
        end,
    }
    if #defaultKeys > 0 then
        options.defaultValue = defaultKeys
    end
    local ok, field = pcall(function()
        return prettyui.KeybindField.new(root, options)
    end)
    if ok then keybindField = field end
end

local function mountLock(root)
    if prettyui == nil or prettyui.CheckboxButton == nil then return end
    local ok, box = pcall(function()
        return prettyui.CheckboxButton.new(root, {
            { text = "Lock infobox and toasts", value = "lock", selected = HubLayers.PositionsLocked() },
        }, {
            x = INSET_X,
            y = LOCK_Y,
            width = FIELD_W,
            onChange = function(_, _, _, selected)
                HubLayers.SetPositionsLocked(selected == true)
            end,
        })
    end)
    if ok then lockBox = box end
end

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
    releaseSettingsWidgets()
    if settingsRoot ~= nil and settingsParent == parent then
        destroyOwned(settingsRoot)
    end
    settingsRoot = nil
    settingsParent = parent

    local root = ui.Layer.new(parent)
    root:SetSize(0, 0, 1, 1)
    settingsRoot = root

    addLine(root, SHELL_LABEL_Y, STATUS_H, "Shell key", 1)
    mountShellKey(root)
    local hint = addLine(root, SHELL_HINT_Y, SHELL_HINT_H, SHELL_HINT, 2)
    hint.alignVertical = ui.AlignMode.TOPLEFT
    mountLock(root)
    local detail = addLine(root, DETAIL_Y, DETAIL_H, RESTRICTED_DETAIL, 3)
    detail.alignVertical = ui.AlignMode.TOPLEFT
    addLine(root, STATUS_Y, STATUS_H, permissionLine("Chat", PluginPermissions.chatAccess), 1)
    addLine(root, STATUS_Y + STATUS_GAP, STATUS_H, permissionLine("Tracking", PluginPermissions.trackingAccess), 1)
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
    -- Cancel key capture without Destroy. Destroying the settings page here crashes.
    if keybindField ~= nil and keybindField.CancelListening ~= nil then
        pcall(function() keybindField:CancelListening() end)
    end
    keybindField = nil
    lockBox = nil
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
    releaseSettingsWidgets()
    destroyOwned(settingsRoot)
    destroyOwned(contentButton)
    destroyOwned(contentLine)
    destroyOwned(contentDetail)
    HubLayers.Unbind()
end

return HubLayers
