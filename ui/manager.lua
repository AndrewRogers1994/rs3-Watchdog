-- manager.lua — the Alert Manager: the second surface beside the Canvas Editor.
--
-- The management surface the F8 keybind and the LibPluginMenu button open (through the nav
-- owner in main.lua): a scope **tab bar** over a tree of Entries. Hybrid PrettyUI + native
-- `ui.Panel` (ADR-0007 + docs/alert-manager-prettyui.md): PrettyUI `Tabs` / toolbar /
-- TextField rename; native horizontal row Panels + native ren/del buttons for the tree strip.
-- NOT the Editor's Canvas — a scrolling list has neither pan nor zoom.
--
-- Window chrome (title bar, frame, drag) lives on the host Multiplexer / PrettyUI window.
-- This module mounts **content only** into an external parent (`mux:Content()`):
-- PrettyUI Tabs sized to the tab strip only + FancyButtons on tabs.root + a sibling native
-- tree Panel below the strip. Tabs must NOT fill the window height — a full-height Tabs
-- paints empty page content over the tree. Mid-session rebuild destroys tree/toolbar via
-- parent Panel; Stop/Unmount only clears Lua refs (mux window Destroy owns native teardown —
-- Destroying Tabs then the window double-frees after Show).
--
-- #90 landed the tree/scope/expand read-only cut; #91 adds the per-row editing ops; PrettyUI
-- chrome migration replaces hand-laid tab buttons and ASCII ren/del. Multi-select + bulk
-- actions are #93; export/import copy-paste (#94) is a transfer modal over a ui.InputField.
-- Sibling Up/Down + Lift are per-row sprite buttons; drag nest / cross-scope stays on #92.
--
-- ## Two halves
--
-- The tree/scope/expand/mutation logic is **pure** (no `ui.*`): it walks a `Watchdog.Bucket`
-- into a flat list of visible rows, tracks per-scope collapse state, resolves the active scope
-- against the injected scope provider, and reports mutations through host callbacks. That half
-- is unit-tested headless (tests/test_manager.lua). The mount / render half is client-only and
-- pcall-guarded, the same split every other surface in this plugin uses.

local Theme = require("ui/theme")
local Export = require("export")

local Manager = {}
Manager.__index = Manager

-- A scope descriptor the injected provider hands back: which Bucket, how to label its tab, and its
-- tree to render. `key` is the Bucket's `PersistentDB` key (`global` / `player_<normalized>`) — the
-- same string main.lua persists and resolves live graphs under, so a row-open can round-trip it.
---@class Watchdog.ManagerScope
---@field key string                 # the Bucket key ("global" | "player_<normalized>")
---@field label string               # tab text ("Global" | the character's display name)
---@field doc Watchdog.Bucket        # the Bucket document whose Entry tree renders under this tab

-- One flattened visible tree row (what the pure walk produces and the view renders one-for-one).
-- A collapsed group's descendants are simply absent from the list, so the renderer needs no
-- collapse logic of its own.
---@class Watchdog.ManagerRow
---@field id integer                  # the Entry id (the key a row-open reports back)
---@field name string                 # display text
---@field kind "alert"|"group"
---@field depth integer               # 0 at root; each nesting level adds one (→ Theme.MANAGER_ROW_INDENT px)
---@field childCount integer|nil      # group only: number of DIRECT children
---@field expanded boolean            # group only: whether its children are shown (false for alerts)
---@field enabled boolean             # the Entry's own enabled flag (drives the row enable Check)

--- Construction ---------------------------------------------------------------------------

-- The Manager's whole seam onto its host: the scope provider, the alert-open callback, and the
-- #91 mutation callbacks (enable / rename / delete / create). Persistence + runtime sync live in
-- the host (main.lua); the Manager only reports the op and bumps its rebuild signature.
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
---@field windowParent fun(): any|nil  # parent Layer for the transfer Window (mux.rootLayer — plugin-owned)

-- `scopes` is the injected scope provider: `fn() -> Watchdog.ManagerScope[]`, ordered (Global
-- first, the current character second when logged in). Called live on every rebuild so a character
-- login/logout re-tabs without the Manager caching identity. `onOpenAlert` is the nav callback
-- `fn(scopeKey, id)` fired when an alert row is double-clicked — main.lua's nav owner binds the
-- Editor to that entry. The #91 mutation callbacks (`onToggleEnabled` / `onRename` / `onDelete` /
-- `onCreateAlert` / `onCreateGroup`) and the #93 bulk callbacks are the host's Store+Runtime
-- wiring; absent ⇒ the matching Manager method is a silent no-op. All of these are the whole
-- seam onto the host.
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
        activeScope = nil,          -- resolved lazily; nil ⇒ "first scope" (Global)
        expanded = {},              -- expanded[scopeKey][id] = bool; absent ⇒ default (expanded)
        expandVersion = 0,          -- bumped on every toggle, part of the rebuild signature
        mutateVersion = 0,          -- bumped on every row/create mutation (#91) so enable/rename redraw
        selected = {},              -- selected[id] = true; antichain after every toggle (#93)
        selectVersion = 0,          -- bumped on every selection change; part of rebuild signature
        lastSelectId = nil,         -- anchor for Shift-click range over VisibleRows()
        visible = false,
        tick = 0,                   -- Logic-tick counter, for row double-click timing
        lastRowId = nil,            -- id of the previously-pressed row (double-click pairing)
        lastRowTick = -1000,
        -- Layout size only (no screen placement — host/mux owns the window chrome).
        window = {
            w = Theme.WINDOW_W, h = Theme.WINDOW_H,
        },
        -- Client-only component handles (nil until Mount); see the render half below.
        contentParent = nil,        -- external parent (mux Content / rootWindow.content)
        tabs = nil,                 -- prettyui.Tabs instance
        tabsScopeSig = nil,         -- scope key:label signature Tabs was built from
        treePanel = nil,
        bulkBarButtons = {},        -- PrettyUI FancyButtons / SpriteButton on the bulk bar
        toolbarButtons = {},        -- PrettyUI FancyButtons on the active tab page
        lastSignature = nil,        -- last-rendered rebuild signature (skip no-op rebuilds)
        -- Inline rename: PrettyUI TextField + the Entry id it's editing, or nil when idle.
        renameField = nil,
        renameId = nil,
        -- Delete confirm (#91): Entry id awaiting confirm, or nil when idle.
        pendingDeleteId = nil,
        -- Bulk delete confirm (#93): true while the bulk Delete button awaits a second press.
        pendingBulkDelete = false,
        -- After + Group (#78): begin inline rename on this id once the row is rebuilt.
        pendingRenameId = nil,
        -- Transfer modal (#94): separate prettyui.Window (not an in-content overlay).
        transfer = nil,             -- { mode, text, message }|nil
        transferWindow = nil,
        transferField = nil,
    }, Manager)
    return self
end

--- Pure logic: scopes ---------------------------------------------------------------------

-- The live scope list from the injected provider (always at least `Global`). Guarded so a throwing
-- provider degrades to an empty list rather than taking the frame down.
---@return Watchdog.ManagerScope[]
function Manager:ScopeList()
    local ok, scopes = pcall(self.scopesProvider)
    if ok and type(scopes) == "table" then return scopes end
    return {}
end

-- The active scope descriptor: the one whose `key` matches `self.activeScope`, or the first scope
-- (Global) when nothing is selected or the selection no longer exists (its character logged out /
-- switched). Returns nil only when the provider yielded no scopes at all.
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

-- The active scope's Bucket key, or nil when there are no scopes. Resolves through ActiveScope so a
-- stale `self.activeScope` (a since-departed character) reports the fallen-back-to key, not the dead one.
---@return string|nil
function Manager:ActiveScopeKey()
    local scope = self:ActiveScope()
    return scope and scope.key or nil
end

-- Selects the scope tab `key` renders. Clears the double-click pairing so a click that switched
-- tabs can't accidentally pair with a row press in the newly-shown tree. Clears selection (#93):
-- a scope switch replaces the visible list.
---@param key string
function Manager:SetActiveScope(key)
    self.activeScope = key
    self.lastRowId = nil
    self:ClearSelection()
end

--- Pure logic: expand/collapse ------------------------------------------------------------

-- Whether group `id` in scope `scopeKey` is expanded. Groups default to **expanded** (an untouched
-- tree shows all its nesting and child counts on first open); a toggle records the explicit state.
---@param scopeKey string
---@param id integer
---@return boolean
function Manager:IsExpanded(scopeKey, id)
    local perScope = self.expanded[scopeKey]
    if perScope == nil or perScope[id] == nil then return true end
    return perScope[id]
end

-- True if `maybeDescendant` is `ancestorId` itself or nested under it in the active scope tree.
---@param ancestorId integer
---@param maybeDescendant integer
---@return boolean
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

-- Flips group `id`'s expand state in scope `scopeKey` and bumps the rebuild signature so the view
-- redraws. On collapse, drops any selection inside the group (#93) — those rows leave the visible
-- list. Read-only otherwise — no persistence; collapse state is transient session UI.
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
            self.pendingBulkDelete = false
        end
    end
end

--- Pure logic: tree flattening ------------------------------------------------------------

-- Walks a scope's Entry tree depth-first pre-order into the flat visible-row list, honoring
-- collapse: a collapsed group contributes its own row but none of its subtree. Shared by the
-- renderer and the tests; the one place tree shape becomes screen order.
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

-- The active scope's visible rows, in render order. Empty when there are no scopes or the active
-- tree is empty.
---@return Watchdog.ManagerRow[]
function Manager:VisibleRows()
    local scope = self:ActiveScope()
    if scope == nil then return {} end
    return flatten(self, (scope.doc or {}).entries, scope.key, 0, {})
end

-- Reacts to a row press (pure part, so the double-click gating in the view can be tested against
-- it): a group toggles expand; an alert reports up through onOpenAlert. `scopeKey` is captured at
-- press time so a row opened just as a tab switches still targets the tree it was drawn from.
---@param scopeKey string
---@param row Watchdog.ManagerRow
function Manager:_activateRow(scopeKey, row)
    if row.kind == "group" then
        self:ToggleExpand(scopeKey, row.id)
    elseif row.kind == "alert" then
        pcall(self.onOpenAlert, scopeKey, row.id)
    end
end

--- Pure logic: row editing ops (#91) ------------------------------------------------------
-- Each method reports through the matching host callback (main.lua wires Store + Runtime) and
-- bumps `mutateVersion` so the rebuild signature changes even when the root entry count does
-- not (enable / rename). A missing active scope or missing callback is a silent no-op.

local function bumpMutate(self)
    self.mutateVersion = self.mutateVersion + 1
end

-- Flips the Entry's own `enabled` via the host. The host re-evaluates the enabled-chain.
---@param id integer
function Manager:ToggleEnabled(id)
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil or self.onToggleEnabled == nil then return end
    pcall(self.onToggleEnabled, scopeKey, id)
    bumpMutate(self)
end

-- Renames the Entry via the host.
---@param id integer
---@param name string
function Manager:Rename(id, name)
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil or self.onRename == nil then return end
    pcall(self.onRename, scopeKey, id, name)
    bumpMutate(self)
end

-- Deletes the Entry (and its subtree) via the host. Confirm UI is the caller's job — this is the
-- committed delete.
---@param id integer
function Manager:Delete(id)
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil or self.onDelete == nil then return end
    pcall(self.onDelete, scopeKey, id)
    bumpMutate(self)
end

-- Locates `id` in `entries`, returning the entry, its sibling array, index, and parent Entry
-- (nil at root). Used for ↑/↓/Lift enablement without a Store dependency.
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

-- Whether ↑ / ↓ / Lift are legal for `id` in the active scope (tree siblings only).
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

-- Swaps the Entry one step among its siblings via the host (`delta` -1 = up, +1 = down).
---@param id integer
---@param delta integer
function Manager:ReorderSibling(id, delta)
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil or self.onReorderSibling == nil then return end
    pcall(self.onReorderSibling, scopeKey, id, delta)
    bumpMutate(self)
end

-- Lifts the Entry one level toward the root via the host (insert before former parent).
---@param id integer
function Manager:Lift(id)
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil or self.onLift == nil then return end
    pcall(self.onLift, scopeKey, id)
    bumpMutate(self)
end

-- Asks the host to mint + insert a new alert at the active scope root (and typically open it).
-- Returns the minted id when the host provides one.
---@return integer|nil
function Manager:CreateAlert()
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil or self.onCreateAlert == nil then return nil end
    local ok, id = pcall(self.onCreateAlert, scopeKey)
    bumpMutate(self)
    if ok and type(id) == "number" then return id end
    return nil
end

-- Asks the host to mint + insert a new empty group at the active scope root. Returns the minted
-- id when the host provides one (so the view can open an inline rename on the new row, #78).
---@return integer|nil
function Manager:CreateGroup()
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil or self.onCreateGroup == nil then return nil end
    local ok, id = pcall(self.onCreateGroup, scopeKey)
    bumpMutate(self)
    if ok and type(id) == "number" then return id end
    return nil
end

--- Pure logic: multi-select (#93) ---------------------------------------------------------
-- Selection is a map `id → true`, normalized to a group-as-unit **antichain** after every
-- toggle: a selected group represents its whole subtree, so no descendant is separately
-- selected (and checkboxes never go tri-state). Shift-click ranges over VisibleRows() order.

local function bumpSelect(self)
    self.selectVersion = self.selectVersion + 1
    self.pendingBulkDelete = false
end

-- Ancestor id chain of `id` in `entries`, outermost-first (root → parent). Empty when `id` is
-- root-level or absent. Pure walk shared by NormalizeSelection.
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

-- Drops any selected id that has an ancestor also selected — group-as-unit antichain.
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

-- Clears the selection map. Bumps selectVersion only when something was actually selected.
function Manager:ClearSelection()
    local any = false
    for _ in pairs(self.selected) do any = true break end
    self.selected = {}
    self.lastSelectId = nil
    self.pendingBulkDelete = false
    if any then bumpSelect(self) end
end

---@return boolean
function Manager:HasSelection()
    for _ in pairs(self.selected) do return true end
    return false
end

-- Selected ids in VisibleRows() order (antichain members only after NormalizeSelection).
---@return integer[]
function Manager:SelectedIds()
    local out = {}
    for _, row in ipairs(self:VisibleRows()) do
        if self.selected[row.id] then out[#out + 1] = row.id end
    end
    return out
end

-- Toggles `id` in the selection. When `shift` is true and there is a prior anchor, selects the
-- inclusive VisibleRows() range from the anchor to `id` (additive). Always re-normalizes to an
-- antichain afterwards and bumps selectVersion.
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

-- Host-facing bulk ops. Each reports through the matching callback and bumps mutateVersion.
-- Confirm UI for delete is the caller's / view's job — BulkDelete is the committed delete.

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
    -- Preserve selection across export (#93).
    self:_runExport(ids)
end

-- Whole-scope export (#94 entry point 1): every root Entry in the active Bucket.
function Manager:ExportScope()
    self:_runExport(nil)
end

-- Single-row subtree export (#94 entry point 2).
---@param id integer
function Manager:ExportRow(id)
    if type(id) ~= "number" then return end
    self:_runExport({ id })
end

-- Shared encode → transfer modal path for every export entry point.
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

-- Opens an empty import modal for the active scope (#94).
function Manager:OpenImport()
    self:_openTransfer("import", "", "Paste an export envelope, then Import.")
end

-- Tears down the transfer modal without applying.
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

-- Commit the import field. Failures stay in the modal with the pasted text intact (#79).
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

-- Tear down the open transfer Window only — keeps `self.transfer` so remount can rebuild.
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

-- A cheap string capturing everything the rendered tree depends on: the active scope, the expand
-- generation, the mutate generation (#91 — enable/rename don't change root count), the select
-- generation (#93), and each scope's key+label+entry-count. The view rebuilds only when this
-- changes, so a character login (new tab), a scope switch, an expand toggle, a row mutation, or a
-- selection change redraws — but an idle frame doesn't.
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

-- The one-line label a row's name button renders: a chevron for a group (▾ open / ▸
-- collapsed), an icon, the name, and a group's direct-child count. Nesting indent is layout
-- (Theme.MANAGER_ROW_INDENT on the name button), not leading spaces. Kept pure so the exact string is
-- assertable in tests without a mounted component. Enable / rename / delete are sibling
-- controls (#91), not baked into this string.
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

-- Content rect size: prefer the parent's width/height when available, else Theme defaults.
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

-- Apply hidden/enabled to a single content child (tabs root, tree, rename field).
---@param comp ui.Component|nil
---@param visible boolean
local function setChildVisible(comp, visible)
    if comp == nil then return end
    pcall(function()
        comp.hidden = not visible
        comp.enabled = visible
    end)
end

-- PrettyUI component root (wrappers expose `.root`; native components are themselves).
---@param comp any
---@return any
local function componentRoot(comp)
    if comp == nil then return nil end
    if type(comp) == "table" and comp.root ~= nil then return comp.root end
    return comp
end

-- Signature of scope tabs only (key+label). Recreate PrettyUI Tabs when this changes
-- (login/logout); keep Tabs across expand/enable/rename rebuilds.
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

-- Destroys create-toolbar FancyButtons parented to tabs.root.
function Manager:_destroyToolbar()
    for _, b in ipairs(self.toolbarButtons) do
        pcall(function() b:Destroy() end)
    end
    self.toolbarButtons = {}
end

-- Destroys bulk-action bar FancyButtons / SpriteButtons (#93).
function Manager:_destroyBulkBar()
    for _, b in ipairs(self.bulkBarButtons) do
        pcall(function() b:Destroy() end)
    end
    self.bulkBarButtons = {}
end

-- Destroys the tree Panel (row children die with it).
function Manager:_destroyTree()
    self:_endRename(false)
    if self.treePanel ~= nil then
        pcall(function() self.treePanel:Destroy() end)
        self.treePanel = nil
    end
end

-- Live rebuild helper: tear down toolbar + Tabs when the scope list changes.
-- NOT used from Unmount/Stop — see Unmount (must not Destroy before mux window Destroy).
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

-- Ensures PrettyUI Tabs match the live scope list. Recreates on scope key/label change;
-- otherwise syncs the active tab without notifying (avoids rebuild re-entrancy).
---@return boolean
function Manager:_ensureTabs()
    if prettyui == nil or prettyui.Tabs == nil or self.contentParent == nil then
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
        tabs = prettyui.Tabs.new(self.contentParent, entries, {
            x = 0,
            y = 0,
            width = 0,
            widthAnchor = 1.0,
            height = Theme.MANAGER_TAB_BASELINE + 1,
            scrollable = false,
            activeIndex = activeIndex,
            onChange = function(_, _index, value, _page)
                self.pendingDeleteId = nil
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
function Manager:Mount(contentParent)
    if ui == nil or ui.Panel == nil then
        if log ~= nil then log("Watchdog: ui.Panel unavailable, Manager Mount aborted") end
        return
    end
    if prettyui == nil or prettyui.Tabs == nil then
        if log ~= nil then log("Watchdog: prettyui.Tabs unavailable, Manager Mount aborted") end
        return
    end

    self.contentParent = contentParent
    local w, h = contentSize(contentParent)
    self.window.w, self.window.h = w, h

    if not self:_ensureTabs() then
        self.contentParent = nil
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

-- Helper: mount a Button under `parent` with text `label`, at (x,y)/(w,h), wired to `onPress`.
-- When `enabled` is false the button is shown disabled and presses are ignored.
---@param parent ui.ComponentCollection
---@param x number
---@param y number
---@param w number
---@param h number
---@param label string
---@param onPress fun()
---@param enabled boolean|nil
---@return ui.Button|nil
-- Column widths shared by the tree header and each row (depth 0 for the header).
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

-- One header label cell: fixed width in the row's horizontal auto-layout strip.
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

-- Commits (or abandons) the inline rename TextField.
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

-- Mounts a transient PrettyUI TextField over the name slot for Entry `id`.
---@param id integer
---@param name string
---@param x number
---@param y number
---@param w number
---@param h number
function Manager:_beginRename(id, name, x, y, w, h)
    self:_endRename(false)
    if self.treePanel == nil or prettyui == nil or prettyui.TextField == nil then return end
    local field
    local ok = pcall(function()
        field = prettyui.TextField.new(self.treePanel, {
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
    if self.pendingDeleteId == id then
        self.pendingDeleteId = nil
        self:Delete(id)
        self:_rebuild()
    else
        self.pendingDeleteId = id
        self:_rebuild()
    end
end

---@param id integer
---@return integer
function Manager:_descendantCount(id)
    local scope = self:ActiveScope()
    if scope == nil or scope.doc == nil then return 0 end
    local function find(entries)
        for _, e in ipairs(entries or {}) do
            if e.id == id then return e end
            if e.children ~= nil then
                local found = find(e.children)
                if found ~= nil then return found end
            end
        end
        return nil
    end
    local entry = find((scope.doc or {}).entries)
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
function Manager:_deleteConfirmLabel(id)
    local n = self:_descendantCount(id)
    if n > 0 then return "OK " .. tostring(n) .. "?" end
    return "OK?"
end

-- Ride-along descendant count across a multi-select set (for the bulk Delete confirm label).
---@param ids integer[]|nil
---@return integer
function Manager:_bulkRideAlongCount(ids)
    local n = 0
    for _, id in ipairs(ids or self:SelectedIds()) do
        n = n + self:_descendantCount(id)
    end
    return n
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

-- + Alert / + Group / Import / Export on the PrettyUI tab strip (right-aligned), visually
-- inline with the tabs. Import/Export sit left of the create buttons so they never cover
-- the Global / character tab labels.
-- PrettyUI Tabs has no trailing-actions API; parenting FancyButtons to tabs.root is the
-- supported workaround.
function Manager:_mountToolbar()
    if self.tabs == nil or self.tabs.root == nil or prettyui == nil then return end
    if prettyui.FancyButton == nil then return end
    local root = self.tabs.root
    local alertW, groupW, importW, exportW = 75, 75, 70, 70
    pcall(function()
        alertW = select(1, prettyui.FancyButton.getSize("+ Alert", { variant = "positive" }))
        groupW = select(1, prettyui.FancyButton.getSize("+ Group", { variant = "neutral" }))
        importW = select(1, prettyui.FancyButton.getSize("Import", { variant = "neutral" }))
        exportW = select(1, prettyui.FancyButton.getSize("Export", { variant = "neutral" }))
    end)
    local y = math.max(0, math.floor((Theme.MANAGER_TAB_BASELINE - Theme.MANAGER_TOOLBAR_H) / 2))
    local group, alert, importBtn, exportBtn
    -- Right-edge packing: [Import][Export][+ Alert][+ Group]  (rightmost = Group)
    local xGroup = -Theme.MANAGER_TOOLBAR_PAD - groupW
    local xAlert = xGroup - Theme.MANAGER_TOOLBAR_GAP - alertW
    local xExport = xAlert - Theme.MANAGER_TOOLBAR_GAP - exportW
    local xImport = xExport - Theme.MANAGER_TOOLBAR_GAP - importW
    pcall(function()
        group = prettyui.FancyButton.new(root, "+ Group", function()
            local id = self:CreateGroup()
            if type(id) == "number" then self.pendingRenameId = id end
            self:_rebuild()
        end, {
            x = xGroup,
            y = y,
            xAnchor = 1.0,
            variant = "neutral",
        })
        alert = prettyui.FancyButton.new(root, "+ Alert", function()
            self:CreateAlert()
            self:_rebuild()
        end, {
            x = xAlert,
            y = y,
            xAnchor = 1.0,
            variant = "positive",
        })
        exportBtn = prettyui.FancyButton.new(root, "Export", function()
            self:ExportScope()
        end, {
            x = xExport,
            y = y,
            xAnchor = 1.0,
            variant = "neutral",
        })
        importBtn = prettyui.FancyButton.new(root, "Import", function()
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

-- Copy-paste transfer as its own prettyui.Window (#94): titled chrome + AddText /
-- AddTextField / AddFancyButton. Parent is the mux-owned root Layer (same pattern as the
-- main shell) so poff / plugins_reload / Stop tear the dialog down with the plugin — never
-- parent directly to the game area. Oversize exports open in error mode with no payload.
-- Save-to-file is present but disabled pending a filesystem API.
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
                        -- not a thing right now
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

-- Bulk-action bar (#93): Delete / New group / Move (when another scope exists) / Export.
-- Sibling of Tabs under contentParent, between the tab strip and the tree.
function Manager:_mountBulkBar(y)
    if not self:HasSelection() then return end
    if self.contentParent == nil or prettyui == nil or prettyui.FancyButton == nil then return end
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
            btn = prettyui.FancyButton.new(self.contentParent, label, onPress, {
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

    local delLabel = "Delete"
    if self.pendingBulkDelete then
        local ride = self:_bulkRideAlongCount(ids)
        delLabel = ride > 0 and ("OK " .. tostring(ride) .. "?") or "OK?"
    end
    addFancy(delLabel, "negative", function()
        if self.pendingBulkDelete then
            self.pendingBulkDelete = false
            self:BulkDelete(ids)
            self:_rebuild()
        else
            self.pendingBulkDelete = true
            self:_rebuild()
        end
    end)

    addFancy("New group", "positive", function()
        local newId = self:BulkNewGroup(ids)
        if type(newId) == "number" then self.pendingRenameId = newId end
        self:_rebuild()
    end)

    -- Move: only when another scope is available (logged in).
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

    if prettyui.SpriteButton ~= nil then
        local exportBtn
        pcall(function()
            exportBtn = prettyui.SpriteButton.new(self.contentParent, "EXPORT", function()
                self:BulkExport(ids)
            end, {
                x = Theme.MANAGER_PAGE_PAD + x,
                y = y,
                inline = true,
                tooltip = "Export selected",
            })
        end)
        if exportBtn ~= nil then
            self.bulkBarButtons[#self.bulkBarButtons + 1] = exportBtn
        end
    else
        addFancy("Export", "neutral", function()
            self:BulkExport(ids)
        end)
    end
end

-- Rebuilds toolbar + bulk bar + tree rows. Tabs recreate only when the scope-list signature changes.
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

    -- Tree: sibling of Tabs under contentParent, below the tab strip (and bulk bar when raised).
    -- Do NOT assign scrollable — read-only on ComponentCollection; writing it aborts the pcall
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
    -- Native ui.Button ren/export/del — PrettyUI SpriteButton crashes client teardown after PluginShutdown.
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
        -- Horizontal ui.Panel auto-layouts children (ADR-0007) — SetPos X is ignored. Indent by
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
                        self.pendingDeleteId = nil
                        self.pendingBulkDelete = false
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
                self.pendingDeleteId = nil
                self.pendingBulkDelete = false
                self:ToggleEnabled(capturedRow.id)
                self:_rebuild()
            end)
        end

        -- Select column (#93): separate native ui.Check — not prettyui.CheckboxButton.
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
                        self.pendingDeleteId = nil
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
                self.pendingDeleteId = nil
                self:ToggleSelection(capturedRow.id, isShiftDown())
                self:_rebuild()
            end)
        end

        -- Sibling Up/Down/Lift: sprite icons after select (client fonts are ASCII-only).
        -- Always visible; disabled sprite + no-op click when illegal.
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
                    self.pendingDeleteId = nil
                    self.pendingBulkDelete = false
                    self:ReorderSibling(capturedRow.id, -1)
                    self:_rebuild()
                end)
            mountIconButton(downX, 0, Theme.MANAGER_REORDER_W, Theme.MANAGER_ROW_H,
                id.Sprite.RS3_ICON_DIRECTION_DOWN_32PX_2,
                id.Sprite.RS3_ICON_DIRECTION_DOWN_32PX_3,
                id.Sprite.RS3_ICON_DIRECTION_DOWN_32PX_4,
                canDown, function()
                    self.pendingDeleteId = nil
                    self.pendingBulkDelete = false
                    self:ReorderSibling(capturedRow.id, 1)
                    self:_rebuild()
                end)
            mountIconButton(liftX, 0, Theme.MANAGER_REORDER_W, Theme.MANAGER_ROW_H,
                id.Sprite.RS3_ICON_DIRECTION_LEFT_32PX_2,
                id.Sprite.RS3_ICON_DIRECTION_LEFT_32PX_3,
                id.Sprite.RS3_ICON_DIRECTION_LEFT_32PX_4,
                canLift, function()
                    self.pendingDeleteId = nil
                    self.pendingBulkDelete = false
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
            self.pendingDeleteId = nil
            self.pendingBulkDelete = false
            self:_onRowPress(capturedRow)
            if capturedRow.kind == "group" then self:_rebuild() end
        end)

        local renameX = nameX + nameW + Theme.MANAGER_ROW_GAP
        mountButton(rowPanel, renameX, 0, Theme.MANAGER_ACT_W, Theme.MANAGER_ROW_H, "Rename", function()
            self.pendingDeleteId = nil
            self.pendingBulkDelete = false
            local fieldY = 0
            pcall(function() fieldY = rowPanel.y or 0 end)
            self:_beginRename(capturedRow.id, capturedRow.name, nameX, fieldY, nameW, Theme.MANAGER_ROW_H)
        end)

        local exportX = renameX + Theme.MANAGER_ACT_W + Theme.MANAGER_ROW_GAP
        mountButton(rowPanel, exportX, 0, Theme.MANAGER_ACT_W, Theme.MANAGER_ROW_H, "Export", function()
            self.pendingDeleteId = nil
            self.pendingBulkDelete = false
            self:ExportRow(capturedRow.id)
        end)

        local deleteX = exportX + Theme.MANAGER_ACT_W + Theme.MANAGER_ROW_GAP
        local armed = self.pendingDeleteId == row.id
        local delLabel = armed and self:_deleteConfirmLabel(row.id) or "Delete"
        local delW = math.max(Theme.MANAGER_ACT_W, 8 + 7 * #delLabel)
        mountButton(rowPanel, deleteX, 0, delW, Theme.MANAGER_ROW_H, delLabel, function()
            self.pendingBulkDelete = false
            self:_onDeletePress(capturedRow.id)
        end)

        if self.pendingRenameId == row.id then
            self.pendingRenameId = nil
            local fieldY = 0
            pcall(function() fieldY = rowPanel.y or 0 end)
            self:_beginRename(row.id, row.name, nameX, fieldY, nameW, Theme.MANAGER_ROW_H)
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
    -- Transfer is its own Window under the game root — close it when the Manager tucks away.
    if not self.visible then
        self:CloseTransfer()
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
-- components and freezes/crashes after the window has been shown. Clear Lua refs only —
-- the window Destroy owns native teardown. Mid-session rebuild still uses _destroyTree /
-- _destroyToolbar / _destroyTabs while the window stays alive.
function Manager:Unmount()
    self.pendingDeleteId = nil
    self.pendingBulkDelete = false
    self:_endRename(false)
    -- Transfer Window lives under the game root (not mux content) — Destroy it on Stop.
    self:CloseTransfer()
    self.toolbarButtons = {}
    self.bulkBarButtons = {}
    self.treePanel = nil
    self.tabs = nil
    self.tabsScopeSig = nil
    self.contentParent = nil
end

return Manager
