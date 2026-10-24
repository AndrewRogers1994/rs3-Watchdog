-- Alert Manager mutations and the Editor's Bucket writes.
--
-- main.lua passes the Store and the runtime in. This module does not read them
-- back out of main, and it does not show, hide, or rename the Editor. Each
-- operation returns one of four results; main applies that result:
--   { kind = "open", scopeKey = ..., alertId = ... }  open the Editor on this Alert
--   { kind = "close" }                                 close the Editor
--   { kind = "rename", name = ... }                   the open Alert has a new name
--   { kind = "leave" }                                 leave the Editor as it is
--
-- The open Alert (id + Scope key, plus its graph and Layout when a write must
-- land before the Entry moves or disappears) is passed in by the caller. This
-- module never calls navBack.

local Export = require("src/export")
local Presets = require("src/presets")
local PresetCopy = require("src/preset_copy")
local Packs = require("src/packs")
local PackRows = require("src/pack_rows")
local Dialog = require("src/ui/dialog")
local PresetDialogs = require("src/ui/preset_dialogs")
local Confirm = require("src/ui/confirm")
local Theme = require("src/ui/theme")

---@class Watchdog.EditorResult
---@field kind "open"|"close"|"rename"|"leave"
---@field scopeKey string|nil
---@field alertId integer|nil
---@field name string|nil

---@class Watchdog.ScopeEdits
---@field store table
---@field runtime table
---@field registry LibNodeGraph.Registry|nil
---@field lookup (fun(scopeKey: string): Watchdog.Bucket|nil, string|nil, Watchdog.RestoredAlert[]|nil)|nil
---@field _savedEncode string|nil
local ScopeEdits = {}
ScopeEdits.__index = ScopeEdits

local function leave()
    return { kind = "leave" }
end

---@param entry Watchdog.Entry
---@return Watchdog.Entry
local function cloneEntry(entry)
    local copy = {
        id = entry.id,
        kind = entry.kind,
        name = entry.name,
        enabled = entry.enabled,
        graph = entry.graph,
        layout = entry.layout,
    }
    if entry.children ~= nil then
        copy.children = {}
        for i, child in ipairs(entry.children) do
            copy.children[i] = cloneEntry(child)
        end
    end
    return copy
end

-- The paste dialog reads this key back. It is not a Bucket.
---@param kind string
---@param ok boolean
---@param detail string
local function mirrorTransfer(kind, ok, detail)
    pcall(function()
        if PersistentDB == nil then return end
        PersistentDB:SetString("transfer_last", string.format(
            "%s\tok=%s\t%s", kind, tostring(ok), tostring(detail):sub(1, 500)))
    end)
end

---@param list Watchdog.RestoredAlert[]
---@param ids integer[]
local function purgeAlertList(list, ids)
    local drop = {}
    for _, id in ipairs(ids) do drop[id] = true end
    for i = #list, 1, -1 do
        if drop[list[i].id] then table.remove(list, i) end
    end
end

---@param entry Watchdog.Entry
---@param targetId integer
---@return boolean
local function subtreeContains(entry, targetId)
    if entry.id == targetId then return true end
    for _, child in ipairs(entry.children or {}) do
        if subtreeContains(child, targetId) then return true end
    end
    return false
end

---@param entry Watchdog.Entry
---@param out integer[]
local function collectAlertIds(entry, out)
    if entry.kind == "alert" then
        out[#out + 1] = entry.id
    else
        for _, child in ipairs(entry.children or {}) do
            collectAlertIds(child, out)
        end
    end
end

---@param deps { store: table, runtime: table, registry: LibNodeGraph.Registry|nil, bucket: fun(scopeKey: string): Watchdog.Bucket|nil, string|nil, Watchdog.RestoredAlert[]|nil }
---@return Watchdog.ScopeEdits
function ScopeEdits.new(deps)
    return setmetatable({
        store = deps.store,
        runtime = deps.runtime,
        registry = deps.registry,
        lookup = deps.bucket,
        _savedEncode = nil,
    }, ScopeEdits)
end

---@param scopeKey string
---@return Watchdog.Bucket|nil doc
---@return string|nil key
---@return Watchdog.RestoredAlert[]|nil list
function ScopeEdits:_bucket(scopeKey)
    if self.lookup == nil then return nil end
    return self.lookup(scopeKey)
end

-- Flips one Entry. A disabled Group does not flip child alert.enabled; firing
-- stops through the ancestor check, so this only releases visuals those children
-- already spawned. An Alert's own flag is what the runtime reads.
---@param scopeKey string
---@param id integer
---@return Watchdog.EditorResult
function ScopeEdits:ToggleEnabled(scopeKey, id)
    local doc, key = self:_bucket(scopeKey)
    if doc == nil or key == nil then return leave() end
    local entry = self.store.FindById(doc, id)
    if entry == nil then return leave() end
    local nextEnabled = not (entry.enabled ~= false)
    self.store.SetEnabled(doc, id, nextEnabled)
    self.store.SaveTo(key, doc)
    if entry.kind == "alert" then
        self.runtime:SetAlertEnabled(id, nextEnabled, key)
        local _, _, list = self:_bucket(scopeKey)
        if list ~= nil then
            for _, alert in ipairs(list) do
                if alert.id == id then alert.enabled = nextEnabled end
            end
        end
    elseif not nextEnabled then
        local alertIds = {}
        collectAlertIds(entry, alertIds)
        for _, alertId in ipairs(alertIds) do
            self.runtime:ReleaseAlertVisuals(alertId, key)
        end
    end
    return leave()
end

-- A failed save puts the previous name back so the Bucket and the runtime stay
-- on the last name that actually persisted. The Editor title changes only when
-- the renamed id is the open Alert; that decision is the returned result.
---@param scopeKey string
---@param id integer
---@param name string
---@param open { alertId: integer, scopeKey: string }|nil
---@return Watchdog.EditorResult
---@return boolean ok
function ScopeEdits:Rename(scopeKey, id, name, open)
    local doc, key, list = self:_bucket(scopeKey)
    if doc == nil or key == nil then return leave(), false end
    local entryBefore = self.store.FindById(doc, id)
    local oldName = entryBefore and entryBefore.name
    if not self.store.SetName(doc, id, name) then return leave(), false end
    if not self.store.SaveTo(key, doc) then
        self.store.SetName(doc, id, oldName)
        return leave(), false
    end
    local entry = self.store.FindById(doc, id)
    if entry ~= nil and entry.kind == "alert" then
        self.runtime:RenameAlert(id, name, key)
        if list ~= nil then
            for _, alert in ipairs(list) do
                if alert.id == id then alert.name = name end
            end
        end
    end
    if open ~= nil and open.alertId == id and open.scopeKey == key then
        return { kind = "rename", name = name }, true
    end
    return leave(), true
end

---@param scopeKey string
---@param id integer
---@param open { alertId: integer, scopeKey: string }|nil
---@return Watchdog.EditorResult
function ScopeEdits:Delete(scopeKey, id, open)
    local doc, key, list = self:_bucket(scopeKey)
    if doc == nil or key == nil then return leave() end
    local entry = self.store.FindById(doc, id)
    if entry == nil then return leave() end
    local alertIds = {}
    collectAlertIds(entry, alertIds)
    local closing = self:_closing(entry, key, open)
    if closing then self:_flushOpen(open) end
    self.store.DeleteById(doc, id)
    self.store.SaveTo(key, doc)
    for _, alertId in ipairs(alertIds) do
        self.runtime:ReleaseAlertVisuals(alertId, key)
        self.runtime:RemoveAlert(alertId, key)
    end
    if list ~= nil then purgeAlertList(list, alertIds) end
    if closing then return { kind = "close" } end
    return leave()
end

---@param list Watchdog.RestoredAlert[]|nil
---@param id integer
---@param name string
---@param graph LibNodeGraph.Graph
---@param layout Watchdog.Layout
local function rememberAlert(list, id, name, graph, layout)
    if list == nil then return end
    list[#list + 1] = { id = id, name = name, graph = graph, layout = layout, enabled = true }
end

local function openEditor(scopeKey, alertId)
    return { kind = "open", scopeKey = scopeKey, alertId = alertId }
end

-- Empty graph, enabled, named "New Alert". Does not read the Preset library.
---@param scopeKey string
---@return Watchdog.EditorResult
---@return integer|nil id
function ScopeEdits:CreateFromScratch(scopeKey)
    local doc, key, list = self:_bucket(scopeKey)
    if doc == nil or key == nil then return leave(), nil end
    local graph = LibNodeGraph.NewGraph(self.registry)
    local layout = {}
    local id = self.store.MintId(doc)
    local name = "New Alert"
    self.store.InsertEntry(doc, self.store.NewAlertEntry(id, name, graph, layout, true))
    self.store.SaveTo(key, doc)
    rememberAlert(list, id, name, graph, layout)
    self.runtime:AddAlert(id, name, graph, true, key, self.store.FindById(doc, id))
    return openEditor(scopeKey, id), id
end

-- Records the Bucket's encoded text when the Editor opens, so a later autosave
-- can tell an untouched graph from a real edit. One open Alert at a time.
---@param scopeKey string
function ScopeEdits:NoteSaved(scopeKey)
    local doc = self:_bucket(scopeKey)
    if doc == nil then
        self._savedEncode = nil
        return
    end
    self._savedEncode = self.store.Encode(doc)
end

-- Writes the open Alert's graph and Layout into its Bucket, and saves only when
-- that encoding differs from the last successful save. Hiding the shell and
-- shutdown both call this; the caller decides when.
---@param scopeKey string
---@param alertId integer
---@param graph LibNodeGraph.Graph
---@param layout Watchdog.Layout|nil
---@return Watchdog.EditorResult
function ScopeEdits:Autosave(scopeKey, alertId, graph, layout)
    if scopeKey == nil or alertId == nil or graph == nil then return leave() end
    local doc, key = self:_bucket(scopeKey)
    if doc == nil or key == nil then return leave() end
    self.store.UpdateAlertGraph(doc, alertId, graph, layout)
    local encoded = self.store.Encode(doc)
    if encoded ~= nil and encoded ~= self._savedEncode then
        if self.store.SaveTo(key, doc) then
            self._savedEncode = encoded
        end
    end
    return leave()
end

---@param scopeKey string
---@param id integer
---@param delta integer
---@return Watchdog.EditorResult
function ScopeEdits:ReorderSibling(scopeKey, id, delta)
    local doc, key = self:_bucket(scopeKey)
    if doc == nil or key == nil then return leave() end
    if not self.store.ReorderSibling(doc, id, delta) then return leave() end
    self.store.SaveTo(key, doc)
    return leave()
end

---@param scopeKey string
---@param id integer
---@return Watchdog.EditorResult
function ScopeEdits:Lift(scopeKey, id)
    local doc, key = self:_bucket(scopeKey)
    if doc == nil or key == nil then return leave() end
    if not self.store.LiftEntry(doc, id) then return leave() end
    self.store.SaveTo(key, doc)
    return leave()
end

---@param scopeKey string
---@return Watchdog.EditorResult
---@return integer|nil id
function ScopeEdits:CreateGroup(scopeKey)
    local doc, key = self:_bucket(scopeKey)
    if doc == nil or key == nil then return leave(), nil end
    local id = self.store.MintId(doc)
    self.store.InsertEntry(doc, self.store.NewGroupEntry(id, "New Group", true, {}))
    self.store.SaveTo(key, doc)
    return leave(), id
end

---@param entry Watchdog.Entry|nil
---@param key string
---@param open { alertId: integer, scopeKey: string, graph: LibNodeGraph.Graph|nil, layout: Watchdog.Layout|nil }|nil
---@return boolean
function ScopeEdits:_closing(entry, key, open)
    if entry == nil or open == nil or open.alertId == nil or open.scopeKey ~= key then
        return false
    end
    return subtreeContains(entry, open.alertId)
end

-- The Editor's unsaved graph has to land on the Entry before that Entry is
-- deleted or moved. main closes the Editor afterwards and must not navBack here.
---@param open { alertId: integer, scopeKey: string, graph: LibNodeGraph.Graph|nil, layout: Watchdog.Layout|nil }|nil
function ScopeEdits:_flushOpen(open)
    if open == nil or open.graph == nil or open.alertId == nil or open.scopeKey == nil then return end
    self:Autosave(open.scopeKey, open.alertId, open.graph, open.layout)
end

---@param scopeKey string
---@param ids integer[]
---@param open { alertId: integer, scopeKey: string, graph: LibNodeGraph.Graph|nil, layout: Watchdog.Layout|nil }|nil
---@return Watchdog.EditorResult
function ScopeEdits:BulkDelete(scopeKey, ids, open)
    local doc, key, list = self:_bucket(scopeKey)
    if doc == nil or key == nil or ids == nil then return leave() end
    local closing = false
    for _, id in ipairs(ids) do
        local entry = self.store.FindById(doc, id)
        if entry ~= nil then
            local alertIds = {}
            collectAlertIds(entry, alertIds)
            if self:_closing(entry, key, open) then
                if not closing then self:_flushOpen(open) end
                closing = true
            end
            self.store.DeleteById(doc, id)
            for _, alertId in ipairs(alertIds) do
                self.runtime:ReleaseAlertVisuals(alertId, key)
                self.runtime:RemoveAlert(alertId, key)
            end
            if list ~= nil then purgeAlertList(list, alertIds) end
        end
    end
    self.store.SaveTo(key, doc)
    if closing then return { kind = "close" } end
    return leave()
end

---@param scopeKey string
---@param ids integer[]
---@return Watchdog.EditorResult
---@return integer|nil id
function ScopeEdits:BulkNewGroup(scopeKey, ids)
    local doc, key = self:_bucket(scopeKey)
    if doc == nil or key == nil or ids == nil or #ids == 0 then return leave(), nil end
    local newId = self.store.GroupSelected(doc, ids, "New Group")
    if newId == nil then return leave(), nil end
    self.store.SaveTo(key, doc)
    return leave(), newId
end

---@param scopeKey string
---@param destScopeKey string
---@param ids integer[]
---@param open { alertId: integer, scopeKey: string, graph: LibNodeGraph.Graph|nil, layout: Watchdog.Layout|nil }|nil
---@return Watchdog.EditorResult
function ScopeEdits:BulkMove(scopeKey, destScopeKey, ids, open)
    local srcDoc, srcKey, srcList = self:_bucket(scopeKey)
    local destDoc, destKey, destList = self:_bucket(destScopeKey)
    if srcDoc == nil or destDoc == nil or srcKey == nil or destKey == nil or ids == nil then
        return leave()
    end
    local closing = false
    for _, id in ipairs(ids) do
        local before = self.store.FindById(srcDoc, id)
        if before ~= nil then
            local alertIds = {}
            collectAlertIds(before, alertIds)
            local snapshots = {}
            if srcList ~= nil then
                for _, alertId in ipairs(alertIds) do
                    for _, alert in ipairs(srcList) do
                        if alert.id == alertId then
                            snapshots[#snapshots + 1] = alert
                            break
                        end
                    end
                end
            end
            if self:_closing(before, srcKey, open) then
                if not closing then self:_flushOpen(open) end
                closing = true
            end
            local moved = self.store.MoveEntryToBucket(srcDoc, destDoc, id)
            if moved ~= nil then
                if srcList ~= nil then purgeAlertList(srcList, alertIds) end
                local leaves = {}
                local function collectLeaves(entry)
                    if entry.kind == "alert" then
                        leaves[#leaves + 1] = entry
                    else
                        for _, child in ipairs(entry.children or {}) do collectLeaves(child) end
                    end
                end
                collectLeaves(moved)
                for i, leaf in ipairs(leaves) do
                    local snap = snapshots[i]
                    if snap ~= nil then
                        self.runtime:RemoveAlert(snap.id, srcKey)
                        if destList ~= nil then
                            destList[#destList + 1] = {
                                id = leaf.id,
                                name = snap.name,
                                graph = snap.graph,
                                layout = snap.layout,
                                enabled = snap.enabled,
                            }
                        end
                        self.runtime:AddAlert(leaf.id, snap.name, snap.graph, snap.enabled ~= false, destKey, leaf)
                    end
                end
            end
        end
    end
    self.store.SaveTo(srcKey, srcDoc)
    self.store.SaveTo(destKey, destDoc)
    if closing then return { kind = "close" } end
    return leave()
end

---@param scopeKey string
---@param ids integer[]|nil
---@return Watchdog.EditorResult
---@return boolean ok
---@return string jsonOrErr
function ScopeEdits:ExportEntries(scopeKey, ids)
    local doc = self:_bucket(scopeKey)
    if doc == nil then return leave(), false, "no active scope" end
    local entries = {}
    if ids == nil then
        for _, entry in ipairs(doc.entries or {}) do
            entries[#entries + 1] = cloneEntry(entry)
        end
    else
        for _, id in ipairs(ids) do
            local entry = self.store.FindById(doc, id)
            if entry ~= nil then entries[#entries + 1] = cloneEntry(entry) end
        end
    end
    local ok, result = Export.Encode(entries)
    if ok then
        mirrorTransfer("export", true, string.format("%d bytes / %d entries", #result, #entries))
    else
        mirrorTransfer("export", false, result)
    end
    return leave(), ok, result
end

---@param scopeKey string
---@param text string
---@return Watchdog.EditorResult
---@return boolean ok
---@return Watchdog.ImportReport|string
function ScopeEdits:ImportJson(scopeKey, text)
    local doc, key, list = self:_bucket(scopeKey)
    if doc == nil or key == nil then return leave(), false, "no active scope" end
    local before = {}
    for _, leaf in ipairs(self.store.Leaves(doc)) do
        before[leaf.id] = true
    end
    local ok, report = Export.Import(doc, text, { registry = self.registry })
    if not ok then
        mirrorTransfer("import", false, tostring(report))
        return leave(), false, report
    end
    self.store.SaveTo(key, doc)
    local newLeaves = {}
    for _, leaf in ipairs(self.store.Leaves(doc)) do
        if not before[leaf.id] then
            newLeaves[#newLeaves + 1] = leaf
        end
    end
    if #newLeaves > 0 then
        local temp = self.store.Empty()
        temp.entries = newLeaves
        local restored = self.store.RestoreAll(temp, self.registry)
        for _, alert in ipairs(restored) do
            if list ~= nil then
                list[#list + 1] = alert
            end
            self.runtime:AddAlert(alert.id, alert.name, alert.graph, alert.enabled ~= false, key, self.store.FindById(doc, alert.id))
        end
    end
    local msg = (type(report) == "table" and report.message) or "ok"
    mirrorTransfer("import", true, msg)
    return leave(), true, report
end

-- Saves and arms the Alert the instantiate call inserted. A failed copy or a
-- failed bake returns the error and leaves the Bucket as that call left it.
---@param scopeKey string
---@param doc Watchdog.Bucket
---@param key string
---@param list Watchdog.RestoredAlert[]|nil
---@param entry Watchdog.Entry|nil
---@param graph LibNodeGraph.Graph|nil
---@param layout Watchdog.Layout|nil
---@param err string|nil
---@return Watchdog.EditorResult
---@return integer|nil id
---@return string|nil err
function ScopeEdits:_finishCreate(scopeKey, doc, key, list, entry, graph, layout, err)
    if entry == nil or graph == nil or layout == nil then
        return leave(), nil, err
    end
    self.store.SaveTo(key, doc)
    rememberAlert(list, entry.id, entry.name, graph, layout)
    self.runtime:AddAlert(entry.id, entry.name, graph, true, key, entry)
    return openEditor(scopeKey, entry.id), entry.id, nil
end

---@param scopeKey string
---@param presetId integer
---@param answers any[]|nil
---@return Watchdog.EditorResult
---@return integer|nil id
---@return string|nil err
function ScopeEdits:CreateFromPreset(scopeKey, presetId, answers)
    local doc, key, list = self:_bucket(scopeKey)
    if doc == nil or key == nil then return leave(), nil, "No scope to create the alert in." end
    return self:_finishCreate(scopeKey, doc, key, list, PresetCopy.Instantiate(doc, presetId, self.registry, answers))
end

-- Same save and arm as a library Preset. The registry does not save the Bucket,
-- and the copy does not keep the author id.
---@param scopeKey string
---@param snapshot Watchdog.PackAlertPreset
---@param answers any[]|nil
---@return Watchdog.EditorResult
---@return integer|nil id
---@return string|nil err
function ScopeEdits:CreateFromAlertPreset(scopeKey, snapshot, answers)
    local doc, key, list = self:_bucket(scopeKey)
    if doc == nil or key == nil then return leave(), nil, "No scope to create the alert in." end
    return self:_finishCreate(scopeKey, doc, key, list, PresetCopy.InstantiateSnapshot(doc, snapshot, self.registry, answers))
end

---@param preset Watchdog.Preset|Watchdog.PackAlertPreset
---@return boolean
local function presetHasVariables(preset)
    return type(preset.variables) == "table" and #preset.variables > 0
end

-- The New alert Dialog. It calls the Variable Dialog for a Preset that has
-- Variables; it does not decide Sound Effect answers itself. `apply` is how
-- main opens the Editor after a create. This dialog does not show the Editor.
---@param parent any
---@param scopeKey string
---@param apply fun(result: Watchdog.EditorResult)|nil
---@return nil
function ScopeEdits:MountNewAlert(parent, scopeKey, apply)
    if parent == nil then return nil end
    local feedback
    local body = {}
    local alertWin
    local fillList, beginRename, beginDelete

    -- Captured at this open. A later registration does not rebuild an open dialog.
    -- Rename and delete call fillList again and still use this list.
    local offered = {}
    local livePacks = Packs.live()
    if livePacks ~= nil then
        offered = PackRows.AlertPresetGroups(livePacks)
    end

    local function deliver(result, id, err)
        if id ~= nil and apply ~= nil then apply(result) end
        return id, err
    end

    -- PrettyUI flow padding (14) and column gap (8). The name fills the row;
    -- the pencil and trash sit inline after it, the same sprites as the Manager.
    local FLOW_PAD = 14
    local FLOW_GAP = 8

    local function forget(host, widget)
        local entries = host._managedFlowEntries
        if type(entries) == "table" then
            for i = #entries, 1, -1 do
                if entries[i].component == widget then
                    table.remove(entries, i)
                end
            end
        end
        pcall(function() widget:Destroy() end)
    end

    local function clearBody(host)
        for i = #body, 1, -1 do
            local widget = body[i]
            body[i] = nil
            forget(host, widget)
        end
        local layout = host._flowLayout
        if layout ~= nil then
            layout.nextY = layout.startY
            layout.row = nil
            layout.hasItems = false
            -- Flow only grows the scroll height. Drop it back so a shorter list,
            -- including the empty library, does not leave the footer below a hole.
            if host.SetContentHeight ~= nil then
                pcall(function() host:SetContentHeight(layout.startY) end)
            end
        end
        feedback = nil
    end

    local function remember(widget)
        if widget ~= nil then body[#body + 1] = widget end
        return widget
    end

    -- `actions` is the pencil and trash. Alert Preset rows have neither, so the name uses the row.
    ---@param host any
    ---@param actions integer
    ---@return integer
    local function rowWidth(host, actions)
        local contentW = host.contentWidth
        if type(contentW) ~= "number" then contentW = 352 end
        local width = contentW - FLOW_PAD * 2 - (Theme.MANAGER_ACT_W + FLOW_GAP) * actions
        if width < 80 then width = 80 end
        return width
    end

    ---@param captured Watchdog.Preset|Watchdog.PackAlertPreset
    ---@param create fun(answers: any[]|nil): integer|nil, string|nil
    local function openPreset(captured, create)
        if presetHasVariables(captured) then
            PresetDialogs.mountVariables(parent, {
                preset = captured,
                registry = self.registry,
                onCreate = function(answers)
                    return create(answers)
                end,
            })
            return
        end
        local id, err = create(nil)
        if id == nil and err ~= "variables" and feedback ~= nil then
            feedback.content = err or "Could not create the alert."
        end
    end

    beginRename = function(preset)
        local field, renameFeedback
        local initial = preset.name or ""
        local renameAction = {
            label = "Rename",
            variant = "positive",
            disabled = Presets.trim(initial) == "",
            onClick = function()
                local name = ""
                pcall(function() name = field:GetText() or "" end)
                if Presets.trim(name) == "" then return false end
                local renamed, err = Presets.Rename(preset.id, name)
                if renamed == nil then
                    if renameFeedback ~= nil then
                        renameFeedback.content = err or "Could not rename the preset."
                    end
                    return false
                end
                if alertWin ~= nil then fillList(alertWin) end
                return true
            end,
        }
        Dialog.mount(parent, {
            title = "Rename preset",
            width = 380,
            height = 200,
            content = function(win)
                win:AddText("Preset name")
                field = win:AddTextField({
                    text = initial,
                    maxLength = 80,
                    height = 30,
                    onChange = function(f)
                        local text = ""
                        pcall(function() text = f:GetText() or "" end)
                        if renameAction.setDisabled ~= nil then
                            renameAction.setDisabled(Presets.trim(text) == "")
                        end
                    end,
                })
                renameFeedback = win:AddText("")
            end,
            actions = {
                { label = "Cancel" },
                renameAction,
            },
        })
    end

    beginDelete = function(preset)
        Confirm.mount(parent, {
            title = "CONFIRM DELETE",
            body = string.format('Delete "%s"? This cannot be undone.', preset.name or ""),
            confirmLabel = "DELETE",
            confirmVariant = "negative",
            onConfirm = function()
                local deleted, err = Presets.Delete(preset.id)
                if deleted ~= true then
                    if feedback ~= nil then
                        feedback.content = err or "Could not delete the preset."
                    end
                    return false
                end
                if alertWin ~= nil then fillList(alertWin) end
                return true
            end,
        })
    end

    fillList = function(host)
        clearBody(host)
        local listed, listErr = Presets.List()
        local hasGroups = #offered > 0
        if listed == nil then
            remember(host:AddText(listErr or "Presets could not be read."))
        elseif #listed == 0 and not hasGroups then
            remember(host:AddText("There are no presets."))
        else
            if listed ~= nil and #listed > 0 then
                local width = rowWidth(host, 2)
                local iconOffset = math.floor((Theme.MANAGER_ROW_H - Theme.MANAGER_ACT_W) / 2)
                for _, preset in ipairs(listed) do
                    local captured = preset
                    remember(host:AddSimpleButton(captured.name, function()
                        openPreset(captured, function(answers)
                            return deliver(self:CreateFromPreset(scopeKey, captured.id, answers))
                        end)
                    end, {
                        width = width,
                        height = Theme.MANAGER_ROW_H,
                    }))
                    remember(host:AddSpriteButton("PENCIL", function()
                        beginRename(captured)
                    end, {
                        inline = true,
                        size = Theme.MANAGER_ACT_W,
                        offsetY = iconOffset,
                        tooltip = "Rename",
                    }))
                    remember(host:AddSpriteButton("TRASH", function()
                        beginDelete(captured)
                    end, {
                        inline = true,
                        size = Theme.MANAGER_ACT_W,
                        offsetY = iconOffset,
                        tooltip = "Delete",
                    }))
                end
            end
            -- The registry already ordered these groups. Do not sort them again.
            if hasGroups then
                local width = rowWidth(host, 0)
                for _, group in ipairs(offered) do
                    remember(host:AddText(group.packName))
                    for _, preset in ipairs(group.presets) do
                        local captured = preset
                        remember(host:AddSimpleButton(captured.name, function()
                            openPreset(captured, function(answers)
                                return deliver(self:CreateFromAlertPreset(scopeKey, captured, answers))
                            end)
                        end, {
                            width = width,
                            height = Theme.MANAGER_ROW_H,
                        }))
                    end
                end
            end
        end
        feedback = remember(host:AddText(""))
    end

    Dialog.mount(parent, {
        title = "New alert",
        width = 400,
        height = 420,
        content = function(win)
            if win.SetScrollable ~= nil then win:SetScrollable(false) end
            if prettyui == nil or prettyui.SimpleView == nil or win.content == nil then
                if log ~= nil then log("Watchdog: prettyui.SimpleView unavailable, New alert list aborted") end
                return
            end
            -- Same chrome as the preset dialogs: title 32 + border 8, footer band 48.
            local width = 400 - 16
            local contentW = win.content.width
            if type(contentW) == "number" and contentW > 0 then width = contentW end
            local view
            local ok, err = pcall(function()
                view = prettyui.SimpleView.new(win.content, {
                    x = 0,
                    y = 0,
                    width = width,
                    height = 420 - 40 - 48,
                })
            end)
            if not ok or view == nil then
                if log ~= nil then log("Watchdog: New alert list failed - " .. tostring(err)) end
                return
            end
            alertWin = view
            fillList(view)
        end,
        actions = {
            { label = "Cancel" },
            {
                label = "From scratch",
                variant = "positive",
                onClick = function()
                    local result, id = self:CreateFromScratch(scopeKey)
                    if id == nil then
                        if feedback ~= nil then
                            feedback.content = "Could not create the alert."
                        end
                        return false
                    end
                    if apply ~= nil then apply(result) end
                    return true
                end,
            },
        },
    })
    return nil
end

return ScopeEdits
