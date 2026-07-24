-- manager.lua — the Alert Manager: the second surface beside the Canvas Editor.
--
-- The management surface the F8 keybind and the LibPluginMenu button open (through the nav
-- owner in main.lua): a scope **tab bar** over a **read-only tree** of Entries. Built from
-- native `ui.*` components on a `ui.Panel` (ADR-0007), NOT the Editor's Canvas — a scrolling
-- list has neither pan nor zoom, so Canvas's rationale (ADR-0001) doesn't extend here, and a
-- Panel hands us native auto-layout + scroll + per-row clicks for free.
--
-- This ticket (#90) renders the tree **read-only**: each row shows an icon + name; a group row
-- shows a chevron + its direct-child count and toggles expand/collapse on click; double-clicking
-- an alert row navigates into the Editor (via the nav owner). The enable checkbox, rename field,
-- drag-reorder, delete and multi-select are later tickets (#78, #82) — the row rendering here is
-- deliberately the minimal read-only cut.
--
-- ## Two halves
--
-- The tree/scope/expand logic is **pure** (no `ui.*`): it walks a `Watchdog.Bucket` into a flat
-- list of visible rows, tracks per-scope collapse state, and resolves the active scope against the
-- injected scope provider. That half is unit-tested headless (tests/test_manager.lua). The mount /
-- render half is client-only and pcall-guarded, the same split every other surface in this plugin
-- uses (the Editor's linkPins is tested; its Mount is not).

local Theme = require("ui/theme")

local Manager = {}
Manager.__index = Manager

-- Layout constants (GroupBox-local content coords, mirroring the Editor's convention: child (0,0)
-- is the top-left of the content area, the title band floats above it per the _TITLED stylesheet).
local TAB_H       = 24    -- scope tab bar height
local TAB_PAD     = 6     -- gap between tabs / inset from the box edge
local ROW_H       = 22    -- one tree row
local CONTENT_TOP = 4     -- inset below the title band

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
---@field enabled boolean             # the Entry's own enabled flag (read-only badge, not yet wired)

--- Construction ---------------------------------------------------------------------------

-- The Manager's whole seam onto its host: the scope provider and the alert-open callback.
---@class Watchdog.ManagerOpts
---@field scopes fun(): Watchdog.ManagerScope[]              # ordered scopes (Global first, character second)
---@field onOpenAlert fun(scopeKey: string, id: integer)    # nav callback for a double-clicked alert row

-- `scopes` is the injected scope provider: `fn() -> Watchdog.ManagerScope[]`, ordered (Global
-- first, the current character second when logged in). Called live on every rebuild so a character
-- login/logout re-tabs without the Manager caching identity. `onOpenAlert` is the nav callback
-- `fn(scopeKey, id)` fired when an alert row is double-clicked — main.lua's nav owner binds the
-- Editor to that entry. Both are the whole seam onto the host; everything else here is self-owned.
---@param opts Watchdog.ManagerOpts|nil
---@return table
function Manager.new(opts)
    local self = setmetatable({
        scopesProvider = (opts and opts.scopes) or function() return {} end,
        onOpenAlert = (opts and opts.onOpenAlert) or function() end,
        activeScope = nil,          -- resolved lazily; nil ⇒ "first scope" (Global)
        expanded = {},              -- expanded[scopeKey][id] = bool; absent ⇒ default (expanded)
        expandVersion = 0,          -- bumped on every toggle, part of the rebuild signature
        visible = false,
        tick = 0,                   -- Logic-tick counter, for row double-click timing
        lastRowId = nil,            -- id of the previously-pressed row (double-click pairing)
        lastRowTick = -1000,
        window = {
            x = Theme.WINDOW_X, y = Theme.WINDOW_Y,
            w = Theme.WINDOW_W, h = Theme.WINDOW_H,
        },
        -- Client-only component handles (nil until Mount); see the render half below.
        groupBox = nil,
        treePanel = nil,
        tabButtons = {},
        rowButtons = {},
        lastSignature = nil,        -- last-rendered rebuild signature (skip no-op rebuilds)
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

--- Rebuild signature ----------------------------------------------------------------------

-- A cheap string capturing everything the rendered tree depends on: the active scope, the expand
-- generation, and each scope's key+label+entry-count. The view rebuilds only when this changes, so
-- a character login (new tab), a scope switch, or an expand toggle redraws — but an idle frame doesn't.
---@return string
function Manager:_signature()
    local parts = { self:ActiveScopeKey() or "-", tostring(self.expandVersion) }
    for _, scope in ipairs(self:ScopeList()) do
        local entries = (scope.doc or {}).entries or {}
        parts[#parts + 1] = scope.key .. ":" .. (scope.label or "") .. ":" .. tostring(#entries)
    end
    return table.concat(parts, "|")
end

--- Client view: rows glyphs ---------------------------------------------------------------

-- The one-line label a row renders as: indent, a chevron for a group (▾ open / ▸ collapsed), an
-- icon, the name, and a group's direct-child count. Text-only (read-only cut) — the richer
-- per-control row (enable check, rename field, badges) is #78. Kept pure so the exact string is
-- assertable in tests without a mounted component.
---@param row Watchdog.ManagerRow
---@return string
function Manager:RowLabel(row)
    local indent = string.rep("  ", row.depth)
    if row.kind == "group" then
        local chevron = row.expanded and "▾" or "▸"
        return indent .. chevron .. " ▣ " .. row.name .. " (" .. tostring(row.childCount or 0) .. ")"
    end
    return indent .. "   • " .. row.name
end

--- Client view: mount / render (client-only, pcall-guarded) -------------------------------

local function safeButtonStyle()
    if id ~= nil and id.StyleSheet ~= nil and id.StyleSheet.BUTTON_DEFAULT ~= nil then
        return id.StyleSheet.BUTTON_DEFAULT
    end
    return nil
end

local function safePanelStyle()
    if id ~= nil and id.StyleSheet ~= nil and id.StyleSheet.GROUPBOX_CONTENT_PANEL_TITLED ~= nil then
        return id.StyleSheet.GROUPBOX_CONTENT_PANEL_TITLED
    end
    return nil
end

-- Mounts the Manager's native chrome: a titled GroupBox framing a scope tab bar and a scrollable
-- vertical tree Panel. Structure mirrors the Editor's mountGroupBox (same safe-style guards, same
-- header layout), differing only in what it hosts. Everything is best-effort: a missing ui.* just
-- leaves the surface unmounted (IsMounted false), and main.lua's retry loop tries again next frame.
---@param parent ui.ComponentCollection
function Manager:Mount(parent)
    if ui == nil or ui.GroupBox == nil then
        if log ~= nil then log("Watchdog: ui.GroupBox unavailable, Manager Mount aborted") end
        return
    end
    local win = self.window

    local ok = pcall(function() self.groupBox = ui.GroupBox.new(parent) end)
    if not ok or self.groupBox == nil then
        self.groupBox = nil
        return
    end
    pcall(function() self.groupBox.stylesheetID = safePanelStyle() end)
    self.groupBox.clickthrough = true
    pcall(function()
        self.groupBox:SetPos(win.x, win.y)
        self.groupBox:SetSize(win.w, win.h)
    end)
    pcall(function()
        self.groupBox:SetHeaderLayout(math.min(win.w, 255), Theme.WINDOW_HEADER_H,
            0, 0, ui.GroupBoxHeaderAlignMode.LEFT)
    end)
    pcall(function() self.groupBox.headerText.content = "Watchdog — Alerts" end)
    pcall(function() self.groupBox.headerText.font = id.Font.MUSEO_SANS_15PT_REGULAR end)
    pcall(function() self.groupBox.contentMargin = ui.Margin.new() end)

    -- The tree lives in its own scrollable vertical Panel below the tab bar; the tabs are direct
    -- GroupBox children positioned by hand (a short fixed row, not worth an auto-layout Panel).
    local treeTop = CONTENT_TOP + TAB_H + TAB_PAD
    pcall(function()
        self.treePanel = ui.Panel.new(self.groupBox)
        self.treePanel.isVertical = true
        self.treePanel.spacing = 0
        self.treePanel.clickthrough = true
        self.treePanel:SetPos(TAB_PAD, treeTop)
        self.treePanel:SetSize(win.w - 2 * TAB_PAD, win.h - Theme.WINDOW_HEADER_H - treeTop - CONTENT_TOP)
    end)

    pcall(function() self.groupBox:MoveToFront() end)
    self:SetVisible(self.visible)
    self:_rebuild()
end

-- True once the GroupBox exists (read back off the handle, mirroring effects:IsMounted — so main's
-- retry loop stops re-mounting once we're up).
---@return boolean
function Manager:IsMounted()
    return self.groupBox ~= nil
end

-- Destroys the previous frame's tab buttons + tree rows. Children of the GroupBox get taken by its
-- own Destroy on Unmount, but a rebuild must clear them itself so stale rows don't pile up.
function Manager:_clearChildren()
    for _, b in ipairs(self.tabButtons) do pcall(function() b:Destroy() end) end
    for _, b in ipairs(self.rowButtons) do pcall(function() b:Destroy() end) end
    self.tabButtons = {}
    self.rowButtons = {}
end

-- Rebuilds the scope tabs and tree rows from current state. Called on mount, on visibility-show,
-- and whenever the rebuild signature changes (see Update). Fully tears down and recreates — a read-
-- only list is rebuilt rarely (tab switch / expand toggle / login), so retained-mode diffing isn't
-- worth it here.
function Manager:_rebuild()
    if self.groupBox == nil or ui == nil then return end
    self:_clearChildren()
    self.lastSignature = self:_signature()

    local win = self.window
    local scopes = self:ScopeList()
    local activeKey = self:ActiveScopeKey()

    -- Scope tab bar: one button per scope, laid left-to-right. The active tab is marked in its text
    -- (native restyle-by-state isn't worth wiring for the read-only cut) so it reads which scope is live.
    local tabX = TAB_PAD
    for _, scope in ipairs(scopes) do
        local label = (scope.key == activeKey) and ("[" .. (scope.label or "") .. "]") or (scope.label or "")
        local scopeKey = scope.key
        local button
        local okb = pcall(function() button = ui.Button.new(self.groupBox) end)
        if okb and button ~= nil then
            pcall(function() button.stylesheetID = safeButtonStyle() end)
            button.clickthrough = false
            local wpx = math.max(64, 12 + 8 * #label)
            button:SetPos(tabX, CONTENT_TOP)
            button:SetSize(wpx, TAB_H)
            pcall(function() button.text.content = label end)
            button:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
                self:_onTabPress(scopeKey)
                return true
            end)
            pcall(function() button:MoveToFront() end)
            self.tabButtons[#self.tabButtons + 1] = button
            tabX = tabX + wpx + TAB_PAD
        end
    end

    -- Tree rows: one button per visible row inside the scrollable Panel. Indent is baked into the
    -- label text (a leading-space run per depth), so all rows share the Panel's simple vertical stack.
    local rows = self:VisibleRows()
    local rowW = win.w - 2 * TAB_PAD
    for i, row in ipairs(rows) do
        local capturedRow = row
        local button
        local okb = pcall(function() button = ui.Button.new(self.treePanel or self.groupBox) end)
        if okb and button ~= nil then
            pcall(function() button.stylesheetID = safeButtonStyle() end)
            button.clickthrough = false
            -- Positioned inside the tree Panel; the Panel's own vertical auto-layout may also
            -- arrange children, but an explicit SetPos keeps rows ordered even if it doesn't. Depth
            -- indent is carried entirely by the label text (RowLabel), so every row is full-width.
            button:SetPos(0, (i - 1) * ROW_H)
            button:SetSize(rowW, ROW_H)
            pcall(function() button.text.content = self:RowLabel(row) end)
            button:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
                self:_onRowPress(capturedRow)
                return true
            end)
            self.rowButtons[#self.rowButtons + 1] = button
        end
    end
    -- Grow the tree Panel's scroll region to the full row stack so it scrolls when it overflows.
    if self.treePanel ~= nil then
        pcall(function() self.treePanel:SetScrollSize(rowW, #rows * ROW_H) end)
    end
end

-- Scope tab press: switch the active scope (a no-op rebuild if it was already active, since the
-- signature is unchanged) and force a rebuild so the new tree shows immediately.
---@param scopeKey string
function Manager:_onTabPress(scopeKey)
    self:SetActiveScope(scopeKey)
    self:_rebuild()
end

-- Tree row press. A group toggles expand (single click). An alert opens only on a **double**-click
-- (two presses of the same row within DOUBLECLICK_TICKS) — a single click on an alert is inert in
-- the read-only cut. Double-click timing reuses the Editor's tick-based scheme (Manager:Update
-- advances the tick).
---@param row Watchdog.ManagerRow
function Manager:_onRowPress(row)
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil then return end
    if row.kind == "group" then
        self:_activateRow(scopeKey, row)
        self:_rebuild()
        return
    end
    -- Alert: pair with the previous press for double-click detection.
    local isDouble = (row.id == self.lastRowId)
        and (self.tick - self.lastRowTick) <= Theme.DOUBLECLICK_TICKS
    self.lastRowId, self.lastRowTick = row.id, self.tick
    if isDouble then
        self.lastRowId = nil -- consume so a 3rd click isn't a fresh double
        self:_activateRow(scopeKey, row)
    end
end

-- Per-tick poll (driven from main.lua's Logic loop, like the Editor's update): advances the
-- double-click tick and rebuilds when the signature changed out from under us (a character login
-- adds a tab, a logout removes one) so the tab bar tracks scope changes without an explicit call.
function Manager:Update()
    self.tick = self.tick + 1
    if not self.visible or self.groupBox == nil then return end
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
    if self.groupBox ~= nil then
        pcall(function() self.groupBox.hidden = not self.visible end)
    end
    -- A rebuild on show catches any scope/tree change that happened while hidden (a login, or an
    -- Editor write-back to a tree the Manager already had on screen).
    if becomingVisible and self.groupBox ~= nil then
        self:_rebuild()
    end
end

function Manager:Toggle()
    self:SetVisible(not self.visible)
end

-- Re-asserts front-most z-order (mirrors Editor:RaiseToFront) after another always-on overlay
-- jumped in front mid-drag. No-op while hidden.
function Manager:RaiseToFront()
    if not self.visible then return end
    pcall(function() if self.groupBox ~= nil then self.groupBox:MoveToFront() end end)
end

function Manager:Unmount()
    self:_clearChildren()
    if self.groupBox ~= nil then
        pcall(function() self.groupBox:Destroy() end)  -- takes the tree Panel + any children with it
        self.groupBox = nil
        self.treePanel = nil
    end
end

return Manager
