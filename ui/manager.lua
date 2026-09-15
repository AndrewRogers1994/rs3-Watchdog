-- manager.lua - Alert Manager: scope tabs + Entry tree (PrettyUI chrome, native tree Panel).
--
-- Native tree mounts under `mux:Content()`; PrettyUI chrome uses `mux:Window():Add*` so
-- Layout.manage owns teardown (unmanaged `prettyui.*.new` under a Layer hard-crashes on
-- poff - see .memory/spritebutton-teardown-crash.md). Tabs are strip-height only - a
-- full-height Tabs paints empty page content over the tree. Mid-session rebuild Destroys
-- managed widgets while the window stays alive (Layout.remove); Stop/Unmount only clears
-- Lua refs (mux window Destroy owns native teardown - Destroying Tabs then the window
-- double-frees after Show).

local Theme = require("ui/theme")
local Export = require("export")
local Confirm = require("ui/confirm")

local DELETE_CONFIRM_TITLE = "CONFIRM DELETE"
local DELETE_CONFIRM_LABEL = "DELETE"

local Manager = {}
Manager.__index = Manager

---@class Watchdog.ManagerScope
---@field key string                 # the Bucket key ("global" | "player_<normalized>")
---@field label string               # tab text ("Global" | the character's display name)
---@field doc Watchdog.Bucket        # the Bucket document whose Entry tree renders under this tab

-- Collapsed groups omit descendants from this list (renderer has no collapse logic).
---@class Watchdog.ManagerRow
---@field id integer                  # the Entry id (the key a row-open reports back)
---@field name string                 # display text
---@field kind "alert"|"group"
---@field depth integer               # 0 at root; each nesting level adds one (→ Theme.MANAGER_ROW_INDENT px)
---@field childCount integer|nil      # group only: number of DIRECT children
---@field expanded boolean            # group only: whether its children are shown (false for alerts)
---@field enabled boolean             # the Entry's own enabled flag (drives the row enable Check)

--- Construction ---------------------------------------------------------------------------

---@class Watchdog.ManagerOpts
---@field scopes fun(): Watchdog.ManagerScope[]              # ordered scopes (Global first, character second)
---@field onOpenAlert fun(scopeKey: string, id: integer)    # nav callback for a double-clicked alert row
---@field onToggleEnabled fun(scopeKey: string, id: integer)|nil
---@field onRename fun(scopeKey: string, id: integer, name: string)|nil
---@field onDelete fun(scopeKey: string, id: integer)|nil
---@field onReorderSibling fun(scopeKey: string, id: integer, delta: integer)|nil  # -1 up / +1 down
---@field onLift fun(scopeKey: string, id: integer)|nil
---@field onCreateAlert fun(scopeKey: string): integer|nil   # returns the minted alert id
---@field onCreateGroup fun(scopeKey: string): integer|nil   # returns the minted group id
---@field onBulkDelete fun(scopeKey: string, ids: integer[])|nil
---@field onBulkNewGroup fun(scopeKey: string, ids: integer[]): integer|nil  # returns new group id
---@field onBulkMove fun(scopeKey: string, destScopeKey: string, ids: integer[])|nil
---@field onExportEntries fun(scopeKey: string, ids: integer[]|nil): boolean, string  # nil ids = whole scope; err or json
---@field onImportJson fun(scopeKey: string, text: string): boolean, Watchdog.ImportReport|string
---@field windowParent fun(): any|nil  # parent Layer for the transfer Window (mux.rootLayer - plugin-owned)

---@param opts Watchdog.ManagerOpts|nil
---@return table
function Manager.new(opts)
    local self = setmetatable({
        scopesProvider = (opts and opts.scopes) or function() return {} end,
        onOpenAlert = (opts and opts.onOpenAlert) or function() end,
        onToggleEnabled = opts and opts.onToggleEnabled,
        onRename = opts and opts.onRename,
        onDelete = opts and opts.onDelete,
        onReorderSibling = opts and opts.onReorderSibling,
        onLift = opts and opts.onLift,
        onCreateAlert = opts and opts.onCreateAlert,
        onCreateGroup = opts and opts.onCreateGroup,
        onBulkDelete = opts and opts.onBulkDelete,
        onBulkNewGroup = opts and opts.onBulkNewGroup,
        onBulkMove = opts and opts.onBulkMove,
        onExportEntries = opts and opts.onExportEntries,
        onImportJson = opts and opts.onImportJson,
        windowParent = opts and opts.windowParent,
        activeScope = nil,          -- nil ⇒ first scope (Global)
        expanded = {},              -- expanded[scopeKey][id]; absent ⇒ expanded
        expandVersion = 0,
        mutateVersion = 0,
        selected = {},              -- selected[id] = true; antichain after every toggle
        selectVersion = 0,
        lastSelectId = nil,         -- Shift-click range anchor over VisibleRows()
        visible = false,
        tick = 0,
        lastRowId = nil,
        lastRowTick = -1000,
        window = {
            w = Theme.WINDOW_W, h = Theme.WINDOW_H,
        },
        contentParent = nil,
        layoutHost = nil,           -- prettyui.Window (Add* / Layout.manage)
        tabs = nil,
        tabsScopeSig = nil,
        treePanel = nil,
        treeTop = 0,                -- content-local Y (rename AddTextField coords)
        bulkBarButtons = {},
        toolbarButtons = {},
        lastSignature = nil,
        renameField = nil,
        renameId = nil,
        pendingRenameId = nil,      -- begin inline rename once the row is rebuilt
        transfer = nil,
        transferWindow = nil,
        transferField = nil,
        confirmWindow = nil,
    }, Manager)
    return self
end

--- Pure logic: scopes ---------------------------------------------------------------------

---@return Watchdog.ManagerScope[]
function Manager:ScopeList()
    local ok, scopes = pcall(self.scopesProvider)
    if ok and type(scopes) == "table" then return scopes end
    return {}
end

-- Stale `activeScope` (logged-out character) falls back to the first scope.
---@return Watchdog.ManagerScope|nil
function Manager:ActiveScope()
    local scopes = self:ScopeList()
    if #scopes == 0 then return nil end
    if self.activeScope ~= nil then
        for _, scope in ipairs(scopes) do
            if scope.key == self.activeScope then return scope end
        end
    end
    return scopes[1]
end

---@return string|nil
function Manager:ActiveScopeKey()
    local scope = self:ActiveScope()
    return scope and scope.key or nil
end

-- Clears double-click pairing and selection (the visible list is replaced).
---@param key string
function Manager:SetActiveScope(key)
    self.activeScope = key
    self.lastRowId = nil
    self:ClearSelection()
end

--- Pure logic: expand/collapse ------------------------------------------------------------

-- Groups default to expanded.
---@param scopeKey string
---@param id integer
---@return boolean
function Manager:IsExpanded(scopeKey, id)
    local perScope = self.expanded[scopeKey]
    if perScope == nil or perScope[id] == nil then return true end
    return perScope[id]
end

local function entryContainsId(entries, ancestorId, maybeDescendant)
    local function find(list)
        for _, e in ipairs(list or {}) do
            if e.id == ancestorId then return e end
            if e.children ~= nil then
                local found = find(e.children)
                if found ~= nil then return found end
            end
        end
        return nil
    end
    local root = find(entries)
    if root == nil then return false end
    if root.id == maybeDescendant then return true end
    local function walk(children)
        for _, c in ipairs(children or {}) do
            if c.id == maybeDescendant then return true end
            if c.children ~= nil and walk(c.children) then return true end
        end
        return false
    end
    return walk(root.children)
end

-- Collapse is session UI only (not persisted). Drops nested selection when collapsing.
---@param scopeKey string
---@param id integer
function Manager:ToggleExpand(scopeKey, id)
    local perScope = self.expanded[scopeKey]
    if perScope == nil then
        perScope = {}
        self.expanded[scopeKey] = perScope
    end
    local nowExpanded = not self:IsExpanded(scopeKey, id)
    perScope[id] = nowExpanded
    self.expandVersion = self.expandVersion + 1
    if not nowExpanded then
        -- Collapse: drop selection inside the group (the group row itself stays visible).
        local scope = self:ActiveScope()
        local entries = scope and (scope.doc or {}).entries or nil
        local changed = false
        for selId, _ in pairs(self.selected) do
            if selId ~= id and entryContainsId(entries, id, selId) then
                self.selected[selId] = nil
                changed = true
            end
        end
        if changed then
            self.selectVersion = self.selectVersion + 1
        end
    end
end

--- Pure logic: tree flattening ------------------------------------------------------------

-- Collapsed group: own row only, no subtree.
---@param self table
---@param entries Watchdog.Entry[]|nil
---@param scopeKey string
---@param depth integer
---@param out Watchdog.ManagerRow[]
local function flatten(self, entries, scopeKey, depth, out)
    for _, e in ipairs(entries or {}) do
        local isGroup = e.kind == "group"
        local expanded = isGroup and self:IsExpanded(scopeKey, e.id) or false
        out[#out + 1] = {
            id = e.id,
            name = e.name or "",
            kind = e.kind,
            depth = depth,
            childCount = isGroup and #(e.children or {}) or nil,
            expanded = expanded,
            enabled = e.enabled ~= false,
        }
        if isGroup and expanded then
            flatten(self, e.children, scopeKey, depth + 1, out)
        end
    end
    return out
end

---@return Watchdog.ManagerRow[]
function Manager:VisibleRows()
    local scope = self:ActiveScope()
    if scope == nil then return {} end
    return flatten(self, (scope.doc or {}).entries, scope.key, 0, {})
end

-- `scopeKey` from press time so a tab switch cannot retarget the row.
---@param scopeKey string
---@param row Watchdog.ManagerRow
function Manager:_activateRow(scopeKey, row)
    if row.kind == "group" then
        self:ToggleExpand(scopeKey, row.id)
    elseif row.kind == "alert" then
        pcall(self.onOpenAlert, scopeKey, row.id)
    end
end

--- Pure logic: row editing ----------------------------------------------------------------
-- Host callbacks; bump mutateVersion even when root count is unchanged (enable/rename).

local function bumpMutate(self)
    self.mutateVersion = self.mutateVersion + 1
end

---@param id integer
function Manager:ToggleEnabled(id)
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil or self.onToggleEnabled == nil then return end
    pcall(self.onToggleEnabled, scopeKey, id)
    bumpMutate(self)
end

---@param id integer
---@param name string
function Manager:Rename(id, name)
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil or self.onRename == nil then return end
    pcall(self.onRename, scopeKey, id, name)
    bumpMutate(self)
end

-- Committed delete; confirm UI is the caller's job.
---@param id integer
function Manager:Delete(id)
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil or self.onDelete == nil then return end
    pcall(self.onDelete, scopeKey, id)
    bumpMutate(self)
end

---@param entries Watchdog.Entry[]|nil
---@param id integer
---@param parent Watchdog.Entry|nil
---@return Watchdog.Entry|nil entry
---@return Watchdog.Entry[]|nil siblings
---@return integer|nil index
---@return Watchdog.Entry|nil parent
local function findInTree(entries, id, parent)
    for i, e in ipairs(entries or {}) do
        if e.id == id then return e, entries, i, parent end
        if e.children ~= nil then
            local found, siblings, index, p = findInTree(e.children, id, e)
            if found ~= nil then return found, siblings, index, p end
        end
    end
    return nil, nil, nil, nil
end

---@param id integer
---@return boolean canUp
---@return boolean canDown
---@return boolean canLift
function Manager:RowMoveCaps(id)
    local scope = self:ActiveScope()
    if scope == nil or scope.doc == nil then return false, false, false end
    local entry, siblings, index, parent = findInTree(scope.doc.entries, id, nil)
    if entry == nil or siblings == nil or index == nil then return false, false, false end
    return index > 1, index < #siblings, parent ~= nil
end

---@param id integer
---@param delta integer
function Manager:ReorderSibling(id, delta)
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil or self.onReorderSibling == nil then return end
    pcall(self.onReorderSibling, scopeKey, id, delta)
    bumpMutate(self)
end

---@param id integer
function Manager:Lift(id)
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil or self.onLift == nil then return end
    pcall(self.onLift, scopeKey, id)
    bumpMutate(self)
end

---@return integer|nil
function Manager:CreateAlert()
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil or self.onCreateAlert == nil then return nil end
    local ok, id = pcall(self.onCreateAlert, scopeKey)
    bumpMutate(self)
    if ok and type(id) == "number" then return id end
    return nil
end

---@return integer|nil
function Manager:CreateGroup()
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil or self.onCreateGroup == nil then return nil end
    local ok, id = pcall(self.onCreateGroup, scopeKey)
    bumpMutate(self)
    if ok and type(id) == "number" then return id end
    return nil
end

--- Pure logic: multi-select ---------------------------------------------------------------
-- Selection is `id → true`, normalized to a group-as-unit antichain (no descendant also selected).

local function bumpSelect(self)
    self.selectVersion = self.selectVersion + 1
end

---@param entries Watchdog.Entry[]|nil
---@param id integer
---@return integer[]
local function ancestorIdsOf(entries, id)
    local function rec(list, acc)
        for _, entry in ipairs(list or {}) do
            if entry.id == id then return acc end
            if entry.children ~= nil then
                acc[#acc + 1] = entry.id
                local found = rec(entry.children, acc)
                if found ~= nil then return found end
                acc[#acc] = nil
            end
        end
        return nil
    end
    return rec(entries, {}) or {}
end

function Manager:NormalizeSelection()
    local scope = self:ActiveScope()
    local entries = scope and (scope.doc or {}).entries or nil
    local drop = {}
    for selId, _ in pairs(self.selected) do
        for _, anc in ipairs(ancestorIdsOf(entries, selId)) do
            if self.selected[anc] then
                drop[selId] = true
                break
            end
        end
    end
    for id, _ in pairs(drop) do
        self.selected[id] = nil
    end
end

function Manager:ClearSelection()
    local any = false
    for _ in pairs(self.selected) do any = true break end
    self.selected = {}
    self.lastSelectId = nil
    if any then bumpSelect(self) end
end

---@return boolean
function Manager:HasSelection()
    for _ in pairs(self.selected) do return true end
    return false
end

---@return integer[]
function Manager:SelectedIds()
    local out = {}
    for _, row in ipairs(self:VisibleRows()) do
        if self.selected[row.id] then out[#out + 1] = row.id end
    end
    return out
end

---@param id integer
---@param shift boolean|nil
function Manager:ToggleSelection(id, shift)
    if shift and self.lastSelectId ~= nil then
        local rows = self:VisibleRows()
        local a, b
        for i, row in ipairs(rows) do
            if row.id == self.lastSelectId then a = i end
            if row.id == id then b = i end
        end
        if a ~= nil and b ~= nil then
            local lo, hi = math.min(a, b), math.max(a, b)
            for i = lo, hi do
                self.selected[rows[i].id] = true
            end
        else
            -- Anchor or target not visible: fall back to a plain add.
            self.selected[id] = true
        end
    else
        if self.selected[id] then
            self.selected[id] = nil
        else
            self.selected[id] = true
        end
    end
    self.lastSelectId = id
    self:NormalizeSelection()
    bumpSelect(self)
end

---@param ids integer[]|nil
function Manager:BulkDelete(ids)
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil or self.onBulkDelete == nil then return end
    ids = ids or self:SelectedIds()
    if #ids == 0 then return end
    pcall(self.onBulkDelete, scopeKey, ids)
    self:ClearSelection()
    bumpMutate(self)
end

---@param ids integer[]|nil
---@return integer|nil
function Manager:BulkNewGroup(ids)
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil or self.onBulkNewGroup == nil then return nil end
    ids = ids or self:SelectedIds()
    if #ids == 0 then return nil end
    local ok, newId = pcall(self.onBulkNewGroup, scopeKey, ids)
    bumpMutate(self)
    if ok and type(newId) == "number" then
        self.selected = { [newId] = true }
        self.lastSelectId = newId
        bumpSelect(self)
        return newId
    end
    self:ClearSelection()
    return nil
end

---@param destScopeKey string
---@param ids integer[]|nil
function Manager:BulkMove(destScopeKey, ids)
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil or self.onBulkMove == nil then return end
    ids = ids or self:SelectedIds()
    if #ids == 0 then return end
    pcall(self.onBulkMove, scopeKey, destScopeKey, ids)
    self:ClearSelection()
    bumpMutate(self)
end

---@param ids integer[]|nil
function Manager:BulkExport(ids)
    ids = ids or self:SelectedIds()
    if #ids == 0 then return end
    -- Keep selection across export.
    self:_runExport(ids)
end

function Manager:ExportScope()
    self:_runExport(nil)
end

---@param id integer
function Manager:ExportRow(id)
    if type(id) ~= "number" then return end
    self:_runExport({ id })
end

---@param ids integer[]|nil  # nil ⇒ whole active scope
function Manager:_runExport(ids)
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil or self.onExportEntries == nil then return end
    local okCall, ok, result = pcall(function()
        return self.onExportEntries(scopeKey, ids)
    end)
    if not okCall then return end
    if ok then
        self:_openTransfer("export", result, "Select all and copy (Ctrl+A / Ctrl+C).")
    else
        self:_openTransfer("error", "", tostring(result))
    end
end

function Manager:OpenImport()
    self:_openTransfer("import", "", "Paste an export envelope, then Import.")
end

function Manager:CloseTransfer()
    self.transfer = nil
    local win = self.transferWindow
    self.transferWindow = nil
    self.transferField = nil
    if win ~= nil then
        pcall(function()
            win.onClose = nil
            win:Destroy()
        end)
    end
end

-- Failures stay in the modal with the pasted text intact.
function Manager:ApplyImport()
    if self.transfer == nil or self.transfer.mode ~= "import" then return end
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil or self.onImportJson == nil then return end
    local text = self.transfer.text or ""
    pcall(function()
        if self.transferField ~= nil and self.transferField.GetText ~= nil then
            text = self.transferField:GetText() or text
        end
    end)
    local okCall, ok, report = pcall(function()
        return self.onImportJson(scopeKey, text)
    end)
    if not okCall then return end
    if not ok then
        self.transfer.text = text
        self.transfer.message = tostring(report)
        self:_remountTransfer()
        return
    end
    local message = (type(report) == "table" and report.message) or "Imported."
    self:CloseTransfer()
    bumpMutate(self)
    self:_openTransfer("notice", "", message)
end

---@param mode "export"|"import"|"error"|"notice"
---@param text string|nil
---@param message string|nil
function Manager:_openTransfer(mode, text, message)
    self.transfer = {
        mode = mode,
        text = text or "",
        message = message,
    }
    self:_remountTransfer()
end

function Manager:_remountTransfer()
    self:_destroyTransfer()
    self:_mountTransfer()
end

-- Tear down the open transfer Window only - keeps `self.transfer` so remount can rebuild.
function Manager:_destroyTransfer()
    local win = self.transferWindow
    self.transferWindow = nil
    self.transferField = nil
    if win ~= nil then
        pcall(function()
            win.onClose = nil
            win:Destroy()
        end)
    end
end

--- Rebuild signature ----------------------------------------------------------------------

---@return string
function Manager:_signature()
    local parts = {
        self:ActiveScopeKey() or "-",
        tostring(self.expandVersion),
        tostring(self.mutateVersion),
        tostring(self.selectVersion),
    }
    for _, scope in ipairs(self:ScopeList()) do
        local entries = (scope.doc or {}).entries or {}
        parts[#parts + 1] = scope.key .. ":" .. (scope.label or "") .. ":" .. tostring(#entries)
    end
    return table.concat(parts, "|")
end

--- Client view: rows glyphs ---------------------------------------------------------------

---@param row Watchdog.ManagerRow
---@return string
function Manager:RowLabel(row)
    if row.kind == "group" then
        local chevron = row.expanded and "v" or ">"
        return chevron .. " | " .. row.name .. " (" .. tostring(row.childCount or 0) .. ")"
    end
    return row.name
end

--- Client view: mount / render (client-only, pcall-guarded) -------------------------------

local function safeButtonStyle()
    if id ~= nil and id.StyleSheet ~= nil and id.StyleSheet.BUTTON_DEFAULT ~= nil then
        return id.StyleSheet.BUTTON_DEFAULT
    end
    return nil
end

local function safeCheckStyle()
    if id ~= nil and id.StyleSheet ~= nil and id.StyleSheet.CHECKBOX_DEFAULT ~= nil then
        return id.StyleSheet.CHECKBOX_DEFAULT
    end
    return nil
end

---@param parent ui.ComponentCollection|nil
---@return number, number
local function contentSize(parent)
    local w, h = Theme.WINDOW_W, Theme.WINDOW_H
    if parent ~= nil then
        pcall(function()
            if parent.width and parent.width > 0 then w = parent.width end
            if parent.height and parent.height > 0 then h = parent.height end
        end)
    end
    return w, h
end

---@param comp ui.Component|nil
---@param visible boolean
local function setChildVisible(comp, visible)
    if comp == nil then return end
    pcall(function()
        comp.hidden = not visible
        comp.enabled = visible
    end)
end

---@param comp any
---@return any
local function componentRoot(comp)
    if comp == nil then return nil end
    if type(comp) == "table" and comp.root ~= nil then return comp.root end
    return comp
end

-- Recreate Tabs on login/logout (key+label); keep them across expand/enable/rename rebuilds.
---@return string
function Manager:_scopeTabsSignature()
    local parts = {}
    for _, scope in ipairs(self:ScopeList()) do
        parts[#parts + 1] = (scope.key or "") .. ":" .. (scope.label or "")
    end
    return table.concat(parts, "|")
end

---@return integer
function Manager:_activeScopeIndex()
    local activeKey = self:ActiveScopeKey()
    for i, scope in ipairs(self:ScopeList()) do
        if scope.key == activeKey then return i end
    end
    return 1
end

function Manager:_destroyToolbar()
    for _, b in ipairs(self.toolbarButtons) do
        pcall(function() b:Destroy() end)
    end
    self.toolbarButtons = {}
end

function Manager:_destroyBulkBar()
    for _, b in ipairs(self.bulkBarButtons) do
        pcall(function() b:Destroy() end)
    end
    self.bulkBarButtons = {}
end

function Manager:_destroyTree()
    self:_endRename(false)
    if self.treePanel ~= nil then
        pcall(function() self.treePanel:Destroy() end)
        self.treePanel = nil
    end
end

-- Live rebuild only - not Unmount/Stop (must not Destroy before mux window Destroy).
function Manager:_destroyTabs()
    self:_destroyToolbar()
    self:_destroyBulkBar()
    self:_destroyTree()
    if self.tabs ~= nil then
        pcall(function() self.tabs:Destroy() end)
        self.tabs = nil
    end
    self.tabsScopeSig = nil
end

-- Recreate on key/label change; otherwise SetActive without notify (avoids rebuild re-entrancy).
---@return boolean
function Manager:_ensureTabs()
    if self.layoutHost == nil or self.layoutHost.AddTabs == nil then
        return false
    end
    local scopes = self:ScopeList()
    if #scopes == 0 then
        self:_destroyTabs()
        return false
    end
    local sig = self:_scopeTabsSignature()
    if self.tabs ~= nil and self.tabsScopeSig == sig then
        local idx = self:_activeScopeIndex()
        pcall(function() self.tabs:SetActive(idx, false) end)
        return true
    end

    self:_destroyTabs()
    local entries = {}
    for _, scope in ipairs(scopes) do
        entries[#entries + 1] = {
            text = scope.label or scope.key,
            value = scope.key,
        }
    end
    local activeIndex = self:_activeScopeIndex()
    local tabs
    local ok, err = pcall(function()
        -- Height = tab strip only. A full-height Tabs root paints an empty page over the
        -- sibling tree Panel and hides every row (MoveToFront is not enough against that).
        -- AddTabs → Layout.manage (safe on poff); Tabs.new under content Layer is not.
        tabs = self.layoutHost:AddTabs(entries, {
            x = 0,
            y = 0,
            width = 0,
            widthAnchor = 1.0,
            height = Theme.MANAGER_TAB_BASELINE + 1,
            scrollable = false,
            activeIndex = activeIndex,
            onChange = function(_, _index, value, _page)
                self:SetActiveScope(value)
                self:_rebuild()
            end,
        })
    end)
    if not ok or tabs == nil then
        if log ~= nil then log("Watchdog: prettyui.Tabs Mount failed") end
        return false
    end
    self.tabs = tabs
    self.tabsScopeSig = sig
    return true
end

---@param contentParent ui.ComponentCollection
---@param layoutHost any  # prettyui.Window (Add* host); required for PrettyUI chrome
function Manager:Mount(contentParent, layoutHost)
    if ui == nil or ui.Panel == nil then
        if log ~= nil then log("Watchdog: ui.Panel unavailable, Manager Mount aborted") end
        return
    end
    if layoutHost == nil or layoutHost.AddTabs == nil then
        if log ~= nil then log("Watchdog: layoutHost.AddTabs unavailable, Manager Mount aborted") end
        return
    end

    self.contentParent = contentParent
    self.layoutHost = layoutHost
    local w, h = contentSize(contentParent)
    self.window.w, self.window.h = w, h

    if not self:_ensureTabs() then
        self.contentParent = nil
        self.layoutHost = nil
        return
    end

    self:SetVisible(self.visible)
    self:_rebuild()
end

---@return boolean
function Manager:IsMounted()
    return self.tabs ~= nil
end

function Manager:_clearChildren()
    self:_destroyToolbar()
    self:_destroyBulkBar()
    self:_destroyTree()
end

---@param rowW number
---@param depth integer|nil
---@return number baseNameW
---@return number nameW
---@return number moveW
---@return number actionsW
local function managerColumnWidths(rowW, depth)
    local baseNameW = math.max(40, rowW - Theme.MANAGER_ENABLE_W - Theme.MANAGER_SELECT_W - Theme.MANAGER_REORDER_COUNT * Theme.MANAGER_REORDER_W
        - Theme.MANAGER_ACT_COUNT * Theme.MANAGER_ACT_W - (Theme.MANAGER_ACT_COUNT + Theme.MANAGER_REORDER_COUNT + 2) * Theme.MANAGER_ROW_GAP)
    local indent = (depth or 0) * Theme.MANAGER_ROW_INDENT
    local nameW = math.max(40, baseNameW - indent)
    local moveW = Theme.MANAGER_REORDER_COUNT * Theme.MANAGER_REORDER_W
        + (Theme.MANAGER_REORDER_COUNT - 1) * Theme.MANAGER_ROW_GAP
    local actionsW = Theme.MANAGER_ACT_COUNT * Theme.MANAGER_ACT_W
        + (Theme.MANAGER_ACT_COUNT - 1) * Theme.MANAGER_ROW_GAP
    return baseNameW, nameW, moveW, actionsW
end

---@param parent ui.ComponentCollection
---@param w number
---@param h number
---@param text string
---@param center boolean|nil
local function mountHeaderCell(parent, w, h, text, center)
    local label
    local ok = pcall(function() label = ui.Text.new(parent) end)
    if not ok or label == nil then return end
    pcall(function()
        label:SetSize(w, h)
        label.content = text
        label.clickthrough = true
        label.isShadowed = true
        label.maxLines = 1
        if id ~= nil and id.Font ~= nil then
            label.font = id.Font.MUSEO_SANS_15PT_REGULAR
        end
        -- ui.Text defaults to no visible colour without rgb/rgba (DevTools / LibUIToolkit pattern).
        local c = Theme.COL_PALETTE_TEXT_DIM
        local function ch(v) return math.floor((v or 1) * 255 + 0.5) end
        local rgb = ch(c.r) * 0x1000000 + ch(c.g) * 0x10000 + ch(c.b) * 0x100 + ch(c.a)
        label.rgb = rgb
        label.rgba = rgb
        if ui.AlignMode ~= nil then
            label.alignHorizontal = center and ui.AlignMode.CENTRE or ui.AlignMode.LEFT
            label.alignVertical = ui.AlignMode.CENTRE
        end
        label:MoveToFront()
    end)
end

---@param parent ui.ComponentCollection
---@param x number
---@param y number
---@param w number
---@param h number
---@param label string
---@param onPress fun()
---@param enabled boolean|nil
---@return ui.Button|nil
local function mountButton(parent, x, y, w, h, label, onPress, enabled)
    local button
    local okb = pcall(function() button = ui.Button.new(parent) end)
    if not okb or button == nil then return nil end
    pcall(function() button.stylesheetID = safeButtonStyle() end)
    button.clickthrough = false
    button:SetPos(x, y)
    button:SetSize(w, h)
    pcall(function() button.text.content = label end)
    local isEnabled = enabled ~= false
    pcall(function() button.enabled = isEnabled end)
    button:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
        if not isEnabled then return true end
        onPress()
        return true
    end)
    pcall(function() button:MoveToFront() end)
    return button
end

local SUBMIT_CAUSES = {
    SUBMIT = true, SUBMIT_ON_ESCAPE = true, SUBMIT_ON_FOCUS_LOSS = true,
}
local function isSubmitCause(cause)
    if cause == nil then return false end
    if type(cause) == "string" and SUBMIT_CAUSES[cause] then return true end
    local r = ui and ui.InputFieldActionResult
    if r ~= nil then
        if cause == r.SUBMIT or cause == r.SUBMIT_ON_ESCAPE or cause == r.SUBMIT_ON_FOCUS_LOSS then
            return true
        end
    end
    return false
end

---@param commit boolean
function Manager:_endRename(commit)
    local field, id = self.renameField, self.renameId
    self.renameField, self.renameId = nil, nil
    if field == nil then return end
    if commit and id ~= nil then
        local name = ""
        pcall(function()
            if field.GetText ~= nil then
                name = field:GetText() or ""
            elseif field.root ~= nil then
                name = field.root.content or ""
            else
                name = field.content or ""
            end
        end)
        if name ~= "" then self:Rename(id, name) end
    end
    pcall(function() field:Destroy() end)
end

-- Content-local coords on layoutHost (treePanel is native - not a Layout host).
---@param id integer
---@param name string
---@param x number
---@param y number
---@param w number
---@param h number
function Manager:_beginRename(id, name, x, y, w, h)
    self:_endRename(false)
    if self.layoutHost == nil or self.layoutHost.AddTextField == nil then return end
    local field
    local ok = pcall(function()
        field = self.layoutHost:AddTextField({
            text = name or "",
            x = x,
            y = y,
            width = w,
            height = h,
            maxLength = 64,
            onChange = function(_f, reason, _text)
                if isSubmitCause(reason) then
                    self:_endRename(true)
                    self:_rebuild()
                end
            end,
        })
    end)
    if ok and field ~= nil then
        self.renameField = field
        self.renameId = id
        pcall(function()
            if field.root ~= nil then field.root:MoveToFront() end
        end)
    end
end

---@param id integer
function Manager:_onDeletePress(id)
    self:_openConfirm({
        title = DELETE_CONFIRM_TITLE,
        confirmLabel = DELETE_CONFIRM_LABEL,
        confirmVariant = 'negative',
        body = self:_deleteConfirmBody(id),
        onConfirm = function()
            self:Delete(id)
            self:_rebuild()
        end,
    })
end

---@param id integer
---@return Watchdog.Entry|nil
function Manager:_entryById(id)
    local scope = self:ActiveScope()
    if scope == nil or scope.doc == nil then return nil end
    local entry = findInTree(scope.doc.entries, id, nil)
    return entry
end

---@param id integer
---@return integer
function Manager:_descendantCount(id)
    local entry = self:_entryById(id)
    if entry == nil or entry.kind ~= "group" then return 0 end
    local n = 0
    local function count(children)
        for _, c in ipairs(children or {}) do
            n = n + 1
            if c.children ~= nil then count(c.children) end
        end
    end
    count(entry.children)
    return n
end

---@param id integer
---@return string
function Manager:_deleteConfirmBody(id)
    local entry = self:_entryById(id)
    local name = entry and entry.name or ""
    local n = self:_descendantCount(id)
    if n > 0 then
        local noun = n == 1 and "descendant" or "descendants"
        return string.format('Delete "%s" and %d %s? This cannot be undone.', name, n, noun)
    end
    return string.format('Delete "%s"? This cannot be undone.', name)
end

---@param ids integer[]|nil
---@return integer
function Manager:_bulkRideAlongCount(ids)
    local n = 0
    for _, id in ipairs(ids or self:SelectedIds()) do
        n = n + self:_descendantCount(id)
    end
    return n
end

---@param ids integer[]|nil
---@return string
function Manager:_bulkDeleteConfirmBody(ids)
    ids = ids or self:SelectedIds()
    local body = string.format("Delete %d selected?", #ids)
    local n = self:_bulkRideAlongCount(ids)
    if n > 0 then
        local noun = n == 1 and "descendant" or "descendants"
        body = body .. string.format(" This also deletes %d %s.", n, noun)
    end
    return body
end

function Manager:CloseConfirm()
    local win = self.confirmWindow
    self.confirmWindow = nil
    Confirm.destroy(win)
end

---@param opts Watchdog.ConfirmOpts
function Manager:_openConfirm(opts)
    self:CloseConfirm()
    local parent
    if self.windowParent ~= nil then
        local ok, p = pcall(self.windowParent)
        if ok then parent = p end
    end
    if parent == nil then return end
    local onConfirm, onCancel = opts.onConfirm, opts.onCancel
    opts.onConfirm = function()
        self.confirmWindow = nil
        if onConfirm ~= nil then onConfirm() end
    end
    opts.onCancel = function()
        self.confirmWindow = nil
        if onCancel ~= nil then onCancel() end
    end
    self.confirmWindow = Confirm.mount(parent, opts)
end

---@return boolean
local function isShiftDown()
    local shift = false
    pcall(function()
        if Keyboard ~= nil and Keyboard.IsShiftDown ~= nil then
            shift = Keyboard.IsShiftDown() and true or false
        end
    end)
    return shift
end

-- Tabs has no trailing-actions API (only TabPage is a ContentMethods host) - AddFancyButton + abs coords.
function Manager:_mountToolbar()
    if self.layoutHost == nil or self.layoutHost.AddFancyButton == nil then return end
    if prettyui == nil or prettyui.FancyButton == nil then return end
    local alertW, groupW, importW, exportW = 75, 75, 70, 70
    pcall(function()
        alertW = select(1, prettyui.FancyButton.getSize("+ Alert", { variant = "positive" }))
        groupW = select(1, prettyui.FancyButton.getSize("+ Group", { variant = "neutral" }))
        importW = select(1, prettyui.FancyButton.getSize("Import", { variant = "neutral" }))
        exportW = select(1, prettyui.FancyButton.getSize("Export", { variant = "neutral" }))
    end)
    local y = math.max(0, math.floor((Theme.MANAGER_TAB_BASELINE - Theme.MANAGER_TOOLBAR_H) / 2))
    local group, alert, importBtn, exportBtn
    local xGroup = -Theme.MANAGER_TOOLBAR_PAD - groupW
    local xAlert = xGroup - Theme.MANAGER_TOOLBAR_GAP - alertW
    local xExport = xAlert - Theme.MANAGER_TOOLBAR_GAP - exportW
    local xImport = xExport - Theme.MANAGER_TOOLBAR_GAP - importW
    pcall(function()
        group = self.layoutHost:AddFancyButton("+ Group", function()
            local id = self:CreateGroup()
            if type(id) == "number" then self.pendingRenameId = id end
            self:_rebuild()
        end, {
            x = xGroup,
            y = y,
            xAnchor = 1.0,
            variant = "neutral",
        })
        alert = self.layoutHost:AddFancyButton("+ Alert", function()
            self:CreateAlert()
            self:_rebuild()
        end, {
            x = xAlert,
            y = y,
            xAnchor = 1.0,
            variant = "positive",
        })
        exportBtn = self.layoutHost:AddFancyButton("Export", function()
            self:ExportScope()
        end, {
            x = xExport,
            y = y,
            xAnchor = 1.0,
            variant = "neutral",
        })
        importBtn = self.layoutHost:AddFancyButton("Import", function()
            self:OpenImport()
        end, {
            x = xImport,
            y = y,
            xAnchor = 1.0,
            variant = "neutral",
        })
    end)
    if importBtn ~= nil then self.toolbarButtons[#self.toolbarButtons + 1] = importBtn end
    if exportBtn ~= nil then self.toolbarButtons[#self.toolbarButtons + 1] = exportBtn end
    if alert ~= nil then self.toolbarButtons[#self.toolbarButtons + 1] = alert end
    if group ~= nil then self.toolbarButtons[#self.toolbarButtons + 1] = group end
end

-- Transfer Window under mux-owned root Layer so poff/Stop tears it down - never parent to the game area.
function Manager:_mountTransfer()
    if self.transfer == nil then return end
    if prettyui == nil or prettyui.Window == nil then return end
    local parent
    if self.windowParent ~= nil then
        local ok, p = pcall(self.windowParent)
        if ok then parent = p end
    end
    if parent == nil then return end

    local mode = self.transfer.mode
    local title = "Export"
    if mode == "import" or mode == "notice" then title = "Import"
    elseif mode == "error" then title = "Export / Import"
    end

    local win
    local ok = pcall(function()
        win = prettyui.Window.new(parent, {
            title = title,
            x = -math.floor(Theme.MANAGER_TRANSFER_W / 2),
            y = -math.floor(Theme.MANAGER_TRANSFER_H / 2),
            xAnchor = 0.5,
            yAnchor = 0.5,
            width = Theme.MANAGER_TRANSFER_W,
            height = Theme.MANAGER_TRANSFER_H,
            minWidth = Theme.MANAGER_TRANSFER_W,
            minHeight = Theme.MANAGER_TRANSFER_H,
            maxWidth = Theme.MANAGER_TRANSFER_W,
            maxHeight = Theme.MANAGER_TRANSFER_H,
            destroyOnClose = true,
            onClose = function()
                -- Window:Close will Destroy after this (destroyOnClose). Clear Lua refs only.
                self.transfer = nil
                self.transferWindow = nil
                self.transferField = nil
            end,
        })
    end)
    if not ok or win == nil then return end
    self.transferWindow = win

    local msg = self.transfer.message or ""
    if msg ~= "" then
        pcall(function() win:AddText(msg) end)
    end

    if mode == "export" or mode == "import" then
        local field
        local okf = pcall(function()
            field = win:AddTextField({
                text = self.transfer.text or "",
                placeholder = mode == "import" and "Paste export JSON here" or nil,
                maxLength = Export.MAX_BYTES,
                height = 280,
                disabled = mode == "export",
            })
            field.root.text.maxLines = 10
        end)
        if okf and field ~= nil then
            self.transferField = field
            -- Export is copy-out: keep content selectable. PrettyUI `disabled` blocks focus;
            -- leave enabled so Ctrl+A/C works, and ignore edits by resetting on change.
            if mode == "export" then
                pcall(function()
                    if field.SetDisabled ~= nil then field:SetDisabled(false) end
                    local frozen = self.transfer.text or ""
                    field.onChange = function(f)
                        if f:GetText() ~= frozen then f:SetText(frozen) end
                    end
                    field.root:Subscribe(ui.Hook.ONCLICK, function()
                        if field.root.SelectAll ~= nil then field.root:SelectAll() end
                        return true
                    end)
                end)
            end
        end
    end

    pcall(function()
        win:AddFancyButton("Close", function()
            self:CloseTransfer()
        end)
        if mode == "import" then
            win:AddFancyButton("Import", function()
                self:ApplyImport()
                self:_rebuild()
            end, { inline = true, variant = "positive" })
        elseif mode == "export" then
            win:AddFancyButton("Save to file", function() end, {
                inline = true,
                disabled = true,
                tooltip = "File export needs a client filesystem API",
            })
        end
    end)

    pcall(function() win:Show() end)
end

function Manager:_mountBulkBar(y)
    if not self:HasSelection() then return end
    if self.layoutHost == nil or self.layoutHost.AddFancyButton == nil then return end
    if prettyui == nil or prettyui.FancyButton == nil then return end
    local ids = self:SelectedIds()
    local x = 0
    local gap = Theme.MANAGER_TOOLBAR_GAP

    local function addFancy(label, variant, onPress)
        local btn
        local w = 80
        pcall(function()
            w = select(1, prettyui.FancyButton.getSize(label, { variant = variant, inline = true }))
        end)
        pcall(function()
            btn = self.layoutHost:AddFancyButton(label, onPress, {
                x = Theme.MANAGER_PAGE_PAD + x,
                y = y,
                variant = variant,
                inline = true,
            })
        end)
        if btn ~= nil then
            self.bulkBarButtons[#self.bulkBarButtons + 1] = btn
            x = x + w + gap
        end
    end

    addFancy("Delete", "negative", function()
        self:_openConfirm({
            title = DELETE_CONFIRM_TITLE,
            confirmLabel = DELETE_CONFIRM_LABEL,
            confirmVariant = 'negative',
            body = self:_bulkDeleteConfirmBody(ids),
            onConfirm = function()
                self:BulkDelete(ids)
                self:_rebuild()
            end,
        })
    end)

    addFancy("New group", "positive", function()
        local newId = self:BulkNewGroup(ids)
        if type(newId) == "number" then self.pendingRenameId = newId end
        self:_rebuild()
    end)

    local scopes = self:ScopeList()
    local activeKey = self:ActiveScopeKey()
    local other
    for _, scope in ipairs(scopes) do
        if scope.key ~= activeKey then other = scope break end
    end
    if other ~= nil then
        local moveLabel = "Move to " .. (other.label or other.key)
        addFancy(moveLabel, "neutral", function()
            self:BulkMove(other.key, ids)
            self:_rebuild()
        end)
    end

    addFancy("Export", "neutral", function()
        self:BulkExport(ids)
    end)
end

function Manager:_rebuild()
    if self.contentParent == nil or ui == nil then
        return
    end
    if not self:_ensureTabs() then
        return
    end
    self:_clearChildren()
    self.lastSignature = self:_signature()

    local w, h = contentSize(self.contentParent)
    self.window.w, self.window.h = w, h

    self:_mountToolbar()

    local hasSel = self:HasSelection()
    local bulkY = Theme.MANAGER_TREE_TOP
    local treeTop = Theme.MANAGER_TREE_TOP
    if hasSel then
        self:_mountBulkBar(bulkY)
        treeTop = Theme.MANAGER_TREE_TOP + Theme.MANAGER_BULK_BAR_H + 4
    end
    self.treeTop = treeTop

    -- Tree: sibling of Tabs under contentParent, below the tab strip (and bulk bar when raised).
    -- Do NOT assign scrollable - read-only on ComponentCollection; writing it aborts the pcall
    -- and leaves no tree.
    local rowW = math.max(40, w - 2 * Theme.MANAGER_PAGE_PAD)
    local treeH = math.max(40, h - treeTop - Theme.MANAGER_PAGE_PAD)
    local treeOk = pcall(function()
        self.treePanel = ui.Panel.new(self.contentParent)
        self.treePanel.isVertical = true
        self.treePanel.spacing = 0
        self.treePanel.clickthrough = false
        self.treePanel:SetPos(Theme.MANAGER_PAGE_PAD, treeTop)
        self.treePanel:SetSize(rowW, treeH)
        self.treePanel:MoveToFront()
    end)
    if not treeOk or self.treePanel == nil then
        self.treePanel = nil
        return
    end

    local rows = self:VisibleRows()
    local treeParent = self.treePanel
    -- Native ui.Button ren/export/del; enable/select ui.Check; move arrows ui.Sprite.
    local baseNameW, headerNameW, headerMoveW, headerActionsW = managerColumnWidths(rowW, 0)
    pcall(function()
        local header = ui.Panel.new(treeParent)
        header.isVertical = false
        header.spacing = Theme.MANAGER_ROW_GAP
        header.clickthrough = true
        header:SetSize(rowW, Theme.MANAGER_HEADER_H)
        mountHeaderCell(header, Theme.MANAGER_ENABLE_W, Theme.MANAGER_HEADER_H, "Enabled", true)
        mountHeaderCell(header, Theme.MANAGER_SELECT_W, Theme.MANAGER_HEADER_H, "Select", true)
        mountHeaderCell(header, headerMoveW, Theme.MANAGER_HEADER_H, "Move", true)
        mountHeaderCell(header, headerNameW, Theme.MANAGER_HEADER_H, "Alert", false)
        mountHeaderCell(header, headerActionsW, Theme.MANAGER_HEADER_H, "Actions", true)
    end)
    for _, row in ipairs(rows) do
        local capturedRow = row
        local rowPanel = treeParent
        local okRow = pcall(function()
            rowPanel = ui.Panel.new(treeParent)
            rowPanel.isVertical = false
            rowPanel.spacing = Theme.MANAGER_ROW_GAP
            rowPanel.clickthrough = true
            rowPanel:SetSize(rowW, Theme.MANAGER_ROW_H)
        end)
        if not okRow or rowPanel == nil then
            rowPanel = treeParent
        end

        local selectX = Theme.MANAGER_ENABLE_W + Theme.MANAGER_ROW_GAP
        local upX = selectX + Theme.MANAGER_SELECT_W + Theme.MANAGER_ROW_GAP
        local downX = upX + Theme.MANAGER_REORDER_W + Theme.MANAGER_ROW_GAP
        local liftX = downX + Theme.MANAGER_REORDER_W + Theme.MANAGER_ROW_GAP
        -- Horizontal ui.Panel auto-layouts children (ADR-0007) - SetPos X is ignored. Indent by
        -- inserting a spacer before the name button; size it so spacer + layout gap + nameW
        -- equals baseNameW and the Rename column stays put across depths.
        local indent = (row.depth or 0) * Theme.MANAGER_ROW_INDENT
        local nameX = liftX + Theme.MANAGER_REORDER_W + Theme.MANAGER_ROW_GAP + indent
        local _, nameW = managerColumnWidths(rowW, row.depth)
        local canUp, canDown, canLift = self:RowMoveCaps(row.id)

        local enableMounted = false
        if ui.Check ~= nil then
            local check
            local okc = pcall(function() check = ui.Check.new(rowPanel) end)
            if okc and check ~= nil then
                pcall(function()
                    check.stylesheetID = safeCheckStyle()
                    check:SetPos(0, 0)
                    check:SetSize(Theme.MANAGER_ENABLE_W, Theme.MANAGER_ROW_H)
                    check.buttonSize = math.min(Theme.MANAGER_ENABLE_W - 2, Theme.MANAGER_ROW_H - 2)
                    check.value = row.enabled and true or false
                    check.label = ""
                    check:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
                        self:ToggleEnabled(capturedRow.id)
                        self:_rebuild()
                        return true
                    end)
                end)
                enableMounted = true
            end
        end
        if not enableMounted then
            local mark = row.enabled and "[x]" or "[ ]"
            mountButton(rowPanel, 0, 0, Theme.MANAGER_ENABLE_W, Theme.MANAGER_ROW_H, mark, function()
                self:ToggleEnabled(capturedRow.id)
                self:_rebuild()
            end)
        end

        -- Native ui.Check, not prettyui.CheckboxButton.
        local selectMounted = false
        if ui.Check ~= nil then
            local sel
            local oks = pcall(function() sel = ui.Check.new(rowPanel) end)
            if oks and sel ~= nil then
                pcall(function()
                    sel.stylesheetID = safeCheckStyle()
                    sel:SetPos(selectX, 0)
                    sel:SetSize(Theme.MANAGER_SELECT_W, Theme.MANAGER_ROW_H)
                    sel.buttonSize = math.min(Theme.MANAGER_SELECT_W - 2, Theme.MANAGER_ROW_H - 2)
                    sel.value = self.selected[row.id] and true or false
                    sel.label = ""
                    sel:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
                        self:ToggleSelection(capturedRow.id, isShiftDown())
                        self:_rebuild()
                        return true
                    end)
                end)
                selectMounted = true
            end
        end
        if not selectMounted then
            local mark = self.selected[row.id] and "[*]" or "[ ]"
            mountButton(rowPanel, selectX, 0, Theme.MANAGER_SELECT_W, Theme.MANAGER_ROW_H, mark, function()
                self:ToggleSelection(capturedRow.id, isShiftDown())
                self:_rebuild()
            end)
        end

        -- Sprite icons (client fonts are ASCII-only). Disabled sprite + no-op when illegal.
        do
            local function mountIconButton(x, y, w, h, sprite, spriteHover, spriteDisabled, isEnabled, onClick)
                local iconBtn
                local ok = pcall(function() iconBtn = ui.Sprite.new(rowPanel) end)
                if not ok or iconBtn == nil then return end
                pcall(function()
                    iconBtn.spriteID = isEnabled and sprite or spriteDisabled
                    iconBtn:SetPos(x, y)
                    iconBtn:SetSize(w, h)
                end)
                iconBtn:Subscribe(ui.Hook.ONCLICK, function()
                    if not isEnabled then return true end
                    onClick()
                    return true
                end)
                iconBtn:Subscribe(ui.Hook.ONMOUSEOVER, function()
                    if isEnabled then iconBtn.spriteID = spriteHover end
                end)
                iconBtn:Subscribe(ui.Hook.ONMOUSELEAVE, function()
                    if isEnabled then iconBtn.spriteID = sprite end
                end)
            end
            mountIconButton(upX, 0, Theme.MANAGER_REORDER_W, Theme.MANAGER_ROW_H,
                id.Sprite.RS3_ICON_DIRECTION_UP_32PX_2,
                id.Sprite.RS3_ICON_DIRECTION_UP_32PX_3,
                id.Sprite.RS3_ICON_DIRECTION_UP_32PX_4,
                canUp, function()
                    self:ReorderSibling(capturedRow.id, -1)
                    self:_rebuild()
                end)
            mountIconButton(downX, 0, Theme.MANAGER_REORDER_W, Theme.MANAGER_ROW_H,
                id.Sprite.RS3_ICON_DIRECTION_DOWN_32PX_2,
                id.Sprite.RS3_ICON_DIRECTION_DOWN_32PX_3,
                id.Sprite.RS3_ICON_DIRECTION_DOWN_32PX_4,
                canDown, function()
                    self:ReorderSibling(capturedRow.id, 1)
                    self:_rebuild()
                end)
            mountIconButton(liftX, 0, Theme.MANAGER_REORDER_W, Theme.MANAGER_ROW_H,
                id.Sprite.RS3_ICON_DIRECTION_LEFT_32PX_2,
                id.Sprite.RS3_ICON_DIRECTION_LEFT_32PX_3,
                id.Sprite.RS3_ICON_DIRECTION_LEFT_32PX_4,
                canLift, function()
                    self:Lift(capturedRow.id)
                    self:_rebuild()
                end)
        end

        -- Nesting indent: empty Panel so horizontal auto-layout shifts the name button right.
        -- spacerW + Theme.MANAGER_ROW_GAP + nameW == baseNameW keeps Rename/Export/Delete column-aligned.
        if indent > Theme.MANAGER_ROW_GAP then
            local spacerW = indent - Theme.MANAGER_ROW_GAP
            local spacer
            local okSp = pcall(function()
                spacer = ui.Panel.new(rowPanel)
                spacer.isVertical = false
                spacer.spacing = 0
                spacer.clickthrough = true
                spacer:SetSize(spacerW, Theme.MANAGER_ROW_H)
            end)
        end

        mountButton(rowPanel, nameX, 0, nameW, Theme.MANAGER_ROW_H, self:RowLabel(row), function()
            self:_onRowPress(capturedRow)
            if capturedRow.kind == "group" then self:_rebuild() end
        end)

        local renameX = nameX + nameW + Theme.MANAGER_ROW_GAP
        mountButton(rowPanel, renameX, 0, Theme.MANAGER_ACT_W, Theme.MANAGER_ROW_H, "Rename", function()
            local fieldY = 0
            pcall(function() fieldY = rowPanel.y or 0 end)
            -- content-local for layoutHost:AddTextField (not treePanel-local)
            self:_beginRename(
                capturedRow.id,
                capturedRow.name,
                Theme.MANAGER_PAGE_PAD + nameX,
                (self.treeTop or 0) + fieldY,
                nameW,
                Theme.MANAGER_ROW_H
            )
        end)

        local exportX = renameX + Theme.MANAGER_ACT_W + Theme.MANAGER_ROW_GAP
        mountButton(rowPanel, exportX, 0, Theme.MANAGER_ACT_W, Theme.MANAGER_ROW_H, "Export", function()
            self:ExportRow(capturedRow.id)
        end)

        local deleteX = exportX + Theme.MANAGER_ACT_W + Theme.MANAGER_ROW_GAP
        mountButton(rowPanel, deleteX, 0, Theme.MANAGER_ACT_W, Theme.MANAGER_ROW_H, "Delete", function()
            self:_onDeletePress(capturedRow.id)
        end)

        if self.pendingRenameId == row.id then
            self.pendingRenameId = nil
            local fieldY = 0
            pcall(function() fieldY = rowPanel.y or 0 end)
            self:_beginRename(
                row.id,
                row.name,
                Theme.MANAGER_PAGE_PAD + nameX,
                (self.treeTop or 0) + fieldY,
                nameW,
                Theme.MANAGER_ROW_H
            )
        end
    end

    if self.treePanel ~= nil then
        pcall(function()
            self.treePanel:SetScrollSize(rowW, Theme.MANAGER_HEADER_H + #rows * Theme.MANAGER_ROW_H)
        end)
    end

    if not self.visible then
        setChildVisible(componentRoot(self.tabs), false)
        for _, b in ipairs(self.toolbarButtons) do
            setChildVisible(componentRoot(b), false)
        end
        for _, b in ipairs(self.bulkBarButtons) do
            setChildVisible(componentRoot(b), false)
        end
        setChildVisible(self.treePanel, false)
        setChildVisible(componentRoot(self.renameField), false)
    end
end

---@param row Watchdog.ManagerRow
function Manager:_onRowPress(row)
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil then return end
    if row.kind == "group" then
        self:_activateRow(scopeKey, row)
        return
    end
    local isDouble = (row.id == self.lastRowId)
        and (self.tick - self.lastRowTick) <= Theme.DOUBLECLICK_TICKS
    self.lastRowId, self.lastRowTick = row.id, self.tick
    if isDouble then
        self.lastRowId = nil
        self:_activateRow(scopeKey, row)
    end
end

function Manager:Update()
    self.tick = self.tick + 1
    if not self.visible or self.tabs == nil then return end
    if self:_signature() ~= self.lastSignature then
        self:_rebuild()
    end
end

--- Client view: visibility / lifecycle ----------------------------------------------------

---@return boolean
function Manager:IsVisible()
    return self.visible
end

---@param v boolean
function Manager:SetVisible(v)
    local becomingVisible = v and not self.visible
    self.visible = v and true or false
    setChildVisible(componentRoot(self.tabs), self.visible)
    for _, b in ipairs(self.toolbarButtons) do
        setChildVisible(componentRoot(b), self.visible)
    end
    for _, b in ipairs(self.bulkBarButtons) do
        setChildVisible(componentRoot(b), self.visible)
    end
    setChildVisible(self.treePanel, self.visible)
    setChildVisible(componentRoot(self.renameField), self.visible)
    -- Transfer / Confirm are their own Windows under the mux root - close when Manager tucks away.
    if not self.visible then
        self:CloseTransfer()
        self:CloseConfirm()
    end
    if becomingVisible and self.tabs ~= nil then
        self:_rebuild()
    end
end

function Manager:Toggle()
    self:SetVisible(not self.visible)
end

function Manager:RaiseToFront()
end

-- Stop/Unmount must NOT :Destroy() Tabs/tree/toolbar. Those are children of the mux
-- prettyui.Window content; api.Stop then calls mux:Destroy() which Destroy()s the window
-- and its content tree. Destroying Tabs first, then the window, double-frees realized
-- components and freezes/crashes after the window has been shown. Clear Lua refs only -
-- the window Destroy owns native teardown. Mid-session rebuild still uses _destroyTree /
-- _destroyToolbar / _destroyTabs while the window stays alive.
function Manager:Unmount()
    self:_endRename(false)
    -- Transfer / Confirm live under the mux root (not mux content) - Destroy on Stop.
    self:CloseTransfer()
    self:CloseConfirm()
    self.toolbarButtons = {}
    self.bulkBarButtons = {}
    self.treePanel = nil
    self.treeTop = 0
    self.tabs = nil
    self.tabsScopeSig = nil
    self.contentParent = nil
    self.layoutHost = nil
end

return Manager
