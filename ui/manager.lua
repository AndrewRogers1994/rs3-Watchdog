-- manager.lua — the Alert Manager: the second surface beside the Canvas Editor.
--
-- The management surface the F8 keybind and the LibPluginMenu button open (through the nav
-- owner in main.lua): a scope **tab bar** over a tree of Entries. Built from native `ui.*`
-- components on a `ui.Panel` (ADR-0007), NOT the Editor's Canvas — a scrolling list has neither
-- pan nor zoom, so Canvas's rationale (ADR-0001) doesn't extend here, and a Panel hands us
-- native auto-layout + scroll + per-row clicks for free.
--
-- #90 landed the tree/scope/expand read-only cut; #91 adds the per-row editing ops (enable
-- toggle, InputField rename, delete-with-confirm) and the per-tab + Alert / + Group actions.
-- Drag-reorder and multi-select are later tickets (#92, #93).
--
-- ## Two halves
--
-- The tree/scope/expand/mutation logic is **pure** (no `ui.*`): it walks a `Watchdog.Bucket`
-- into a flat list of visible rows, tracks per-scope collapse state, resolves the active scope
-- against the injected scope provider, and reports mutations through host callbacks. That half
-- is unit-tested headless (tests/test_manager.lua). The mount / render half is client-only and
-- pcall-guarded, the same split every other surface in this plugin uses.

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
local ENABLE_W    = 22    -- enable toggle width
local ACT_W       = 36    -- rename / delete action button width (ASCII labels, not emoji)
local CREATE_W    = 72    -- + Alert / + Group button width
local ROW_GAP     = 2     -- gap between controls inside a row

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
        -- Inline rename (#91): the mounted InputField + the Entry id it's editing, or nil when idle.
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

-- Destroys the previous frame's tab buttons + tree rows + create buttons + any inline rename
-- field. Children of the GroupBox get taken by its own Destroy on Unmount, but a rebuild must
-- clear them itself so stale rows don't pile up.
function Manager:_clearChildren()
    self:_endRename(false) -- drop the InputField without committing (rebuild is about to recreate)
    for _, b in ipairs(self.tabButtons) do pcall(function() b:Destroy() end) end
    for _, b in ipairs(self.rowButtons) do pcall(function() b:Destroy() end) end
    self.tabButtons = {}
    self.rowButtons = {}
end

-- Helper: mount a Button under `parent` with text `label`, at (x,y)/(w,h), wired to `onPress`.
-- Returns the button or nil. Tracked in `bucket` (tabButtons / rowButtons) for teardown.
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

-- Resolves an enum member by name with a string fallback (mirrors ui/graph.lua's enumv — newer
-- Hook / InputFieldFilterMode members can be missing from stubs but present in-client).
local function enumv(tbl, name)
    if tbl ~= nil and tbl[name] ~= nil then return tbl[name] end
    return name
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

-- Commits (or abandons) the inline rename InputField. `commit` true reads the field content and
-- calls Rename; false just tears the field down (used by rebuild / cancel).
---@param commit boolean
function Manager:_endRename(commit)
    local field, id = self.renameField, self.renameId
    self.renameField, self.renameId = nil, nil
    if field == nil then return end
    if commit and id ~= nil then
        local name = ""
        pcall(function() name = field.content or "" end)
        if name ~= "" then self:Rename(id, name) end
    end
    pcall(function() field:Destroy() end)
end

-- Mounts a transient InputField over the name slot for Entry `id` (ADR-0007's caret rename).
---@param id integer
---@param name string
---@param x number
---@param y number
---@param w number
---@param h number
function Manager:_beginRename(id, name, x, y, w, h)
    self:_endRename(false)
    if self.groupBox == nil or ui == nil or ui.InputField == nil then return end
    local field
    local ok = pcall(function()
        field = ui.InputField.new(self.treePanel or self.groupBox)
        pcall(function() field.stylesheetID = safeButtonStyle() end)
        field.clickthrough = false
        field:SetPos(x, y)
        field:SetSize(w, h)
        field:Setup(enumv(ui.TextContentVisibilityMode, "VISIBLE"),
            enumv(ui.InputFieldFilterMode, "NONE"), 64)
        field.content = name or ""
        field:Subscribe(enumv(ui.Hook, "ONCONTENTCHANGED"), function(_c, cause, _new)
            if isSubmitCause(cause) then
                self:_endRename(true)
                self:_rebuild()
            end
            return true
        end)
        pcall(function() field:MoveToFront() end)
    end)
    if ok and field ~= nil then
        self.renameField = field
        self.renameId = id
    end
end

-- Delete press: first click arms a confirm (pendingDeleteId); second click on the same row
-- commits. Any other row's delete re-arms onto that row. The armed label discloses ride-along
-- descendant count for a non-empty group (#78/#82) — Manager writes are immediate, no undo.
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

-- Descendant count for the delete-confirm label (direct + nested children of a group; 0 for an
-- alert). Read off the live Bucket so a nested tree discloses the full ride-along set.
---@param id integer
---@return integer
function Manager:_descendantCount(id)
    local scope = self:ActiveScope()
    if scope == nil or scope.doc == nil then return 0 end
    -- Walk VisibleRows isn't enough (collapsed children are absent); search the live tree.
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

-- Confirm-button label for a pending delete: "OK?" for a leaf / empty group; "OK N?" when a
-- group would take N descendants with it (#78).
---@param id integer
---@return string
function Manager:_deleteConfirmLabel(id)
    local n = self:_descendantCount(id)
    if n > 0 then return "OK " .. tostring(n) .. "?" end
    return "OK?"
end

-- Rebuilds the scope tabs, + Alert/+ Group actions, and tree rows from current state. Called on
-- mount, on visibility-show, and whenever the rebuild signature changes (see Update). Fully tears
-- down and recreates — a list is rebuilt rarely (tab switch / expand / mutation / login), so
-- retained-mode diffing isn't worth it here.
function Manager:_rebuild()
    if self.groupBox == nil or ui == nil then return end
    self:_clearChildren()
    self.lastSignature = self:_signature()

    local win = self.window
    local scopes = self:ScopeList()
    local activeKey = self:ActiveScopeKey()

    -- Scope tab bar: one button per scope, laid left-to-right. The active tab is marked in its text
    -- (native restyle-by-state isn't worth wiring) so it reads which scope is live.
    local tabX = TAB_PAD
    for _, scope in ipairs(scopes) do
        local label = (scope.key == activeKey) and ("[" .. (scope.label or "") .. "]") or (scope.label or "")
        local scopeKey = scope.key
        local wpx = math.max(64, 12 + 8 * #label)
        mountButton(self.groupBox, self.tabButtons, tabX, CONTENT_TOP, wpx, TAB_H, label, function()
            self:_onTabPress(scopeKey)
        end)
        tabX = tabX + wpx + TAB_PAD
    end

    -- Per-tab create actions (#91 / #78): + Alert / + Group, right-aligned on the tab bar.
    local createX = win.w - TAB_PAD - 2 * CREATE_W - TAB_PAD
    if createX < tabX then createX = tabX + TAB_PAD end
    mountButton(self.groupBox, self.tabButtons, createX, CONTENT_TOP, CREATE_W, TAB_H, "+ Alert", function()
        self:CreateAlert()
        -- Host opens the Editor immediately; no Manager-side follow-up.
        self:_rebuild()
    end)
    mountButton(self.groupBox, self.tabButtons, createX + CREATE_W + TAB_PAD, CONTENT_TOP, CREATE_W, TAB_H, "+ Group", function()
        local id = self:CreateGroup()
        if type(id) == "number" then self.pendingRenameId = id end
        self:_rebuild()
    end)

    -- Tree rows: one horizontal row Panel per visible Entry (ADR-0007). The tree Panel itself is
    -- vertical and would otherwise stack every control as its own row — that was why rename/delete
    -- sat under the name instead of beside it. Client fonts also don't render emoji (✎/🗑 → ?/tofu),
    -- so action labels stay ASCII ("ren" / "del").
    local rows = self:VisibleRows()
    local rowW = win.w - 2 * TAB_PAD
    local treeParent = self.treePanel or self.groupBox
    local nameW = math.max(40, rowW - ENABLE_W - 2 * ACT_W - 3 * ROW_GAP)
    for _, row in ipairs(rows) do
        local capturedRow = row
        local rowPanel = treeParent
        local okRow = pcall(function()
            rowPanel = ui.Panel.new(treeParent)
            rowPanel.isVertical = false
            rowPanel.spacing = ROW_GAP
            rowPanel.clickthrough = true
            rowPanel:SetSize(rowW, ROW_H)
        end)
        if not okRow or rowPanel == nil then rowPanel = treeParent end
        -- Destroying the row Panel takes its children; track it (not each control) for teardown.
        if rowPanel ~= treeParent then
            self.rowButtons[#self.rowButtons + 1] = rowPanel
        end

        local nameX = ENABLE_W + ROW_GAP
        -- Inside the row Panel, y is always 0 — the vertical tree Panel stacks the row Panels.

        -- Enable toggle (ui.Check with CHECKBOX_DEFAULT — no stylesheet ⇒ invisible, same gotcha
        -- as Button/InputField). Falls back to a labelled Button if Check can't mount.
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

        -- Name / expand / double-click-open.
        do
            local bucket = (rowPanel == treeParent) and self.rowButtons or {}
            mountButton(rowPanel, bucket, nameX, 0, nameW, ROW_H, self:RowLabel(row), function()
                self.pendingDeleteId = nil
                self:_onRowPress(capturedRow)
                if capturedRow.kind == "group" then self:_rebuild() end
            end)
        end

        -- Inline rename — ASCII "ren" (client fonts don't render ✎).
        local renameX = nameX + nameW + ROW_GAP
        do
            local bucket = (rowPanel == treeParent) and self.rowButtons or {}
            mountButton(rowPanel, bucket, renameX, 0, ACT_W, ROW_H, "ren", function()
                self.pendingDeleteId = nil
                -- InputField is parented to the tree Panel; convert row-local name slot to tree Y
                -- via the row Panel's laid-out origin when available.
                local fieldY = 0
                pcall(function() fieldY = rowPanel.y or 0 end)
                self:_beginRename(capturedRow.id, capturedRow.name, nameX, fieldY, nameW, ROW_H)
            end)
        end

        -- Delete — ASCII "del"; confirm label discloses descendant count.
        local deleteX = renameX + ACT_W + ROW_GAP
        local delLabel = (self.pendingDeleteId == row.id) and self:_deleteConfirmLabel(row.id) or "del"
        local delW = math.max(ACT_W, 8 + 7 * #delLabel)
        do
            local bucket = (rowPanel == treeParent) and self.rowButtons or {}
            mountButton(rowPanel, bucket, deleteX, 0, delW, ROW_H, delLabel, function()
                self:_onDeletePress(capturedRow.id)
            end)
        end

        -- + Group follow-up: open the InputField caret on the freshly created row (#78).
        if self.pendingRenameId == row.id then
            self.pendingRenameId = nil
            local fieldY = 0
            pcall(function() fieldY = rowPanel.y or 0 end)
            self:_beginRename(row.id, row.name, nameX, fieldY, nameW, ROW_H)
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
    self.pendingDeleteId = nil
    self:SetActiveScope(scopeKey)
    self:_rebuild()
end

-- Tree row press. A group toggles expand (single click). An alert opens only on a **double**-click
-- (two presses of the same row within DOUBLECLICK_TICKS) — a single click on an alert is inert.
-- Double-click timing reuses the Editor's tick-based scheme (Manager:Update advances the tick).
---@param row Watchdog.ManagerRow
function Manager:_onRowPress(row)
    local scopeKey = self:ActiveScopeKey()
    if scopeKey == nil then return end
    if row.kind == "group" then
        self:_activateRow(scopeKey, row)
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
    self.pendingDeleteId = nil
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
