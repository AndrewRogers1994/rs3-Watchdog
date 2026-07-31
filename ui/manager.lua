-- manager.lua — the Alert Manager: the second surface beside the Canvas Editor.
--
-- The management surface the F8 keybind and the LibPluginMenu button open (through the nav
-- owner in main.lua): a scope **tab bar** over a tree of Entries. Hybrid PrettyUI + native
-- `ui.Panel` (ADR-0007 + docs/alert-manager-prettyui.md): PrettyUI `Tabs` / toolbar /
-- SpriteButton actions / TextField rename; native horizontal row Panels for the tree strip.
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
-- chrome migration replaces hand-laid tab buttons and ASCII ren/del. Drag-reorder and
-- multi-select are later tickets (#92, #93).
--
-- ## Two halves
--
-- The tree/scope/expand/mutation logic is **pure** (no `ui.*`): it walks a `Watchdog.Bucket`
-- into a flat list of visible rows, tracks per-scope collapse state, resolves the active scope
-- against the injected scope provider, and reports mutations through host callbacks. That half
-- is unit-tested headless (tests/test_manager.lua). The mount / render half is client-only and
-- pcall-guarded, the same split every other surface in this plugin uses.

local Theme = require("ui/theme")

local Manager = {}
Manager.__index = Manager

-- Layout constants (content-parent-local / tab-strip-local).
-- PrettyUI Tabs uses TAB_BASELINE ≈ 42 for the tab header strip (see prettyui/src/tabs.lua).
local TAB_BASELINE = 42
local ROW_H       = 22    -- one tree row
local ENABLE_W    = 22    -- enable toggle width
local ACT_W       = 24    -- PrettyUI SpriteButton default size
local ROW_GAP     = 2     -- gap between controls inside a row
local PAGE_PAD    = 8     -- inset from content edge for the tree
local TOOLBAR_H   = 27    -- PrettyUI FancyButton height
local TOOLBAR_PAD = 8     -- right inset for + Alert / + Group on the tab strip
local TOOLBAR_GAP = 6     -- gap between create buttons
local TREE_TOP    = TAB_BASELINE + 4 -- tree sits below the PrettyUI tab strip


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
---@field depth integer               # 0 at root; each nesting level adds one (→ ROW_INDENT px)
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
---@field onCreateAlert fun(scopeKey: string): integer|nil   # returns the minted alert id
---@field onCreateGroup fun(scopeKey: string): integer|nil   # returns the minted group id

-- `scopes` is the injected scope provider: `fn() -> Watchdog.ManagerScope[]`, ordered (Global
-- first, the current character second when logged in). Called live on every rebuild so a character
-- login/logout re-tabs without the Manager caching identity. `onOpenAlert` is the nav callback
-- `fn(scopeKey, id)` fired when an alert row is double-clicked — main.lua's nav owner binds the
-- Editor to that entry. The #91 mutation callbacks (`onToggleEnabled` / `onRename` / `onDelete` /
-- `onCreateAlert` / `onCreateGroup`) are the host's Store+Runtime wiring; absent ⇒ the matching
-- Manager method is a silent no-op. All of these are the whole seam onto the host.
---@param opts Watchdog.ManagerOpts|nil
---@return table
function Manager.new(opts)
    local self = setmetatable({
        scopesProvider = (opts and opts.scopes) or function() return {} end,
        onOpenAlert = (opts and opts.onOpenAlert) or function() end,
        onToggleEnabled = opts and opts.onToggleEnabled,
        onRename = opts and opts.onRename,
        onDelete = opts and opts.onDelete,
        onCreateAlert = opts and opts.onCreateAlert,
        onCreateGroup = opts and opts.onCreateGroup,
        activeScope = nil,          -- resolved lazily; nil ⇒ "first scope" (Global)
        expanded = {},              -- expanded[scopeKey][id] = bool; absent ⇒ default (expanded)
        expandVersion = 0,          -- bumped on every toggle, part of the rebuild signature
        mutateVersion = 0,          -- bumped on every row/create mutation (#91) so enable/rename redraw
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
        toolbarButtons = {},        -- PrettyUI FancyButtons on the active tab page
        rowButtons = {},            -- native row Panels (teardown destroys children)
        rowWidgets = {},            -- PrettyUI SpriteButton / FancyButton wrappers on rows
        lastSignature = nil,        -- last-rendered rebuild signature (skip no-op rebuilds)
        -- Inline rename: PrettyUI TextField + the Entry id it's editing, or nil when idle.
        renameField = nil,
        renameId = nil,
        -- Delete confirm (#91): Entry id awaiting confirm, or nil when idle.
        pendingDeleteId = nil,
        -- After + Group (#78): begin inline rename on this id once the row is rebuilt.
        pendingRenameId = nil,
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
-- tabs can't accidentally pair with a row press in the newly-shown tree.
---@param key string
function Manager:SetActiveScope(key)
    self.activeScope = key
    self.lastRowId = nil
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

-- Flips group `id`'s expand state in scope `scopeKey` and bumps the rebuild signature so the view
-- redraws. Read-only otherwise — no persistence; collapse state is transient session UI.
---@param scopeKey string
---@param id integer
function Manager:ToggleExpand(scopeKey, id)
    local perScope = self.expanded[scopeKey]
    if perScope == nil then
        perScope = {}
        self.expanded[scopeKey] = perScope
    end
    perScope[id] = not self:IsExpanded(scopeKey, id)
    self.expandVersion = self.expandVersion + 1
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

--- Rebuild signature ----------------------------------------------------------------------

-- A cheap string capturing everything the rendered tree depends on: the active scope, the expand
-- generation, the mutate generation (#91 — enable/rename don't change root count), and each
-- scope's key+label+entry-count. The view rebuilds only when this changes, so a character login
-- (new tab), a scope switch, an expand toggle, or a row mutation redraws — but an idle frame doesn't.
---@return string
function Manager:_signature()
    local parts = {
        self:ActiveScopeKey() or "-",
        tostring(self.expandVersion),
        tostring(self.mutateVersion),
    }
    for _, scope in ipairs(self:ScopeList()) do
        local entries = (scope.doc or {}).entries or {}
        parts[#parts + 1] = scope.key .. ":" .. (scope.label or "") .. ":" .. tostring(#entries)
    end
    return table.concat(parts, "|")
end

--- Client view: rows glyphs ---------------------------------------------------------------

-- The one-line label a row's name button renders: indent, a chevron for a group (▾ open / ▸
-- collapsed), an icon, the name, and a group's direct-child count. Kept pure so the exact string
-- is assertable in tests without a mounted component. Enable / rename / delete are sibling
-- controls (#91), not baked into this string.
---@param row Watchdog.ManagerRow
---@return string
function Manager:RowLabel(row)
    local indent = string.rep("  ", row.depth)
    if row.kind == "group" then
        local chevron = row.expanded and "▾" or "▸"
        return indent .. chevron .. " ▣ " .. row.name .. " (" .. tostring(row.childCount or 0) .. ")"
    end
    return indent .. "• " .. row.name
end

--- Client view: mount / render (client-only, pcall-guarded) -------------------------------

-- PersistentDB crash/rebuild probe (AGENTS.md mirror-log pattern).
-- APPEND-ONLY across Mount/Stop: wiping on Mount erased the Stop/mux trail that names the
-- crash site. Cap keeps the interesting tail. Agents read PluginData.db.
local PROBE_KEY = "mgr_probe_log"
local PROBE_RUN_KEY = "mgr_probe_run"
local PROBE_STOP_KEY = "mgr_probe_stop" -- last Stop trail only; Mount never clears this
local PROBE_BUDGET = 120000
local probeLines = {}

local function probe(msg)
    local line = tostring(msg)
    if log ~= nil then pcall(function() log("Watchdog.mgr: " .. line) end) end
    probeLines[#probeLines + 1] = line
    local blob = table.concat(probeLines, "\n")
    if #blob > PROBE_BUDGET then
        blob = blob:sub(-PROBE_BUDGET)
        probeLines = { blob }
    end
    pcall(function()
        if PersistentDB ~= nil and PersistentDB.SetString ~= nil then
            PersistentDB:SetString(PROBE_KEY, blob)
        end
    end)
end

-- Seed probeLines from whatever is already on disk so a fresh Mount doesn't erase prior
-- Stop/mux lines from a crashed reload.
local function probeBeginRun()
    local prev = ""
    pcall(function()
        if PersistentDB ~= nil and PersistentDB.GetString ~= nil then
            prev = PersistentDB:GetString(PROBE_KEY) or ""
        end
    end)
    if prev ~= "" then
        probeLines = { prev }
    else
        probeLines = {}
    end
    local run = 0
    pcall(function()
        if PersistentDB ~= nil and PersistentDB.GetInt ~= nil then
            run = PersistentDB:GetInt(PROBE_RUN_KEY) or 0
        end
    end)
    run = run + 1
    pcall(function()
        if PersistentDB ~= nil and PersistentDB.SetInt ~= nil then
            PersistentDB:SetInt(PROBE_RUN_KEY, run)
        end
    end)
    probe("=== mgr probe run " .. tostring(run) .. " ===")
end

-- Append a line to the Stop-only key (survives Mount). Used from main.lua / multiplexer.
local function probeStopTrail(msg)
    pcall(function()
        if PersistentDB == nil then return end
        local line = tostring(msg)
        if log ~= nil then pcall(function() log("Watchdog.stop: " .. line) end) end
        local prev = ""
        if PersistentDB.GetString ~= nil then
            prev = PersistentDB:GetString(PROBE_STOP_KEY) or ""
        end
        local blob = prev
        if blob ~= "" then blob = blob .. "\n" end
        blob = blob .. line
        if #blob > PROBE_BUDGET then blob = blob:sub(-PROBE_BUDGET) end
        if PersistentDB.SetString ~= nil then
            PersistentDB:SetString(PROBE_STOP_KEY, blob)
        end
        -- Also mirror into the main append-only log.
        probe("[stop] " .. line)
    end)
end

-- Expose Stop-trail helper for main.lua / multiplexer (same module table).
Manager._probeStopTrail = probeStopTrail
Manager._probe = probe

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
    probe("destroyToolbar n=" .. tostring(#self.toolbarButtons))
    for _, b in ipairs(self.toolbarButtons) do
        pcall(function() b:Destroy() end)
    end
    self.toolbarButtons = {}
    probe("destroyToolbar done")
end

-- Destroys the tree Panel (row SpriteButtons die with it — do not Destroy them separately).
function Manager:_destroyTree()
    probe("destroyTree BEFORE treePanel=" .. tostring(self.treePanel ~= nil)
        .. " rowWidgets=" .. tostring(#self.rowWidgets)
        .. " rowButtons=" .. tostring(#self.rowButtons)
        .. " renameField=" .. tostring(self.renameField ~= nil))
    self:_endRename(false)
    probe("destroyTree after endRename")
    self.rowWidgets = {}
    self.rowButtons = {}
    if self.treePanel ~= nil then
        local ok, err = pcall(function() self.treePanel:Destroy() end)
        probe("destroyTree panel:Destroy ok=" .. tostring(ok) .. " err=" .. tostring(err))
        self.treePanel = nil
    end
    probe("destroyTree done")
end

-- Live rebuild helper: tear down toolbar + Tabs when the scope list changes.
-- NOT used from Unmount/Stop — see Unmount (must not Destroy before mux window Destroy).
function Manager:_destroyTabs()
    probe("destroyTabs begin")
    self:_destroyToolbar()
    self:_destroyTree()
    if self.tabs ~= nil then
        probe("destroyTabs calling tabs:Destroy")
        pcall(function() self.tabs:Destroy() end)
        self.tabs = nil
        probe("destroyTabs tabs:Destroy returned")
    end
    self.tabsScopeSig = nil
    probe("destroyTabs end")
end

-- Ensures PrettyUI Tabs match the live scope list. Recreates on scope key/label change;
-- otherwise syncs the active tab without notifying (avoids rebuild re-entrancy).
---@return boolean
function Manager:_ensureTabs()
    if prettyui == nil or prettyui.Tabs == nil or self.contentParent == nil then
        probe("ensureTabs bail prettyui/parent missing")
        return false
    end
    local scopes = self:ScopeList()
    if #scopes == 0 then
        probe("ensureTabs no scopes")
        self:_destroyTabs()
        return false
    end
    local sig = self:_scopeTabsSignature()
    if self.tabs ~= nil and self.tabsScopeSig == sig then
        local idx = self:_activeScopeIndex()
        pcall(function() self.tabs:SetActive(idx, false) end)
        return true
    end

    probe("ensureTabs recreate sig=" .. sig)
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
            height = TAB_BASELINE + 1,
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
        probe("ensureTabs Tabs.new FAILED " .. tostring(err))
        if log ~= nil then log("Watchdog: prettyui.Tabs Mount failed") end
        return false
    end
    self.tabs = tabs
    self.tabsScopeSig = sig
    probe("ensureTabs ok nScopes=" .. tostring(#scopes) .. " active=" .. tostring(activeIndex))
    return true
end

---@param contentParent ui.ComponentCollection
function Manager:Mount(contentParent)
    probeBeginRun()
    probe("Mount begin")
    if ui == nil or ui.Panel == nil then
        probe("Mount abort: no ui.Panel")
        if log ~= nil then log("Watchdog: ui.Panel unavailable, Manager Mount aborted") end
        return
    end
    if prettyui == nil or prettyui.Tabs == nil then
        probe("Mount abort: no prettyui.Tabs")
        if log ~= nil then log("Watchdog: prettyui.Tabs unavailable, Manager Mount aborted") end
        return
    end

    self.contentParent = contentParent
    local w, h = contentSize(contentParent)
    self.window.w, self.window.h = w, h
    probe("Mount contentSize " .. tostring(w) .. "x" .. tostring(h))

    if not self:_ensureTabs() then
        self.contentParent = nil
        probe("Mount abort: ensureTabs failed")
        return
    end

    self:SetVisible(self.visible)
    self:_rebuild()
    probe("Mount end mounted=" .. tostring(self:IsMounted()) .. " visible=" .. tostring(self.visible))
end

---@return boolean
function Manager:IsMounted()
    return self.tabs ~= nil
end

function Manager:_clearChildren()
    self:_destroyToolbar()
    self:_destroyTree()
end

-- Helper: mount a Button under `parent` with text `label`, at (x,y)/(w,h), wired to `onPress`.
---@param parent ui.ComponentCollection
---@param bucket table[]
---@param x number
---@param y number
---@param w number
---@param h number
---@param label string
---@param onPress fun()
---@return ui.Button|nil
local function mountButton(parent, bucket, x, y, w, h, label, onPress)
    local button
    local okb = pcall(function() button = ui.Button.new(parent) end)
    if not okb or button == nil then return nil end
    pcall(function() button.stylesheetID = safeButtonStyle() end)
    button.clickthrough = false
    button:SetPos(x, y)
    button:SetSize(w, h)
    pcall(function() button.text.content = label end)
    button:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
        onPress()
        return true
    end)
    pcall(function() button:MoveToFront() end)
    bucket[#bucket + 1] = button
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

-- + Alert / + Group on the PrettyUI tab strip (right-aligned), visually inline with the tabs.
-- PrettyUI Tabs has no trailing-actions API; parenting FancyButtons to tabs.root is the
-- supported workaround.
function Manager:_mountToolbar()
    if self.tabs == nil or self.tabs.root == nil or prettyui == nil then return end
    if prettyui.FancyButton == nil then return end
    local root = self.tabs.root
    local alertW = 75
    local groupW = 75
    pcall(function()
        alertW = select(1, prettyui.FancyButton.getSize("+ Alert", { variant = "positive" }))
        groupW = select(1, prettyui.FancyButton.getSize("+ Group", { variant = "neutral" }))
    end)
    local y = math.max(0, math.floor((TAB_BASELINE - TOOLBAR_H) / 2))
    local group
    local alert
    pcall(function()
        group = prettyui.FancyButton.new(root, "+ Group", function()
            local id = self:CreateGroup()
            if type(id) == "number" then self.pendingRenameId = id end
            self:_rebuild()
        end, {
            x = -TOOLBAR_PAD - groupW,
            y = y,
            xAnchor = 1.0,
            variant = "neutral",
        })
        alert = prettyui.FancyButton.new(root, "+ Alert", function()
            self:CreateAlert()
            self:_rebuild()
        end, {
            x = -TOOLBAR_PAD - groupW - TOOLBAR_GAP - alertW,
            y = y,
            xAnchor = 1.0,
            variant = "positive",
        })
    end)
    if alert ~= nil then self.toolbarButtons[#self.toolbarButtons + 1] = alert end
    if group ~= nil then self.toolbarButtons[#self.toolbarButtons + 1] = group end
end

-- Rebuilds toolbar + tree rows. Tabs recreate only when the scope-list signature changes.
function Manager:_rebuild()
    probe("rebuild begin visible=" .. tostring(self.visible))
    if self.contentParent == nil or ui == nil then
        probe("rebuild bail no parent/ui")
        return
    end
    if not self:_ensureTabs() then
        probe("rebuild bail ensureTabs")
        return
    end
    self:_clearChildren()
    self.lastSignature = self:_signature()

    local w, h = contentSize(self.contentParent)
    self.window.w, self.window.h = w, h
    probe("rebuild size " .. tostring(w) .. "x" .. tostring(h))

    self:_mountToolbar()
    probe("rebuild toolbar n=" .. tostring(#self.toolbarButtons))

    -- Tree: sibling of Tabs under contentParent, below the tab strip (not inside a tab page).
    local rowW = math.max(40, w - 2 * PAGE_PAD)
    local treeH = math.max(40, h - TREE_TOP - PAGE_PAD)
    local treeOk, treeErr = pcall(function()
        self.treePanel = ui.Panel.new(self.contentParent)
        self.treePanel.isVertical = true
        self.treePanel.spacing = 0
        -- BASELINE PROBE (verify non-crash): re-introduce the scrollable write that aborts
        -- tree mount. Historically this left Tabs+toolbar only (no rows / no SpriteButtons)
        -- and plugins_reload after Show did NOT crash. Remove once baseline confirmed.
        self.treePanel.scrollable = true
        self.treePanel.clickthrough = false
        self.treePanel:SetPos(PAGE_PAD, TREE_TOP)
        self.treePanel:SetSize(rowW, treeH)
        self.treePanel:MoveToFront()
    end)
    if not treeOk or self.treePanel == nil then
        self.treePanel = nil
        probe("rebuild treePanel FAILED (baseline: expect readonly scrollable) " .. tostring(treeErr))
        return
    end
    probe("rebuild treePanel ok UNEXPECTED — baseline probe should have failed")

    local rows = self:VisibleRows()
    local scope = self:ActiveScope()
    local entryCount = 0
    if scope ~= nil and scope.doc ~= nil and scope.doc.entries ~= nil then
        entryCount = #scope.doc.entries
    end
    probe("rebuild scope=" .. tostring(self:ActiveScopeKey())
        .. " docEntries=" .. tostring(entryCount)
        .. " visibleRows=" .. tostring(#rows))

    local treeParent = self.treePanel
    local nameW = math.max(40, rowW - ENABLE_W - 2 * ACT_W - 3 * ROW_GAP)
    local mountedRows = 0
    local nPencil, nTrash, nConfirm, nPencilFail, nTrashFail = 0, 0, 0, 0, 0
    local nCheck, nNameBtn = 0, 0
    for _, row in ipairs(rows) do
        local capturedRow = row
        local rowPanel = treeParent
        local okRow, rowErr = pcall(function()
            rowPanel = ui.Panel.new(treeParent)
            rowPanel.isVertical = false
            rowPanel.spacing = ROW_GAP
            rowPanel.clickthrough = true
            rowPanel:SetSize(rowW, ROW_H)
        end)
        if not okRow or rowPanel == nil then
            probe("rowPanel FAIL id=" .. tostring(row.id) .. " err=" .. tostring(rowErr))
            rowPanel = treeParent
        end
        if rowPanel ~= treeParent then
            self.rowButtons[#self.rowButtons + 1] = rowPanel
            mountedRows = mountedRows + 1
        end

        local nameX = ENABLE_W + ROW_GAP

        local enableMounted = false
        if ui.Check ~= nil then
            local check
            local okc = pcall(function() check = ui.Check.new(rowPanel) end)
            if okc and check ~= nil then
                pcall(function()
                    check.stylesheetID = safeCheckStyle()
                    check:SetPos(0, 0)
                    check:SetSize(ENABLE_W, ROW_H)
                    check.buttonSize = math.min(ENABLE_W - 2, ROW_H - 2)
                    check.value = row.enabled and true or false
                    check.label = ""
                    check:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
                        self.pendingDeleteId = nil
                        self:ToggleEnabled(capturedRow.id)
                        self:_rebuild()
                        return true
                    end)
                end)
                if rowPanel == treeParent then
                    self.rowButtons[#self.rowButtons + 1] = check
                end
                enableMounted = true
                nCheck = nCheck + 1
            end
        end
        if not enableMounted then
            local mark = row.enabled and "[x]" or "[ ]"
            local bucket = (rowPanel == treeParent) and self.rowButtons or {}
            mountButton(rowPanel, bucket, 0, 0, ENABLE_W, ROW_H, mark, function()
                self.pendingDeleteId = nil
                self:ToggleEnabled(capturedRow.id)
                self:_rebuild()
            end)
        end

        do
            local bucket = (rowPanel == treeParent) and self.rowButtons or {}
            mountButton(rowPanel, bucket, nameX, 0, nameW, ROW_H, self:RowLabel(row), function()
                self.pendingDeleteId = nil
                self:_onRowPress(capturedRow)
                if capturedRow.kind == "group" then self:_rebuild() end
            end)
            nNameBtn = nNameBtn + 1
        end

        local renameX = nameX + nameW + ROW_GAP
        local iconY = math.max(0, math.floor((ROW_H - ACT_W) / 2))
        if prettyui ~= nil and prettyui.SpriteButton ~= nil then
            -- Sprite roots are owned by rowPanel; teardown destroys the panel only (no
            -- SpriteButton:Destroy — that double-frees after the window has been shown).
            local pencil
            local okP, errP = pcall(function()
                pencil = prettyui.SpriteButton.new(rowPanel, "PENCIL", function()
                    self.pendingDeleteId = nil
                    local fieldY = 0
                    pcall(function() fieldY = rowPanel.y or 0 end)
                    self:_beginRename(capturedRow.id, capturedRow.name, nameX, fieldY, nameW, ROW_H)
                end, {
                    x = renameX,
                    y = iconY,
                    width = ACT_W,
                    height = ACT_W,
                    tooltip = "Rename",
                })
            end)
            if okP and pencil ~= nil then
                nPencil = nPencil + 1
                self.rowWidgets[#self.rowWidgets + 1] = pencil
                local tipOk = pencil.tooltip ~= nil
                local tipRoot = tipOk and pencil.tooltip.root ~= nil
                probe("row id=" .. tostring(row.id) .. " PENCIL ok tip=" .. tostring(tipOk)
                    .. " tipRoot=" .. tostring(tipRoot)
                    .. " tipParent=" .. tostring(tipOk and pencil.tooltip.parent ~= nil)
                    .. " x=" .. tostring(renameX))
            else
                nPencilFail = nPencilFail + 1
                probe("row id=" .. tostring(row.id) .. " PENCIL FAIL ok=" .. tostring(okP)
                    .. " err=" .. tostring(errP))
            end
        else
            local bucket = (rowPanel == treeParent) and self.rowButtons or {}
            mountButton(rowPanel, bucket, renameX, 0, ACT_W, ROW_H, "ren", function()
                self.pendingDeleteId = nil
                local fieldY = 0
                pcall(function() fieldY = rowPanel.y or 0 end)
                self:_beginRename(capturedRow.id, capturedRow.name, nameX, fieldY, nameW, ROW_H)
            end)
        end

        local deleteX = renameX + ACT_W + ROW_GAP
        local armed = self.pendingDeleteId == row.id
        if armed and prettyui ~= nil and prettyui.FancyButton ~= nil then
            -- Confirm button is also parented to the row panel; panel Destroy cleans it up.
            local confirm
            pcall(function()
                confirm = prettyui.FancyButton.new(rowPanel, self:_deleteConfirmLabel(row.id), function()
                    self:_onDeletePress(capturedRow.id)
                end, {
                    x = deleteX,
                    y = 0,
                    variant = "negative",
                })
            end)
            if confirm ~= nil then
                nConfirm = nConfirm + 1
                self.rowWidgets[#self.rowWidgets + 1] = confirm
            end
        elseif prettyui ~= nil and prettyui.SpriteButton ~= nil then
            local trash
            local okT, errT = pcall(function()
                trash = prettyui.SpriteButton.new(rowPanel, "TRASH", function()
                    self:_onDeletePress(capturedRow.id)
                end, {
                    x = deleteX,
                    y = iconY,
                    width = ACT_W,
                    height = ACT_W,
                    tooltip = "Delete",
                })
            end)
            if okT and trash ~= nil then
                nTrash = nTrash + 1
                self.rowWidgets[#self.rowWidgets + 1] = trash
                local tipOk = trash.tooltip ~= nil
                local spriteId = nil
                pcall(function() spriteId = trash.root and trash.root.spriteID end)
                probe("row id=" .. tostring(row.id) .. " TRASH ok tip=" .. tostring(tipOk)
                    .. " spriteID=" .. tostring(spriteId)
                    .. " disabled=" .. tostring(trash.disabled)
                    .. " x=" .. tostring(deleteX)
                    .. " rowW=" .. tostring(rowW))
            else
                nTrashFail = nTrashFail + 1
                probe("row id=" .. tostring(row.id) .. " TRASH FAIL ok=" .. tostring(okT)
                    .. " err=" .. tostring(errT))
            end
        else
            local delLabel = armed and self:_deleteConfirmLabel(row.id) or "del"
            local delW = math.max(ACT_W, 8 + 7 * #delLabel)
            local bucket = (rowPanel == treeParent) and self.rowButtons or {}
            mountButton(rowPanel, bucket, deleteX, 0, delW, ROW_H, delLabel, function()
                self:_onDeletePress(capturedRow.id)
            end)
        end

        if self.pendingRenameId == row.id then
            self.pendingRenameId = nil
            local fieldY = 0
            pcall(function() fieldY = rowPanel.y or 0 end)
            self:_beginRename(row.id, row.name, nameX, fieldY, nameW, ROW_H)
        end
    end

    if self.treePanel ~= nil then
        pcall(function() self.treePanel:SetScrollSize(rowW, #rows * ROW_H) end)
    end

    probe("rebuild summary rows=" .. tostring(mountedRows)
        .. " checks=" .. tostring(nCheck)
        .. " names=" .. tostring(nNameBtn)
        .. " pencil=" .. tostring(nPencil) .. "/" .. tostring(nPencilFail)
        .. " trash=" .. tostring(nTrash) .. "/" .. tostring(nTrashFail)
        .. " confirm=" .. tostring(nConfirm)
        .. " rowWidgets=" .. tostring(#self.rowWidgets)
        .. " done")

    if not self.visible then
        setChildVisible(componentRoot(self.tabs), false)
        for _, b in ipairs(self.toolbarButtons) do
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
    probe("SetVisible " .. tostring(self.visible) .. " becoming=" .. tostring(becomingVisible))
    setChildVisible(componentRoot(self.tabs), self.visible)
    for _, b in ipairs(self.toolbarButtons) do
        setChildVisible(componentRoot(b), self.visible)
    end
    setChildVisible(self.treePanel, self.visible)
    setChildVisible(componentRoot(self.renameField), self.visible)
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
    -- Snapshot only — no Destroy, no Tooltip.unbind (probe phase; do not "fix" teardown here).
    local tipCount = 0
    for _, w in ipairs(self.rowWidgets) do
        if w ~= nil and w.tooltip ~= nil then tipCount = tipCount + 1 end
    end
    probe("Unmount BEGIN (no Destroy) visible=" .. tostring(self.visible)
        .. " tabs=" .. tostring(self.tabs ~= nil)
        .. " treePanel=" .. tostring(self.treePanel ~= nil)
        .. " toolbar=" .. tostring(#self.toolbarButtons)
        .. " rowWidgets=" .. tostring(#self.rowWidgets)
        .. " withTooltip=" .. tostring(tipCount)
        .. " rowButtons=" .. tostring(#self.rowButtons)
        .. " renameField=" .. tostring(self.renameField ~= nil)
        .. " contentParent=" .. tostring(self.contentParent ~= nil))
    self.pendingDeleteId = nil
    self:_endRename(false)
    probe("Unmount after endRename")
    self.toolbarButtons = {}
    self.rowWidgets = {}
    self.rowButtons = {}
    self.treePanel = nil
    self.tabs = nil
    self.tabsScopeSig = nil
    self.contentParent = nil
    probe("Unmount END refs cleared — native tree/tabs still under mux window until mux:Destroy")
end

return Manager
