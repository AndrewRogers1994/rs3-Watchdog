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

-- Absolute cursor position off the client `Mouse` global (nil under the headless test harness /
-- before the client is ready). Mirrors ui/graph.lua's helper — the drag path is client-only and
-- pcall-guarded, so reading the global directly here (rather than injecting a source) matches the
-- Editor's convention and keeps the pure tree/scope logic free of any client coupling.
local function mousePos()
    if Mouse == nil or Mouse.GetPosition == nil then return nil end
    local ok, pos = pcall(function() return Mouse.GetPosition() end)
    if ok and pos ~= nil then return pos.x, pos.y end
    return nil
end

local function clampv(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

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
        -- Window drag (mirrors the Editor's capture-layer model, ui/graph.lua). An invisible
        -- full-window Button sits behind the clickthrough GroupBox: it blocks clicks from reaching
        -- the game AND drives header-drag. Grab offset recorded on a header press; window follows
        -- the cursor each Update tick while `dragging`.
        rootParent = nil,           -- kept for on-screen clamp (screen size)
        captureButton = nil,
        dragging = false,
        dragDX = 0, dragDY = 0,     -- cursor-to-window-origin offset captured at drag start
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

    self.rootParent = parent
    local ok = pcall(function() self.groupBox = ui.GroupBox.new(parent) end)
    if not ok or self.groupBox == nil then
        self.groupBox = nil
        return
    end
    pcall(function() self.groupBox.stylesheetID = safePanelStyle() end)
    -- Clickthrough like the Editor's GroupBox: a click that misses a real child Button falls through
    -- the frame to the invisible capture Button behind it (created below). That capture both BLOCKS
    -- the click from reaching the game (fixing the "window reads as dead / clicks leak through"
    -- report) and drives header-dragging. Without the capture layer a clickthrough frame would leak
    -- clicks — the two are a pair; never one without the other.
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
        self.treePanel.clickthrough = false
        self.treePanel:SetPos(TAB_PAD, treeTop)
        self.treePanel:SetSize(win.w - 2 * TAB_PAD, win.h - Theme.WINDOW_HEADER_H - treeTop - CONTENT_TOP)
    end)

    -- The invisible capture Button (mirrors the Editor's, ui/graph.lua). A SIBLING on the root
    -- parent (not a GroupBox child) so it can grow past the window to full-screen during a drag —
    -- a nested child can only size within its parent. Created AFTER the GroupBox so it lands in
    -- front of it; the MoveToFront below then re-fronts the GroupBox + its Buttons above the
    -- capture, leaving the capture reachable only where a click misses a real Button (the header
    -- band and empty content), which is exactly where we want drags/blocking. ONCLICK begins a drag
    -- iff it landed in the header; movement is polled in Update; ONRELEASE ends it.
    pcall(function()
        self.captureButton = ui.Button.new(parent)
        self.captureButton.alpha = 0
        self.captureButton.clickthrough = false
        self.captureButton:Subscribe(ui.Hook.ONCLICK, function() self:_beginDrag() end)
        self.captureButton:Subscribe(ui.Hook.ONRELEASE, function() self:_endDrag() end)
    end)
    self:_positionCapture()

    pcall(function() self.groupBox:MoveToFront() end)
    self:SetVisible(self.visible)
    self:_rebuild()
end

--- Window drag (capture-layer model; see the captureButton comment in Mount) -----------------

-- Full-screen interface size (fallback if the root component can't be read), for the on-screen
-- clamp. Mirrors Editor:screenSize.
---@return number, number
function Manager:_screenSize()
    local w, h = 1920, 1080
    if self.rootParent ~= nil then
        pcall(function()
            if self.rootParent.width and self.rootParent.width > 0 then w = self.rootParent.width end
            if self.rootParent.height and self.rootParent.height > 0 then h = self.rootParent.height end
        end)
    end
    return w, h
end

-- Whether an absolute screen point is in the window's header band. The Manager works entirely in
-- absolute coords (no Canvas transform), so this is a plain rect test — pure, and unit-tested.
---@param mx number
---@param my number
---@return boolean
function Manager:_inHeader(mx, my)
    local win = self.window
    return mx >= win.x and mx <= win.x + win.w
        and my >= win.y and my <= win.y + Theme.WINDOW_HEADER_H
end

-- Sizes the capture Button to the window rect (its resting size). Absolute coords, like the Editor's.
function Manager:_positionCapture()
    if self.captureButton == nil then return end
    local win = self.window
    pcall(function()
        self.captureButton:SetPos(win.x, win.y)
        self.captureButton:SetSize(win.w, win.h)
    end)
end

-- Grows the capture Button to the whole screen for a drag's duration, so the release (and continued
-- tracking) still reaches us if the cursor leaves the window. Restored to window size in _endDrag.
function Manager:_expandCapture()
    if self.captureButton == nil then return end
    pcall(function()
        self.captureButton:SetPos(0, 0)
        self.captureButton:SetSize(0, 0, 1.0, 1.0)
    end)
end

-- Moves the GroupBox (its tab/row children ride along) and the resting capture to the window rect.
function Manager:_positionWindow()
    local win = self.window
    if self.groupBox ~= nil then
        pcall(function()
            self.groupBox:SetPos(win.x, win.y)
            self.groupBox:SetSize(win.w, win.h)
        end)
    end
    self:_positionCapture()
end

-- A press reached the capture: start a window drag only if it landed in the header band. The grab
-- offset is cursor-minus-window-origin so the window tracks the cursor without jumping. A non-header
-- press just gets swallowed by the capture (blocking the game), which is the desired no-op.
function Manager:_beginDrag()
    if not self.visible or self.captureButton == nil then return end
    local mx, my = mousePos()
    if mx == nil then return end
    if self:_inHeader(mx, my) then
        self.dragging = true
        self.dragDX, self.dragDY = mx - self.window.x, my - self.window.y
        self:_expandCapture()
    end
end

-- Ends a drag on release: shrink the capture back to the window. Safe when not dragging.
function Manager:_endDrag()
    if not self.dragging then return end
    self.dragging = false
    self:_positionCapture()
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
-- double-click tick, follows the cursor while dragging, and rebuilds when the signature changed out
-- from under us (a character login adds a tab, a logout removes one) so the tab bar tracks scope
-- changes without an explicit call.
function Manager:Update()
    self.tick = self.tick + 1
    -- Follow the cursor via the grab offset, clamped so the window (header included) stays on screen.
    -- The tab/row Buttons are GroupBox children, so moving the GroupBox carries them along for free.
    if self.dragging then
        local mx, my = mousePos()
        if mx ~= nil then
            local sw, sh = self:_screenSize()
            self.window.x = clampv(mx - self.dragDX, 0, math.max(0, sw - self.window.w))
            self.window.y = clampv(my - self.dragDY, 0, math.max(0, sh - self.window.h))
            self:_positionWindow()
        end
    end
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
    if not self.visible then
        self.dragging = false -- abandon any in-progress drag so nothing resumes when reshown
    end
    if self.groupBox ~= nil then
        pcall(function() self.groupBox.hidden = not self.visible end)
    end
    if self.captureButton ~= nil then
        pcall(function()
            self.captureButton.hidden = not self.visible
            self.captureButton.enabled = self.visible -- stop intercepting game input while hidden
        end)
        if self.visible then self:_positionCapture() end -- also recovers size if a drag left it expanded
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
-- jumped in front mid-drag. Fronts the capture first, then the GroupBox on top of it — the same
-- relative order Mount establishes (GroupBox + Buttons out-rank capture, capture out-ranks the rest).
-- No-op while hidden.
function Manager:RaiseToFront()
    if not self.visible then return end
    pcall(function() if self.captureButton ~= nil then self.captureButton:MoveToFront() end end)
    pcall(function() if self.groupBox ~= nil then self.groupBox:MoveToFront() end end)
end

function Manager:Unmount()
    self:_clearChildren()
    if self.captureButton ~= nil then
        pcall(function() self.captureButton:Destroy() end)
        self.captureButton = nil
    end
    if self.groupBox ~= nil then
        pcall(function() self.groupBox:Destroy() end)  -- takes the tree Panel + any children with it
        self.groupBox = nil
        self.treePanel = nil
    end
end

return Manager
