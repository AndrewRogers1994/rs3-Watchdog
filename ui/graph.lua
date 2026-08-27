-- graph.lua — the Editor: the pannable/zoomable Viewport onto a live LibNodeGraph Graph.
--
-- Owns the View (pan/zoom), the Layout (nodeId -> Graph-space position), the input state
-- machine, and all hit-testing. Draws everything each frame onto one Canvas (immediate
-- mode, ADR-0001) mounted into an external PrettyUI content parent; window chrome (title,
-- frame, drag, close) belongs to the host Multiplexer / prettyui.Window. Mutates the Graph
-- through the engine's own Connect/Disconnect so the picture and the model can't drift. UI
-- presentation only — no graph structure is invented here.
--
-- Mount(contentParent, overlayParent): Canvas under contentParent; Back/+, capture,
-- paletteCanvas, and transient InputField/ComboField under overlayParent. The mux raises
-- the overlay above the PrettyUI window so capture can receive canvas gestures — anything
-- that needs real clicks (toolbar, inline editors) must live on that same overlay *above*
-- the capture, or MoveToFront inside the window cannot win. Content-local (0,0) is the
-- top-left of PrettyUI content (no WINDOW_HEADER_H inset). `self.window` is the live
-- content screen rect, re-synced each update from contentParent (PrettyUI owns drag).
-- Resting capture tracks that rect so title-drag/close stay clickable; overlay chrome is
-- positioned in absolute screen space via toScreen.

local Theme    = require("ui/theme")
local View     = require("ui/view")
local Node     = require("ui/node")
local Placeholder = require("ui/placeholder")
local Wire     = require("ui/wire")
local Palette  = require("ui/palette")
local ColorPopup = require("ui/color_popup")
local IfaceScale = require("ui/iface_scale")
local InvViewer = require("ui/inv_viewer")

local Editor = {}
Editor.__index = Editor

-- registry: the live LibNodeGraph Registry. runtime: optional (see runtime.lua) — only reached for
-- its `screenMarkerCapture` (#39), the full-screen "Draw on screen" capture overlay a Screen Marker
-- node's `rect` Control arms.
--
-- The Editor is constructed and mounted **unbound** (#80): it holds no graph until `BindEntry`
-- swaps one in. The Manager (the root surface) is what opens an alert, at which point the nav owner
-- binds this one long-lived Editor to that entry rather than constructing a fresh one — mounting is
-- the fragile, retry-guarded part of this codebase, so it happens once at startup, not per open. An
-- unbound Editor is inert: it stays hidden (nav never shows it unbound), and its draw/update early-
-- out on `not visible`, so nothing dereferences the nil graph. `boundId` is the transient bound-
-- entry id (the persisted `current` pointer is gone, #80), what the host's write-back keys on.
--
-- The View (pan/zoom) is intentionally NOT restored: it resets to the default origin on every open
-- and every BindEntry (see resetView), so there's nothing to thread in or persist.
---@param registry LibNodeGraph.Registry
---@param runtime Watchdog.Runtime|nil
function Editor.new(registry, runtime)
    local self = setmetatable({
        graph = nil,               -- bound via BindEntry (#80); nil ⇒ inert/unbound
        boundId = nil,             -- the transient bound-entry id the host writes back under
        registry = registry,
        runtime = runtime,
        view = View.new(),
        layout = {},               -- nodeId -> {x, y} in Graph-space; replaced on BindEntry
        nodeOrder = {},            -- draw/z order, front-most last
        geoms = {},                -- per-frame geometry cache, nodeId -> geom
        mouse = { x = 0, y = 0 },
        pressed = false,
        mode = "idle",             -- idle | pan | dragnode | wire | colordrag | palettescroll
        editing = nil,             -- active inline Control editor: {nodeId,pinName,spec,widget,field}
        selected = nil,
        visible = false,           -- starts closed; opened via F8 / the panel button
        palette = Palette.new(),   -- the Node-creation popup (modal while open)
        colorPopup = ColorPopup.new(),  -- the color-picker popup (#30, modal while open)
        colorHexField = nil,       -- transient real InputField over the popup's hex row
        inventoryGrids = {},       -- nodeId -> prettyui.ItemGrid (Inventory Viewer, ADR-0010)
        viewerScroll = {},         -- nodeId -> row offset into the Snapshot
        tick = 0,                  -- Logic-tick counter, for double-click timing
        lastClickTick = -1000,     -- tick of the previous press (double-click pairing)
        lastClickX = 0,
        lastClickY = 0,
        window = {                 -- live content screen rect (synced from contentParent)
            x = Theme.WINDOW_X, y = Theme.WINDOW_Y,
            w = Theme.WINDOW_W, h = Theme.WINDOW_H,
        },
        canvas = nil,
        paletteCanvas = nil,       -- separate full-screen Canvas for the Palette (screen space,
                                   -- unclipped) so it can render past the Window edges
        capture = nil,
        contentParent = nil,       -- PrettyUI content host (Canvas only)
        overlayParent = nil,       -- capture + palette + toolbar + transient editors
        plusButton = nil,          -- real Button on overlay, top-right of content rect
        backButton = nil,          -- real "Back" Button on overlay, top-LEFT (#80 nav-up)
        onBack = nil,              -- host nav callback: navigate up to the Manager (set by main.lua)
    }, Editor)

    return self
end

-- Binds the Editor to alert `id`'s live graph + Layout and resets all transient view state, so an
-- open lands on a clean framing (#80). Called by the nav owner when a Manager alert row is double-
-- clicked; the graph is the *same* live instance the runtime fires, so edits and firing stay in
-- sync (unchanged from the old single-alert boot). Resets pan/zoom/selection/mode and dismisses any
-- open popup/palette/capture — none of the previous entry's transient UI may bleed into the next.
-- `boundId` is what the host's debounced write-back keys on (never the name — #75).
---@param id integer
---@param graph LibNodeGraph.Graph
---@param layout Watchdog.Layout|nil
function Editor:BindEntry(id, graph, layout)
    -- Tear down any transient editor/popup from the previous binding before its graph goes away.
    self:closeControlEditor()
    self:closeColorPopup()
    self.palette:Close()

    self.boundId = id
    self.graph = graph
    self.layout = layout or {}
    self.geoms = {}
    self.nodeOrder = {}
    self.selected = nil
    self.editing = nil
    self.pressed = false
    self.mode = "idle"
    self.wire = nil
    self.dragNodeId = nil
    self:resetView()
    InvViewer.DestroyAll(self)
end

-- Clears the binding on navigate-back (#80): the Editor becomes inert/unbound again. Kept distinct
-- from Unmount (which destroys components) — Unbind only drops the graph pointer + bound id so a
-- reload/back lands on the Manager with nothing bound. The host flushes the entry BEFORE calling this.
function Editor:Unbind()
    self:closeControlEditor()
    self:closeColorPopup()
    self.palette:Close()
    InvViewer.DestroyAll(self)
    self.boundId = nil
    self.graph = nil
    self.layout = {}
    self.geoms = {}
    self.nodeOrder = {}
    self.selected = nil
end

-- The live Layout map (nodeId -> {x,y}); mutated in place as nodes are dragged/created.
---@return Watchdog.Layout
function Editor:GetLayout()
    return self.layout
end

-- Whether the editor Window is currently open. Editing only happens while it's shown, so
-- the host uses this to persist only during an editing session (see main.lua's autosave).
function Editor:IsVisible()
    return self.visible
end

-- The content region in Canvas-draw (content-local) space. Origin is (0,0) at the top-left
-- of the PrettyUI content parent — no header inset (chrome lives outside this rect).
function Editor:viewportRect()
    local win = self.window
    return 0, 0, win.w, win.h
end

-- Converts an absolute screen point (e.g. from Mouse.GetPosition()) into content-local
-- Canvas-draw space. `self.window.x/y` must be the live content screen origin (see
-- syncContentOrigin) — PrettyUI owns window drag, so a stale cache misaligns hit-tests.
function Editor:toLocal(sx, sy)
    return sx - self.window.x, sy - self.window.y
end

-- Inverse of toLocal: content-local point → absolute screen. Used for the out-of-window
-- Palette on paletteCanvas (screen space, unclipped by the content Canvas).
function Editor:toScreen(lx, ly)
    return lx + self.window.x, ly + self.window.y
end

-- Graph-space point under the Viewport's content-local center (accounts for pan/zoom).
-- Used by the + button Palette so the new Node lands in the middle of what the user sees
-- (#96), rather than under the toolbar chrome that opened the panel.
---@return number gx
---@return number gy
function Editor:viewCenterGraph()
    local w, h = self.window.w, self.window.h
    return self.view:ToGraph(w * 0.5, h * 0.5)
end

-- Re-read the content parent's live screen rect into self.window. PrettyUI moves the window
-- root on title-drag; nested content's raw .x/.y are parent-relative, so prefer PrettyUI's
-- Tooltip context position resolver when present (absolute screen). Falls back to .x/.y.
function Editor:syncContentOrigin()
    local p = self.contentParent
    if p == nil then return end
    pcall(function()
        local x, y = p.x or 0, p.y or 0
        if prettyui ~= nil and prettyui.Tooltip ~= nil and prettyui.Tooltip.getContext ~= nil then
            local ctx = prettyui.Tooltip.getContext(p)
            if ctx ~= nil and type(ctx.position) == "function" then
                local ax, ay = ctx.position(p)
                if ax ~= nil and ay ~= nil then x, y = ax, ay end
            end
        end
        local w = self.window.w
        local h = self.window.h
        if p.width and p.width > 0 then w = p.width end
        if p.height and p.height > 0 then h = p.height end
        self.window.x, self.window.y = x, y
        self.window.w, self.window.h = w, h
    end)
    self:layoutToolbar()
    self:layoutTransientEditors()
end

-- Parent for clickable overlay chrome (toolbar + transient fields). Falls back to
-- contentParent only if Mount somehow lacked an overlay (should not happen in-client).
---@return ui.ComponentCollection|nil
function Editor:interactiveParent()
    return self.overlayParent or self.contentParent
end

-- Re-assert overlay child order: capture under palette under toolbar under transient
-- editors. Call after expandCapture / RaiseToFront / Mount so chrome stays clickable
-- while the overlay sits above the PrettyUI window.
function Editor:frontOverlayInteractives()
    pcall(function() if self.capture ~= nil then self.capture:MoveToFront() end end)
    InvViewer.Front(self)
    pcall(function() if self.paletteCanvas ~= nil then self.paletteCanvas:MoveToFront() end end)
    if self.backButton ~= nil then pcall(function() self.backButton:MoveToFront() end) end
    if self.plusButton ~= nil then pcall(function() self.plusButton:MoveToFront() end) end
    if self.editing ~= nil and self.editing.field ~= nil then
        pcall(function() self.editing.field:MoveToFront() end)
    end
    if self.colorHexField ~= nil then
        pcall(function() self.colorHexField:MoveToFront() end)
    end
end

-- Keep absolute-positioned overlay editors glued to content while PrettyUI drags the window.
function Editor:layoutTransientEditors()
    if self.editing ~= nil and self.editing.field ~= nil
        and self.editing.localX ~= nil and self.editing.localY ~= nil then
        local ax, ay = self:toScreen(self.editing.localX, self.editing.localY)
        pcall(function()
            self.editing.field:SetPos(ax, ay)
            if self.editing.sw ~= nil then
                self.editing.field:SetSize(self.editing.sw, self.editing.sh)
            end
        end)
    end
    if self.colorHexField ~= nil and self.colorHexLocalX ~= nil then
        local ax, ay = self:toScreen(self.colorHexLocalX, self.colorHexLocalY)
        pcall(function()
            self.colorHexField:SetPos(ax, ay)
            if self.colorHexLocalW ~= nil then
                self.colorHexField:SetSize(self.colorHexLocalW, self.colorHexLocalH)
            end
        end)
    end
end

--- Small helpers ------------------------------------------------------------------------

local function mousePos()
    if Mouse == nil or Mouse.GetPosition == nil then return nil end
    local ok, pos = pcall(function() return Mouse.GetPosition() end)
    if ok and pos ~= nil then
        -- Mouse is denser than interface units when InterfaceScale ≠ 100%; divide first
        -- so toLocal / palette hits line up with Canvas draw (native ui.* already scales).
        return IfaceScale.ToInterface(pos.x, pos.y)
    end
    return nil
end

local function modeLabelOf(nt, key)
    if nt == nil or nt.modes == nil then return nil end
    local modeDef = key and nt.modes[key]
    return (modeDef and modeDef.label) or key
end

local function pinExists(graph, nodeId, pinName)
    if pinName == nil then return false end
    for _, p in ipairs(graph:GetPins(nodeId) or {}) do
        if p.name == pinName then return true end
    end
    return false
end

local function dataCompatible(a, b)
    return a == b or a == "any" or b == "any"
end

-- First pin on `def` that can receive `want` (matching kind, opposite direction, compatible
-- Type Tag). Walks every Mode's pinOrder in SortedModes order so a pin that exists only on a
-- non-default Mode is still found. Returns pinName, modeKey (modeKey nil when the type has
-- no modes). pinSet comes from the live Registry instance (client cannot require engine modules).
---@param registry LibNodeGraph.Registry
---@param def table
---@param want { kind: string, direction: string, dataType: string|nil }
---@return string|nil pinName
---@return string|nil modeKey
function Editor.FirstCompatiblePin(registry, def, want)
    local wantDir = (want.direction == "out") and "in" or "out"
    local function firstCompatibleInOrder(pins, pinOrder)
        for _, pinName in ipairs(pinOrder or {}) do
            local p = pins[pinName]
            if p ~= nil and p.kind == want.kind and p.direction == wantDir then
                if p.kind ~= "data" or dataCompatible(p.dataType, want.dataType) then
                    return pinName
                end
            end
        end
        return nil
    end
    if def.modes ~= nil then
        for _, m in ipairs(Node.SortedModes(def)) do
            local pins, pinOrder = registry.pinSet(def, m.key)
            local pinName = firstCompatibleInOrder(pins, pinOrder)
            if pinName ~= nil then return pinName, m.key end
        end
        return nil, nil
    end
    local pins, pinOrder = registry.pinSet(def, nil)
    return firstCompatibleInOrder(pins, pinOrder), nil
end

-- An InputField's raw text content / pre-parsed numeric quantity (honors suffixes like
-- 1K/1M), read defensively since a field can be mid-teardown when these are read. Handed to a
-- Pin Control's own onChange commit callback when the host-mounted field changes.
local function fieldContent(field)
    local raw = ""
    pcall(function() raw = field.content or "" end)
    local quantity
    pcall(function() quantity = field.contentQuantity end)
    return raw, quantity
end

-- Resolves an enum member by name with a string fallback. The client's ui.Hook /
-- ui.InputFieldFilterMode / etc. carry the member's own name as its value, and some newer
-- members (ONCONTENTCHANGED, ONSELECTIONCHANGED) are missing from the generated stub but
-- present in-client — so a plain string works whether or not the enum table has the key.
local function enumv(tbl, name)
    if tbl ~= nil and tbl[name] ~= nil then return tbl[name] end
    return name
end

-- Whether an ONCONTENTCHANGED `cause` means the user finished (submit / focus loss / esc),
-- as opposed to a plain keystroke (CONTENT_CHANGE). Compared by value against
-- ui.InputFieldActionResult, tolerant of the raw string.
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

-- Native StyleSheet lookups for toolbar / transient fields (mirrors DevTools/menu.lua's
-- safeButtonStyle) — guarded since a stylesheet id can be absent/renamed.
local function safeButtonStyle()
    if id ~= nil and id.StyleSheet ~= nil and id.StyleSheet.BUTTON_DEFAULT ~= nil then
        return id.StyleSheet.BUTTON_DEFAULT
    end
    return nil
end

-- Dropdown stylesheet for the transient enum editor. Falls back through DROPDOWN -> BUTTON so
-- the ComboField still renders a background if the preferred id is missing/renamed.
local function safeComboStyle()
    if id ~= nil and id.StyleSheet ~= nil then
        return id.StyleSheet.COMBO_DEFAULT or id.StyleSheet.DROPDOWN_DEFAULT
            or id.StyleSheet.BUTTON_DEFAULT
    end
    return nil
end

-- Content-local toolbar button edge length (Back / + sit in the content area, not a header).
local TOOLBAR_BTN = 18
local TOOLBAR_PAD = 6

-- The reserved placeholder type key (#53), read from the authoritative source. LibNodeGraph is a
-- hard dependency (called unguarded in store.lua too), so no nil-guard or literal fallback — a
-- fallback string would only duplicate the constant and silently drift if the lib ever renamed it.
function Editor:unknownTypeKey()
    return LibNodeGraph.UNKNOWN_TYPE
end

-- Whether a node is a `__unknown__` placeholder, read authoritatively from its live type key
-- (not the per-frame geom, so it's valid even before the first draw builds geometry).
function Editor:isPlaceholderNode(nodeId)
    local node = self.graph.nodes[nodeId]
    return node ~= nil and node.typeKey == self:unknownTypeKey()
end

-- The original (missing) type key a placeholder stashes, or nil for a real node. Read from the
-- engine's documented `node.unknown` carrier (LibNodeGraph.Node.unknown) — the one piece of a
-- placeholder that survives only on the live node, not in the id/type projection GetNodes gives.
function Editor:unknownTypeOf(nodeId)
    local node = self.graph.nodes[nodeId]
    if node == nil or node.unknown == nil then return nil end
    return node.unknown.type
end

function Editor:meta(nodeId, typeKey)
    -- A placeholder is titled by the type it's standing in for, not the reserved key (#53).
    if typeKey == self:unknownTypeKey() then
        return { title = "Unknown: " .. (self:unknownTypeOf(nodeId) or "?"),
            category = nil, placeholder = true }
    end
    local nt = self.registry:GetNodeType(typeKey)
    if nt == nil then return { title = typeKey, category = nil } end
    return { title = nt.displayName or typeKey, category = nt.category }
end

function Editor:posOf(nodeId)
    local p = self.layout[nodeId]
    if p == nil then
        -- Nodes with no assigned position get a cascading default so nothing hides at 0,0.
        local n = 0
        for _ in pairs(self.layout) do n = n + 1 end
        p = { x = 60 + n * 40, y = 60 + n * 40 }
        self.layout[nodeId] = p
    end
    return p
end

function Editor:bringToFront(nodeId)
    for i, id in ipairs(self.nodeOrder) do
        if id == nodeId then
            table.remove(self.nodeOrder, i)
            break
        end
    end
    self.nodeOrder[#self.nodeOrder + 1] = nodeId
end

-- Rebuilds the per-frame geometry cache and keeps nodeOrder in sync with the Graph.
function Editor:buildGeoms()
    -- Input pins that already have an incoming Connection get a wire, not a Control box.
    local connectedIn = {}
    for _, c in ipairs(self.graph:GetConnections()) do
        connectedIn[c.toNode] = connectedIn[c.toNode] or {}
        connectedIn[c.toNode][c.toPin] = true
    end

    local unknownKey = self:unknownTypeKey()
    local present = {}
    for _, n in ipairs(self.graph:GetNodes()) do
        present[n.id] = n.typeKey
        local pos = self:posOf(n.id)
        local pins, opts
        if n.typeKey == unknownKey then
            -- A placeholder (#53) has no real pins (GetPins returns []); reconstruct display-only
            -- stubs from the wires touching it, and skip all interactive geometry (opts.placeholder).
            pins = Placeholder.Stubs(self.graph, n.id)
            opts = { placeholder = true }
        else
            pins = self.graph:GetPins(n.id) or {}
            opts = { connected = connectedIn[n.id] or {} }
            local nt = self.registry:GetNodeType(n.typeKey)
            if nt ~= nil and nt.modes ~= nil then
                opts.modeLabel = modeLabelOf(nt, self.graph:GetMode(n.id))
            end
            if n.typeKey == InvViewer.TYPE_KEY then
                local extra = InvViewer.ExtraBodyOpts(self.view.zoom)
                opts.extraBodyH = extra.extraBodyH
                opts.extraBodyW = extra.extraBodyW
            end
        end
        local geom = Node.BuildGeometry(pins, pos.x, pos.y, Theme.NODE_WIDTH, opts)
        geom.typeKey = n.typeKey
        -- Fill each Control box's current value + display string (Node stays graph-only).
        -- A composite Control (#25, e.g. coordgrid) shares one stored table across several
        -- boxes: a "field" box shows just its own axis, an "action" box is a fixed label.
        for _, ctrl in ipairs(geom.controls) do
            ctrl.value = self.graph:GetControl(n.id, ctrl.pinName)
            -- A nil stored Control (e.g. a graph saved before this pin had a default) shows
            -- the pin's default, so the box reflects the value the node would actually run with.
            if ctrl.value == nil then ctrl.value = ctrl.default end
            -- Every data Control is a Pin Control (ADR-0005): the Editor just asks the module for
            -- each sub-rect's display text and never branches on the control's kind. A mode row's
            -- checkbox tick/dim is derived at draw time from the baked `enabled` flag + the stored
            -- value (node.lua), so nothing else needs stamping here.
            -- #71: Capture Controls show "Cancel" while this pin's Capture Arm is live.
            if ctrl.kind == "capture" then
                ctrl.captureArmed = self:isCaptureArmed(n.id, ctrl.pinName)
            end
            ctrl.display = ctrl.pinControl.Display(ctrl)
        end
        self.geoms[n.id] = geom
    end
    -- Drop geoms/order for nodes that no longer exist; append newly seen ones.
    for id in pairs(self.geoms) do
        if present[id] == nil then self.geoms[id] = nil end
    end
    local seen = {}
    local kept = {}
    for _, id in ipairs(self.nodeOrder) do
        if present[id] and not seen[id] then
            kept[#kept + 1] = id
            seen[id] = true
        end
    end
    for id in pairs(present) do
        if not seen[id] then kept[#kept + 1] = id end
    end
    self.nodeOrder = kept
end

--- Hit-testing (uses last frame's geoms) ------------------------------------------------

-- Topmost pin under a screen point: { nodeId, entry } or nil. Front-most node wins. A
-- placeholder's stubs (#53) are deliberately excluded: they're display-only geometry, never
-- wire drag endpoints — the engine can't validate a wire to a pin whose real definition is gone.
function Editor:pinAt(sx, sy)
    for i = #self.nodeOrder, 1, -1 do
        local id = self.nodeOrder[i]
        local geom = self.geoms[id]
        if geom ~= nil and not geom.placeholder then
            local pin = Node.PinAt(geom, self.view, sx, sy)
            if pin ~= nil then return { nodeId = id, entry = pin } end
        end
    end
    return nil
end

-- Topmost node body under a screen point: nodeId or nil.
function Editor:nodeAt(sx, sy)
    for i = #self.nodeOrder, 1, -1 do
        local id = self.nodeOrder[i]
        local geom = self.geoms[id]
        if geom ~= nil and Node.HitBody(geom, self.view, sx, sy) then
            return id
        end
    end
    return nil
end

-- Topmost Control box under a screen point: { nodeId, ctrl } or nil. Front-most node wins.
function Editor:controlAt(sx, sy)
    for i = #self.nodeOrder, 1, -1 do
        local id = self.nodeOrder[i]
        local geom = self.geoms[id]
        if geom ~= nil then
            local ctrl = Node.ControlAt(geom, self.view, sx, sy)
            if ctrl ~= nil then return { nodeId = id, ctrl = ctrl } end
        end
    end
    return nil
end

-- Topmost exec-in test button under a screen point: { nodeId, tb } or nil. Front-most wins.
function Editor:testButtonAt(sx, sy)
    for i = #self.nodeOrder, 1, -1 do
        local id = self.nodeOrder[i]
        local geom = self.geoms[id]
        if geom ~= nil then
            local tb = Node.TestButtonAt(geom, self.view, sx, sy)
            if tb ~= nil then return { nodeId = id, tb = tb } end
        end
    end
    return nil
end

-- Topmost node whose header delete button is under a screen point: nodeId or nil.
function Editor:closeAt(sx, sy)
    for i = #self.nodeOrder, 1, -1 do
        local id = self.nodeOrder[i]
        local geom = self.geoms[id]
        if geom ~= nil and Node.HitClose(geom, self.view, sx, sy) then
            return id
        end
    end
    return nil
end

-- Topmost node whose Mode strip is under a screen point: nodeId or nil.
function Editor:modeStripAt(sx, sy)
    for i = #self.nodeOrder, 1, -1 do
        local id = self.nodeOrder[i]
        local geom = self.geoms[id]
        if geom ~= nil and Node.HitModeStrip(geom, self.view, sx, sy) then
            return id
        end
    end
    return nil
end

function Editor:connectionInto(nodeId, pinName)
    for _, c in ipairs(self.graph:GetConnections()) do
        if c.toNode == nodeId and c.toPin == pinName then return c end
    end
    return nil
end

-- Removes a node from the Graph (the engine cascades its Connections) and drops the UI-only
-- state that referenced it: its Layout entry, cached geometry, z-order slot, and selection.
-- buildGeoms would prune the geom/order next frame anyway, but clearing them here keeps any
-- later hit-tests within this same press consistent.
function Editor:deleteNode(nodeId)
    self.graph:RemoveNode(nodeId)
    self.layout[nodeId] = nil
    self.geoms[nodeId] = nil
    if self.selected == nodeId then self.selected = nil end
    for i, id in ipairs(self.nodeOrder) do
        if id == nodeId then
            table.remove(self.nodeOrder, i)
            break
        end
    end
end

--- Interaction ---------------------------------------------------------------------------

-- Begins an interaction on press. Only ever called from ONCLICK (a genuine mouse-DOWN
-- captured on our layer) — deliberately NOT from ONHOLD, which fires whenever the button
-- is held AND the cursor is over the component, even for a press that started elsewhere
-- (the game world, or the Window before the capture shrank back). Such a foreign press
-- never routes its ONRELEASE to us, so starting a gesture from it strands it stuck-to-cursor.
-- The pressed-guard still protects against a duplicate ONCLICK re-starting mid-gesture.
function Editor:beginPress()
    if self.pressed or not self.visible then return end
    self:syncContentOrigin()
    local mx, my = mousePos()
    if mx == nil then return end
    local lx, ly = self:toLocal(mx, my)
    self.mouse.x, self.mouse.y = lx, ly

    -- The Palette is modal: while it's open, a click either picks a Node Type or dismisses
    -- it — never a drag gesture, so this is handled before pressed/expandCapture. It hit-tests
    -- in SCREEN space (it draws on the full-screen paletteCanvas), so pass the raw mouse, not
    -- the toLocal'd coords.
    if self.palette.open then
        if self.editing ~= nil then self:closeControlEditor() end
        self:handlePaletteClick(mx, my)
        return
    end

    -- The color popup (#30) is modal too, but unlike the Palette some of its parts (the SV
    -- field, hue strip, R/G/B/A rows) DO drag — handleColorPopupClick sets up pressed/
    -- expandCapture itself for those, so it's not a plain return-only branch like above.
    if self.colorPopup.open then
        if self.editing ~= nil then self:closeControlEditor() end
        self:handleColorPopupClick(lx, ly)
        return
    end

    -- Click-away commits a pin editor, but not when the press is on the Mode strip: that
    -- ComboField parks the pin editor until SetMode (drop if the pin vanished, restore if not).
    local onModeStrip = self:modeStripAt(lx, ly)
    if self.editing ~= nil then
        if self.editing.kind == "nodeMode" then
            if not onModeStrip then
                self:closeControlEditor()
                return
            end
        elseif not onModeStrip then
            self:closeControlEditor()
        end
    end

    -- The toolbar Back/+ are real Buttons on the overlay (above capture) with their own
    -- ONBUTTONPRESSED handlers, so they never reach here.

    -- Pair this press with the previous one for double-click detection (recorded for every
    -- press; only acted on when the second click lands on empty space, below).
    local dbl = (self.tick - self.lastClickTick) <= Theme.DOUBLECLICK_TICKS
        and math.abs(lx - self.lastClickX) <= Theme.DOUBLECLICK_DIST
        and math.abs(ly - self.lastClickY) <= Theme.DOUBLECLICK_DIST
    self.lastClickTick, self.lastClickX, self.lastClickY = self.tick, lx, ly

    -- From here it's a real drag gesture. Grow the Capture Layer to full-screen for its
    -- duration, so the release (and continued tracking) still reaches us if the cursor
    -- leaves the content. Restored to content size in endPress.
    self.pressed = true
    self:expandCapture()

    -- A node's header delete button takes priority over its body/pins beneath it. Deleting
    -- isn't a drag, so unwind the gesture setup (pressed/capture) the way the double-click
    -- branch does before returning.
    local hitClose = self:closeAt(lx, ly)
    if hitClose ~= nil then
        self.pressed = false
        self:positionCapture()
        self:deleteNode(hitClose)
        return
    end

    -- Mode strip (ADR-0011): reconstructs pins via Graph:SetMode, not a Control. Before pin
    -- glyphs so a click on the dropdown isn't stolen as a wire start.
    local hitMode = self:modeStripAt(lx, ly)
    if hitMode ~= nil then
        self.pressed = false
        self:positionCapture()
        self.selected = hitMode
        self:bringToFront(hitMode)
        self:openNodeModeDropdown(hitMode)
        return
    end

    local hitPin = self:pinAt(lx, ly)
    if hitPin ~= nil then
        self:beginWire(hitPin)
        return
    end

    -- A Control box hands the click to its Pin Control (ADR-0005): the Editor passes a host and the
    -- clicked sub-rect and does NO per-control branching — the module decides whether to mount an
    -- editor, fire an action, toggle, or open a popup/overlay. Not a drag, so unwind the gesture
    -- setup the way the close-button branch does (the box sits in the value column, clear of the
    -- pin glyph).
    local hitCtrl = self:controlAt(lx, ly)
    if hitCtrl ~= nil then
        self.pressed = false
        self:positionCapture()
        self.selected = hitCtrl.nodeId
        self:bringToFront(hitCtrl.nodeId)
        hitCtrl.ctrl.pinControl.Press(self:controlHost(hitCtrl.nodeId, hitCtrl.ctrl), hitCtrl.ctrl)
        return
    end

    -- A test button on an exec-in pin fires that pin (runs the node as if wired) — not a drag,
    -- so unwind the gesture setup the same way the Control branch does.
    local hitTest = self:testButtonAt(lx, ly)
    if hitTest ~= nil then
        self.pressed = false
        self:positionCapture()
        self.selected = hitTest.nodeId
        self:bringToFront(hitTest.nodeId)
        self:fireTestPin(hitTest.nodeId, hitTest.tb.pinName)
        return
    end

    local hitNode = self:nodeAt(lx, ly)
    if hitNode ~= nil then
        self.selected = hitNode
        self:bringToFront(hitNode)
        local pos = self:posOf(hitNode)
        local gx, gy = self.view:ToGraph(lx, ly)
        self.mode = "dragnode"
        self.dragNodeId = hitNode
        self.dragDX, self.dragDY = gx - pos.x, gy - pos.y
        return
    end

    -- Empty space: a double-click opens the Palette; a single click starts a pan.
    if dbl then
        self.pressed = false          -- not a drag after all
        self:positionCapture()
        self.lastClickTick = -1000    -- consume so a 3rd click isn't a fresh double
        self:openPaletteUnfiltered(lx, ly)
        return
    end
    self.selected = nil
    self.mode = "pan"
end

-- Starts a pending Wire from the pressed pin. Pressing a connected input "grabs" its
-- existing Connection (disconnects it and re-anchors to the original output) — the
-- grab-from-input disconnect gesture.
function Editor:beginWire(hit)
    self.mode = "wire"

    if hit.entry.direction == "in" then
        local conn = self:connectionInto(hit.nodeId, hit.entry.name)
        -- Don't grab a wire whose source is a placeholder stub (#53): re-anchoring the loose end
        -- to a pin the engine can't resolve would fail to reconnect, silently dropping a wire the
        -- user only meant to inspect. Leave it intact — a fresh wire from this input can still
        -- replace it if dropped on a real output (linkPins swaps the data input's connection).
        if conn ~= nil and not self:isPlaceholderNode(conn.fromNode) then
            self.graph:Disconnect(conn.id)
            local srcGeom = self.geoms[conn.fromNode]
            local srcEntry = srcGeom and srcGeom.byName[conn.fromPin]
            if srcEntry ~= nil then
                self.wire = { nodeId = conn.fromNode, entry = srcEntry }
                return
            end
        end
    end

    self.wire = { nodeId = hit.nodeId, entry = hit.entry }
end

-- Per-tick drag application (driven by Event.Logic poll in main).
function Editor:update()
    self.tick = self.tick + 1   -- advances even without a cursor, for double-click timing
    self:syncContentOrigin()
    -- Resting capture must track the live content rect while PrettyUI drags the window;
    -- skip while expanded (gesture / open palette).
    if self.visible and not self.pressed and not self.palette.open then
        self:positionCapture()
    end
    local mx, my = mousePos()   -- absolute; converted to local per-branch below
    if mx == nil then return end

    if self.pressed then
        if self.mode == "pan" then
            local lx, ly = self:toLocal(mx, my)
            self.view:PanBy(lx - self.mouse.x, ly - self.mouse.y)
        elseif self.mode == "dragnode" and self.dragNodeId ~= nil then
            local lx, ly = self:toLocal(mx, my)
            local gx, gy = self.view:ToGraph(lx, ly)
            local pos = self:posOf(self.dragNodeId)
            pos.x, pos.y = gx - self.dragDX, gy - self.dragDY
        elseif self.mode == "colordrag" then
            local lx, ly = self:toLocal(mx, my)
            self.colorPopup:ApplyDrag(self.colorDragPart, lx, ly)
            self:commitColorPopupValue()
        elseif self.mode == "palettescroll" then
            -- Palette hit-tests in screen space, so scrub with the raw mouse (no toLocal).
            self.palette:ScrollToY(my)
        end
        -- "wire" needs no state here; the loose end follows self.mouse in Draw.
    end

    self.mouse.x, self.mouse.y = self:toLocal(mx, my)
end

-- Finalizes a gesture on release.
function Editor:endPress()
    if not self.pressed then return end
    self.pressed = false

    if self.mode == "wire" and self.wire ~= nil then
        self:commitWire()
    end

    self.mode = "idle"
    self.wire = nil
    self.dragNodeId = nil
    self.colorDragPart = nil
    self.palette.scrollDragging = false
    -- Shrink the Capture Layer back to the Window — UNLESS this release just opened the Palette
    -- (a Wire dropped on empty Viewport, via commitWire above), which needs the capture to stay
    -- full-screen so its out-of-window rows remain clickable. closePalette restores it later.
    if not self.palette.open then self:positionCapture() end
end

-- Commits one output->input link. Order matters: re-dropping the *identical* wire toggles it
-- off (removes the existing edge) — uniform for exec and data. Otherwise a Data input takes a
-- single Connection, so a *different-source* occupant is replaced first. Connect returns a
-- reason rather than throwing (uniform result contract); a rejection (e.g. cycle) is logged,
-- never crashes the frame. Shared by Wire drops and Palette auto-connect.
function Editor:linkPins(outNode, outPin, inNode, inPin, isData)
    local dup = self.graph:FindConnection(outNode, outPin, inNode, inPin)
    if dup ~= nil then
        self.graph:Disconnect(dup.id)   -- toggle off
        return true
    end
    if isData then
        local existing = self:connectionInto(inNode, inPin)
        if existing ~= nil then self.graph:Disconnect(existing.id) end
    end
    local id, reason = self.graph:Connect(outNode, outPin, inNode, inPin)
    if id == nil and log ~= nil then
        log("Watchdog: connect rejected — " .. tostring(reason))
    end
    return id ~= nil
end

-- Resolves the pending Wire against whatever pin is under the cursor and connects if
-- legal. A miss inside the Viewport opens the Palette filtered to Node Types that can
-- accept this Wire (drag-to-create); a miss outside, or an illegal drop, simply discards —
-- and if the gesture began by grabbing a Connection off an input, that Connection stays
-- removed (drop-on-empty = delete).
function Editor:commitWire()
    local mx, my = self.mouse.x, self.mouse.y
    local target = self:pinAt(mx, my)
    if target == nil then
        local vx, vy, vw, vh = self:viewportRect()
        if mx >= vx and mx <= vx + vw and my >= vy and my <= vy + vh then
            self:openPaletteFiltered(mx, my, self.wire)
        end
        return
    end

    local a, b = self.wire, target
    local outEnd, inEnd
    if a.entry.direction == "out" and b.entry.direction == "in" then
        outEnd, inEnd = a, b
    elseif a.entry.direction == "in" and b.entry.direction == "out" then
        outEnd, inEnd = b, a
    else
        return -- two outputs or two inputs: illegal
    end

    if outEnd.nodeId == inEnd.nodeId then return end
    if outEnd.entry.kind ~= inEnd.entry.kind then return end
    if outEnd.entry.kind == "data"
        and not dataCompatible(outEnd.entry.dataType, inEnd.entry.dataType) then
        return
    end

    self:linkPins(outEnd.nodeId, outEnd.entry.name, inEnd.nodeId, inEnd.entry.name,
        inEnd.entry.kind == "data")
end

--- Palette (Node creation) --------------------------------------------------------------

-- Opens the Palette listing every Node Type. `lx, ly` are content-local: they place the
-- panel (via toScreen) and, by default, the new-Node Graph-space origin (via ToGraph).
-- `opts.anchorGX/GY` override that point; `opts.centerOnAnchor` places the Node Body's
-- center on it instead of the origin (toolbar + → Viewport center, #96). Expands the
-- Capture Layer to full-screen so rows drawn past the Window edge are still clickable
-- (closePalette restores it). Single unfiltered open path (ADR-0003) — double-click,
-- empty-space, and toolbar + all come through here.
---@param lx number
---@param ly number
---@param opts { anchorGX: number, anchorGY: number, centerOnAnchor: boolean }|nil
function Editor:openPaletteUnfiltered(lx, ly, opts)
    -- Mutual exclusion with the color popup: the toolbar + is a real Button (bypasses
    -- beginPress's colorPopup-modal check), so every unfiltered open enforces it here.
    self:closeColorPopup()
    local gx, gy
    if opts ~= nil and opts.anchorGX ~= nil and opts.anchorGY ~= nil then
        gx, gy = opts.anchorGX, opts.anchorGY
    else
        gx, gy = self.view:ToGraph(lx, ly)
    end
    local scx, scy = self:toScreen(lx, ly)
    self.palette:Open(self.registry, nil, {
        screenX = scx, screenY = scy, anchorGX = gx, anchorGY = gy,
        centerOnAnchor = opts ~= nil and opts.centerOnAnchor == true,
        connect = nil,
    })
    self:expandCapture()
    self.mode = "idle"
    self.selected = nil
end

-- Toolbar "+" entry (#96): panel near the button; Node Body center lands on the Viewport
-- center so the new Node sits in the middle of what the user sees, not under the chrome.
-- Delegates to openPaletteUnfiltered (ADR-0003 single open path).
function Editor:openPaletteFromPlus()
    local w = self.window.w
    local bs = TOOLBAR_BTN
    local gx, gy = self:viewCenterGraph()
    self:openPaletteUnfiltered(w - 2 * bs - 12, TOOLBAR_PAD + bs, {
        anchorGX = gx, anchorGY = gy, centerOnAnchor = true,
    })
end

-- Opens the Palette filtered to Node Types with a Pin that could receive `source` (the
-- dragged Wire's Pin): matching kind, opposite direction, and (for Data) a compatible
-- Type Tag. The first such Pin per type (across every Mode) is recorded as the auto-connect
-- target, with `targetMode` when the match lives on a non-default pin-set.
function Editor:openPaletteFiltered(lx, ly, source)
    local gx, gy = self.view:ToGraph(lx, ly)
    local scx, scy = self:toScreen(lx, ly)
    local want = source.entry
    local filter = function(def)
        return Editor.FirstCompatiblePin(self.registry, def, want)
    end
    self.palette:Open(self.registry, filter, {
        screenX = scx, screenY = scy, anchorGX = gx, anchorGY = gy,
        connect = { nodeId = source.nodeId, entry = source.entry },
    })
    self:expandCapture()
end

-- Closes the Palette and shrinks the Capture Layer back to the Window (undoing the
-- full-screen expand openPalette* applied), unless a drag gesture still owns the capture.
function Editor:closePalette()
    self.palette:Close()
    if not self.pressed then self:positionCapture() end
end

-- Routes a click while the Palette is open: pick an item, or dismiss on an outside click.
-- `mx, my` are SCREEN coords (the Palette hit-tests in screen space, matching how it draws on
-- the full-screen paletteCanvas) — beginPress passes the raw mouse position, not toLocal'd.
function Editor:handlePaletteClick(mx, my)
    -- A press in the scrollbar gutter starts a scroll-drag (jump-to-cursor now, scrub as the
    -- cursor moves — see update's "palettescroll" branch). This is the one Palette press that
    -- becomes a real drag gesture, so it sets up pressed/expandCapture like the color popup's
    -- draggable parts do; checked before RowAt since the gutter isn't a row.
    if self.palette:ScrollbarAt(mx, my) then
        self.pressed = true
        self:expandCapture()
        self.mode = "palettescroll"
        self.palette.scrollDragging = true
        self.palette:ScrollToY(my)
        return
    end
    local row = self.palette:RowAt(mx, my)
    if row ~= nil then
        self:placeFromPalette(row)
    elseif not self.palette:Contains(mx, my) then
        self:closePalette()
    end
    -- A click on a header row or inner padding is ignored, keeping the Palette open.
end

-- Creates the chosen Node Type at the Palette's anchor and, in drag-to-create mode,
-- auto-connects the source Pin to the recorded target Pin. When centerOnAnchor is set
-- (#96 toolbar +), the Node Body's center is placed on the anchor rather than its origin.
function Editor:placeFromPalette(row)
    local anchorGX, anchorGY = self.palette.anchorGX, self.palette.anchorGY
    local centerOnAnchor = self.palette.centerOnAnchor
    local connect = self.palette.connect
    local targetPin = row.targetPin
    self:closePalette()

    local ok, newId = pcall(function()
        return self.graph:AddNode(row.typeKey, nil, row.targetMode)
    end)
    if not ok or newId == nil then
        if log ~= nil then log("Watchdog: AddNode failed — " .. tostring(newId)) end
        return
    end
    local x, y = anchorGX, anchorGY
    if centerOnAnchor then
        local pins = self.graph:GetPins(newId) or {}
        local opts = { connected = {} }
        local nt = self.registry:GetNodeType(row.typeKey)
        if nt ~= nil and nt.modes ~= nil then
            opts.modeLabel = modeLabelOf(nt, self.graph:GetMode(newId))
        end
        local geom = Node.BuildGeometry(pins, 0, 0, Theme.NODE_WIDTH, opts)
        x = anchorGX - geom.w * 0.5
        y = anchorGY - geom.h * 0.5
    end
    self.layout[newId] = { x = x, y = y }
    self:bringToFront(newId)
    self.selected = newId

    if connect ~= nil and targetPin ~= nil then
        local src = connect.entry
        if src.direction == "out" then
            self:linkPins(connect.nodeId, src.name, newId, targetPin, src.kind == "data")
        else
            self:linkPins(newId, targetPin, connect.nodeId, src.name, src.kind == "data")
        end
    end
end

-- Reconstructs `nodeId` into `key` via Graph:SetMode. After a successful reconstruct, dismiss
-- an inline Control editor (or one parked under the Mode ComboField) whose pin is gone.
---@param nodeId integer
---@param key string
---@return boolean
function Editor:applyNodeMode(nodeId, key)
    if not self.graph:SetMode(nodeId, key) then return false end
    self:dropVanishedParkedOrEditing(nodeId)
    return true
end

-- Parks a pin Control editor under the Mode ComboField so a cancelled/surviving reconstruct
-- can restore it. Does not Destroy the field.
function Editor:parkControlEditor()
    local e = self.editing
    if e == nil or e.kind == "nodeMode" then return end
    self._modeEditStash = e
    self.editing = nil
    if e.field ~= nil then pcall(function() e.field.visible = false end) end
end

function Editor:discardParkedEditor()
    local e = self._modeEditStash
    self._modeEditStash = nil
    if e ~= nil and e.field ~= nil then pcall(function() e.field:Destroy() end) end
end

function Editor:unparkControlEditor()
    local e = self._modeEditStash
    if e == nil then return end
    self._modeEditStash = nil
    self.editing = e
    if e.field ~= nil then pcall(function() e.field.visible = true end) end
    self:frontOverlayInteractives()
end

function Editor:dropVanishedParkedOrEditing(nodeId)
    local e = self.editing
    if e ~= nil and e.kind ~= "nodeMode" and e.nodeId == nodeId
        and not pinExists(self.graph, nodeId, e.pinName) then
        self:closeControlEditor()
    end
    local s = self._modeEditStash
    if s ~= nil and s.nodeId == nodeId and not pinExists(self.graph, nodeId, s.pinName) then
        self:discardParkedEditor()
    end
end

-- Mounts the same ComboField path enum Controls use, over the Mode strip. ComboField labels
-- are unique displays from ModeDropdownChoices (key suffix when labels collide).
function Editor:openNodeModeDropdown(nodeId)
    local geom = self.geoms[nodeId]
    if geom == nil or geom.modeStrip == nil then return end
    local node = self.graph.nodes[nodeId]
    if node == nil then return end
    local nt = self.registry:GetNodeType(node.typeKey)
    local choices = Node.ModeDropdownChoices(nt)
    if #choices == 0 then return end
    self:parkControlEditor()
    local labels = {}
    local byDisplay = {}
    for i, c in ipairs(choices) do
        labels[i] = c.display
        byDisplay[c.display] = c.key
    end
    local current = self.graph:GetMode(nodeId)
    local initial
    for _, c in ipairs(choices) do
        if c.key == current then initial = c.display break end
    end
    local strip = geom.modeStrip
    local ctrl = { x = strip.x, y = strip.y, w = strip.w, h = strip.h, kind = "nodeMode" }
    self:mountControlDropdown(nil, nodeId, ctrl, { labels = labels, initial = initial },
        function(display)
            local key = byDisplay[display]
            if key ~= nil then self:applyNodeMode(nodeId, key) end
        end)
end

function Editor:onScroll(...)
    local delta
    for _, v in ipairs({ ... }) do
        if type(v) == "number" then delta = v break end
    end
    if delta == nil or delta == 0 then return end
    -- While the Palette is open the wheel scrolls its list instead of zooming the View.
    if self.palette.open then
        self.palette:Scroll(delta)
        return
    end
    -- A transient editor is pinned to a fixed screen rect; zooming would strand it, so
    -- commit and close it first. The color popup is the same kind of fixed-screen-rect
    -- overlay, so it closes on zoom too.
    if self.editing ~= nil then self:closeControlEditor() end
    if self.colorPopup.open then self:closeColorPopup() end
    local mx, my = mousePos()
    local lx, ly
    if mx ~= nil then lx, ly = self:toLocal(mx, my) else lx, ly = self.mouse.x, self.mouse.y end
    local factor = delta > 0 and (1 / 1.1) or 1.1
    self.view:ZoomAt(lx, ly, factor, Theme.ZOOM_MIN, Theme.ZOOM_MAX)
end

--- Control commit ------------------------------------------------------------------------

-- The one path every Control edit in this file commits through: writes the value via
-- Graph:SetControl, then runs the "control-commit" leg of the generalized `preload(node)`
-- node-type hook (#33) — the other leg (graph-restore) runs from Runtime:AddAlert at startup.
-- A resource-backed node (e.g. action.custom_sound) preloads the instant its dropdown Control
-- is picked, not just next reload. Silent no-op if no runtime was wired in (e.g. a headless
-- Editor in a future test) — PreloadNode itself already no-ops without a registry set.
function Editor:setControl(nodeId, pinName, value)
    pcall(function() self.graph:SetControl(nodeId, pinName, value) end)
    if self.runtime ~= nil then
        pcall(function() self.runtime:PreloadNode(self.graph, nodeId) end)
    end
end

--- Test button (per exec-in pin) --------------------------------------------------------

-- Fires one exec-in pin of `nodeId` directly through the engine, running that node's own
-- run(ctx) as if an upstream wire had fired into `pinName` (ctx.exec == pinName, no payload).
-- Guarded like linkPins: a node whose run errors must never crash the frame. This is a live
-- fire against the real graph — the node's actual side effects (log lines, overlays, sounds,
-- info boxes) happen, which is the point: it exercises the node in isolation for testing.
function Editor:fireTestPin(nodeId, pinName)
    local ok, err = pcall(function() self.graph:FireInput(nodeId, pinName) end)
    if not ok and log ~= nil then
        log("Watchdog: test fire failed — " .. tostring(err))
    end
end

--- Marker Capture Arm (#39/#40/#71) ---------------------------------------------------------

-- Shared arm/cancel/retarget for Screen + Object Capture Arms: cancel the *other* kind
-- (mutual exclusion), same-Control re-click cancels, otherwise Arm with `onCommit`.
---@param primary { IsArmed: fun(self): boolean, Cancel: fun(self), Arm: fun(self, any, string, function), nodeId: any, pinName: string|nil }|nil
---@param other { IsArmed: fun(self): boolean, Cancel: fun(self) }|nil
---@param nodeId any
---@param pinName string
---@param onCommit fun(value: any)
local function toggleMarkerCapture(primary, other, nodeId, pinName, onCommit)
    if primary == nil then return end
    local CaptureArm = require("ui/capture_arm")
    if other ~= nil and other:IsArmed() then
        other:Cancel()
    end
    if CaptureArm.Decide(primary.nodeId, primary.pinName, nodeId, pinName) == "cancel"
        and primary:IsArmed() then
        primary:Cancel()
        return
    end
    primary:Arm(nodeId, pinName, onCommit)
end

-- Arms the shared full-screen "Draw on screen" capture overlay for this node's capture pin.
-- Same-Control re-click cancels; arming cancels any live Object Marker Capture Arm.
function Editor:armScreenMarkerCapture(nodeId, pinName)
    if self.runtime == nil then return end
    toggleMarkerCapture(
        self.runtime.screenMarkerCapture,
        self.runtime.objectMarkerCapture,
        nodeId, pinName,
        function(rect) self:setControl(nodeId, pinName, rect) end)
end

-- Arms the shared MiniMenu select mode. Same-Control re-click cancels; arming cancels any
-- live Screen Marker Capture Arm. Commits on Examine of a LOC.
function Editor:armObjectMarkerCapture(nodeId, pinName)
    if self.runtime == nil then return end
    toggleMarkerCapture(
        self.runtime.objectMarkerCapture,
        self.runtime.screenMarkerCapture,
        nodeId, pinName,
        function(object) self:setControl(nodeId, pinName, object) end)
end

-- True when the named Capture Control is the live Capture Arm target (#71 Cancel label).
---@param nodeId integer
---@param pinName string
---@return boolean
function Editor:isCaptureArmed(nodeId, pinName)
    if self.runtime == nil then return false end
    for _, cap in ipairs({ self.runtime.screenMarkerCapture, self.runtime.objectMarkerCapture }) do
        if cap ~= nil and cap:IsArmed() and cap.nodeId == nodeId and cap.pinName == pinName then
            return true
        end
    end
    return false
end


--- Color popup (#30) ----------------------------------------------------------------------

-- A press that could start a drag (SV field, hue strip, R/G/B/A rows), keyed by PartAt's
-- return value. Everything else ("hex", "close", "other", nil-outside) is a single click.
local COLOR_DRAG_PARTS = { sv = true, hue = true, r = true, g = true, b = true, a = true }

-- Opens the color popup anchored just below the clicked swatch chip. Only ever called with
-- the popup already closed — while it's open, beginPress's modal check above routes every
-- click (including a re-click of the same chip, which the popup sees as a click outside its
-- own rect and closes on — one of #30's dismiss triggers) to handleColorPopupClick instead,
-- so this never has to reopen over itself. Any node Control editor IS still a real scenario
-- to guard against — it isn't gated by that same modal check — so it's closed first, same
-- rule ADR-0004 already applies elsewhere.
-- `codec` (#60) is the swatch Pin Control's hex format/parse table, what the popup round-trips its
-- one hex field through — so the popup keeps its own file/lifecycle and needs no Control knowledge:
-- the swatch Pin Control hands its Widget's hex codec straight in through the host's OpenColorPopup.
---@param nodeId integer
---@param ctrl table
---@param codec table
function Editor:openColorPopup(nodeId, ctrl, codec)
    if self.editing ~= nil then self:closeControlEditor() end
    local geom = self.geoms[nodeId]
    if geom == nil then return end
    local cp = self.colorPopup
    local sx, sy = self.view:ToScreen(geom.x + ctrl.x, geom.y + ctrl.y + ctrl.h)
    local current = self.graph:GetControl(nodeId, ctrl.pinName)
    if current == nil then current = ctrl.default end
    cp:Open(nodeId, ctrl.pinName, codec, current, sx, sy)
end

-- Tears down the transient hex field (if mounted) and closes the popup. Idempotent, so it's
-- safe to call defensively from anywhere that needs "make sure the popup isn't open."
function Editor:closeColorPopup()
    self:closeColorHexEditor()
    self.colorPopup:Close()
end

-- Routes a click while the popup is open (called from beginPress, mirroring
-- handlePaletteClick): a draggable part starts a real drag gesture (pressed/expandCapture,
-- same as any other drag — this is the one way the popup differs from the Palette, whose
-- clicks are all single-shot); the hex box mounts its own transient InputField; the close
-- glyph or a click outside the panel dismisses; a click on inert padding/the prev-cur chips
-- does nothing, keeping the popup open.
function Editor:handleColorPopupClick(lx, ly)
    local cp = self.colorPopup
    local part = cp:PartAt(lx, ly)
    if part == "close" then
        self:closeColorPopup()
        return
    end
    if part == "hex" then
        self:openColorHexEditor()
        return
    end
    if COLOR_DRAG_PARTS[part] then
        if self.colorHexField ~= nil then self:closeColorHexEditor() end
        self.pressed = true
        self:expandCapture()
        self.mode = "colordrag"
        self.colorDragPart = part
        cp:ApplyDrag(part, lx, ly)
        self:commitColorPopupValue()
        return
    end
    if not cp:Contains(lx, ly) then
        self:closeColorPopup()
    end
    -- part == "other" (padding/prev-cur chips) or nil (Draw hasn't run yet): stay open.
end

-- Writes the popup's current working value back through the same setControl path every
-- other Control uses — live, once per drag tick, mirroring the coordgrid axis fields' and the
-- plain scalar editor's live-write behavior.
function Editor:commitColorPopupValue()
    local cp = self.colorPopup
    if not cp.open then return end
    self:setControl(cp.nodeId, cp.pinName, cp:Value())
end

-- Mounts a transient InputField over the popup's hex row (ADR-0004's mechanism, reused here
-- for the one textual field the popup has). Filter is NONE rather than ALPHANUMERIC/NUMERIC
-- — the swatch codec's parse hook (Color.ParseHex8) already strips non-hex characters on commit,
-- so the field just needs to accept whatever's typed and let the parse sort it out.
function Editor:openColorHexEditor()
    self:closeColorHexEditor()
    if self:interactiveParent() == nil or ui == nil then return end
    local cp = self.colorPopup
    local r = cp.rect and cp.rect.hex
    if r == nil then return end

    -- The popup lives in the same content-local frame the Canvas draws in, so its rect's
    -- coords are content-local; mountInputField converts to absolute for the overlay.
    local field = self:mountInputField(r.x, r.y, r.w, r.h, "NONE", 8,
        cp:Format(cp:Value()),
        function(_, cause, newContent) self:onColorHexContent(cause, newContent) end)
    if field == nil then return end
    self.colorHexField = field
    self.colorHexLocalX, self.colorHexLocalY = r.x, r.y
    self.colorHexLocalW, self.colorHexLocalH = r.w, r.h
    self:frontOverlayInteractives()
    pcall(function() field:SetFocus() end)
end

-- ONCONTENTCHANGED: live-parse every keystroke into the popup's working value through the
-- codec's own parse hook (Color.ParseHex8's guard, so a too-short/unparsable string is a no-op
-- and a mid-typed hex never nukes the color); close just the hex field (not the whole popup) on
-- a submit/focus-loss cause.
function Editor:onColorHexContent(cause, _newContent)
    if self.colorHexField == nil then return end
    local raw = ""
    pcall(function() raw = self.colorHexField.content or "" end)
    local cp = self.colorPopup
    cp:SetValue(cp:Parse(raw, cp:Value()))
    self:commitColorPopupValue()
    if isSubmitCause(cause) then self:closeColorHexEditor() end
end

function Editor:closeColorHexEditor()
    if self.colorHexField == nil then return end
    pcall(function() self.colorHexField:Destroy() end)
    self.colorHexField = nil
    self.colorHexLocalX, self.colorHexLocalY = nil, nil
    self.colorHexLocalW, self.colorHexLocalH = nil, nil
end

-- The Esc cascade (#80). Escape means different things depending on what's active, resolved
-- highest-priority-first so a nested affordance is dismissed before the surface navigates:
--   1. an open color popup (#30's third dismiss trigger, alongside outside-click and re-click),
--   2. an in-progress Screen Marker capture (#39) / Object Marker select mode (#40),
--   3. otherwise — nothing local claimed it — navigate **up to the Manager** (goBack), the final rung.
-- Each rung that fires **consumes** the Escape and stops the cascade, so a marker-capture cancel
-- never also pops you back to the Manager. Wired from main.lua's existing KeyDown subscription; only
-- reached while the Editor is the visible surface.
function Editor:onEscape()
    if self.colorPopup.open then
        self:closeColorPopup()
        return
    end
    if self.runtime ~= nil and self.runtime.screenMarkerCapture ~= nil
        and self.runtime.screenMarkerCapture:IsArmed() then
        self.runtime.screenMarkerCapture:Cancel()
        return
    end
    if self.runtime ~= nil and self.runtime.objectMarkerCapture ~= nil
        and self.runtime.objectMarkerCapture:IsArmed() then
        self.runtime.objectMarkerCapture:Cancel()
        return
    end
    self:goBack()
end

-- Screen rect for a transient editor field mounted over a Control box `ctrl`. The field's
-- native font is a fixed pixel size (it can't scale with the View), so the component is sized
-- in screen pixels: a fixed readable height, width tracking the box but never below the min,
-- centered vertically on the box row so a taller-than-box field straddles it evenly. Returns
-- content-local coords (Canvas-draw frame); mountInputField converts to absolute for the
-- overlay parent. Shared by the inline editor and the Pin Control host.
---@param geom table
---@param ctrl table
---@return number px, number py, number sw, number sh
function Editor:controlEditRect(geom, ctrl)
    local sx, sy = self.view:ToScreen(geom.x + ctrl.x, geom.y + ctrl.y)
    local boxH = self.view:Scale(ctrl.h)
    local sw = math.max(self.view:Scale(ctrl.w), Theme.CONTROL_EDIT_MIN_W)
    local sh = Theme.CONTROL_EDIT_H
    return sx, sy + (boxH - sh) * 0.5, sw, sh
end

--- Pin Control host seam (ADR-0005) ------------------------------------------------------

-- The typed contract every Pin Control reaches the Editor through — the seam's whole surface, so a
-- Pin Control that calls a capability the host doesn't expose (or fat-fingers `host:Commmit`)
-- surfaces as an undefined-field at check time, the same guard the RunContext class gives node
-- run(ctx) code (CLAUDE.md typechecking note). Both the real host (Editor:controlHost) and the
-- test adapter (tests/fake_control_host.lua) satisfy it. `ctrl` is a geom control sub-rect.
---@class ControlHost
---@field GetControl fun(self: ControlHost): any
---@field Commit fun(self: ControlHost, value: any)
---@field MountField fun(self: ControlHost, ctrl: table, opts: table, onChange: fun(raw: string, quantity: number|nil))
---@field MountDropdown fun(self: ControlHost, ctrl: table, opts: table, onSelect: fun(label: string))
---@field OpenColorPopup fun(self: ControlHost, codec: table)
---@field ArmCapture fun(self: ControlHost, kind: string)

-- The `host` a Pin Control is handed on press: the Editor-only capabilities it needs, and no
-- more. It exposes reading and committing the Pin's stored Control value (Commit runs the same
-- Graph:SetControl + preload path every other Control edit uses) and mounting a transient field or
-- dropdown over one of the control's boxes. The Editor does NO per-control branching — a Pin
-- Control pushes work through this seam. Its test adapter is the fake host in
-- tests/fake_control_host.lua, which is what makes a Pin Control's whole press->commit lifecycle
-- testable headless. The host-routed controls (#60) reach two more Editor collaborators through it —
-- the swatch opens the Color Popup, the capture arms a marker overlay — rather than committing a
-- value directly; the overlay/popup commit for them through the same setControl path.
---@return ControlHost
function Editor:controlHost(nodeId, ctrl)
    local editor = self
    return {
        -- The raw stored Control value (no default fallback) — a per-axis read-modify-write
        -- seeds a fresh table from nil exactly as the old commitAxisField path did.
        GetControl = function(_)
            return editor.graph:GetControl(nodeId, ctrl.pinName)
        end,
        Commit = function(_, value)
            editor:setControl(nodeId, ctrl.pinName, value)
        end,
        -- Mounts a transient numeric/text field over the given sub-rect, wiring its content
        -- changes back to the Pin Control's own `onChange(raw, quantity)` commit callback.
        MountField = function(_, mctrl, opts, onChange)
            editor:mountControlField(ctrl.pinControl, nodeId, mctrl, opts, onChange)
        end,
        -- Mounts a transient dropdown over the given sub-rect from a list of labels, reporting the
        -- picked label back to the Pin Control's `onSelect(label)` callback (which maps it to a
        -- value and commits). Selection is by label, never id — ADR-0004's ComboField caveat.
        MountDropdown = function(_, mctrl, opts, onSelect)
            editor:mountControlDropdown(ctrl.pinControl, nodeId, mctrl, opts, onSelect)
        end,
        -- Opens the Color Popup over the swatch chip (#60). The popup keeps its own file/lifecycle;
        -- the Pin Control passes the hex codec so the popup needs no Control Spec of its own.
        OpenColorPopup = function(_, codec)
            editor:openColorPopup(nodeId, ctrl, codec)
        end,
        -- Arms the marker capture the Pin Control asks for (#60): "object" -> the MiniMenu select
        -- mode, anything else -> the Screen Marker drag overlay. Each overlay commits the finished
        -- value back through setControl itself; a headless host with no runtime is a silent no-op.
        ArmCapture = function(_, kind)
            if kind == "object" then
                editor:armObjectMarkerCapture(nodeId, ctrl.pinName)
            else
                editor:armScreenMarkerCapture(nodeId, ctrl.pinName)
            end
        end,
    }
end

-- Mounts the host's transient field for a Pin Control edit. Reuses the same real ui.InputField
-- machinery and self.editing lifecycle as openControlEditor (re-fronted each frame in draw(),
-- committed and torn down on click-away/submit), but records the Pin Control + its onChange
-- callback so commitField routes back through the Pin Control instead of the old kind switches.
---@param pinControl table
---@param nodeId integer
---@param ctrl table
---@param opts { filter: string|nil, maxLen: integer|nil, initial: string|nil }
---@param onChange fun(raw: string, quantity: number|nil)
function Editor:mountControlField(pinControl, nodeId, ctrl, opts, onChange)
    if self.editing ~= nil then self:closeControlEditor() end
    if self:interactiveParent() == nil or ui == nil then return end
    local geom = self.geoms[nodeId]
    if geom == nil then return end

    local px, py, sw, sh = self:controlEditRect(geom, ctrl)
    local field = self:mountInputField(px, py, sw, sh, opts.filter or "NONE", opts.maxLen or 128,
        opts.initial or "",
        function(_, cause, _newContent) self:onControlContent(cause, _newContent) end)
    if field == nil then return end

    self.editing = { nodeId = nodeId, pinName = ctrl.pinName, field = field,
        kind = ctrl.kind, axis = ctrl.axis, pinControl = pinControl, onChange = onChange,
        localX = px, localY = py, sw = sw, sh = sh }
    self:frontOverlayInteractives()
    pcall(function() field:SetFocus() end)
end

-- Mounts the host's transient DROPDOWN for a Pin Control edit (the enum path). Mirrors the enum
-- branch of openControlEditor — a real ui.ComboField styled so it isn't invisible, entries Add'd by
-- label, the current label pre-selected, and ONSELECTIONCHANGED wired to commit — but routes the
-- pick back through the Pin Control's own `onSelect(label)` instead of the old spec/choice path.
-- Like an enum's inline editor it commits ONLY on an actual selection change: the editing session
-- records no `onChange`, so a plain close (commitField's Pin Control branch) is a no-op — merely
-- mounting then unmounting the dropdown can't rewrite the value (the bool-flip bug ADR-0004 fixed).
---@param pinControl table
---@param nodeId integer
---@param ctrl table
---@param opts { labels: string[]|nil, initial: string|nil }
---@param onSelect fun(label: string)
function Editor:mountControlDropdown(pinControl, nodeId, ctrl, opts, onSelect)
    if self.editing ~= nil then
        -- Remounting the Mode ComboField must not unpark the pin editor parked under it.
        self:closeControlEditor({ skipUnpark = ctrl.kind == "nodeMode" })
    end
    local parent = self:interactiveParent()
    if parent == nil or ui == nil then return end
    local geom = self.geoms[nodeId]
    if geom == nil then return end

    local px, py, sw, sh = self:controlEditRect(geom, ctrl)
    local ax, ay = self:toScreen(px, py)
    local field
    local ok = pcall(function()
        field = ui.ComboField.new(parent)
        pcall(function() field.stylesheetID = safeComboStyle() end)
        field.clickthrough = false
        field:SetPos(ax, ay)
        field:SetSize(sw, sh)
        -- The `i` passed to Add only guarantees id uniqueness; ComboField re-sorts alphabetically
        -- and reassigns ids, so selection is matched by label text, not id (see openControlEditor).
        for i, label in ipairs(opts.labels or {}) do
            field:Add(label, i)
        end
        local sel = 1
        for i, e in ipairs(field.entries) do
            if e.text == opts.initial then sel = i break end
        end
        field:Select(sel, false)
        field:Subscribe(enumv(ui.Hook, "ONSELECTIONCHANGED"), function()
            self:onControlDropdownSelect()
        end)
    end)
    if not ok or field == nil then return end

    self.editing = { nodeId = nodeId, pinName = ctrl.pinName, field = field,
        kind = ctrl.kind, axis = ctrl.axis, pinControl = pinControl, onSelect = onSelect,
        localX = px, localY = py, sw = sw, sh = sh }
    self:frontOverlayInteractives()
    pcall(function() field:SetFocus() end)
end

-- ONSELECTIONCHANGED for a Pin Control dropdown: hand the picked label (the authoritative field —
-- NOT selectedID) to the Pin Control's onSelect, then tear the dropdown down. A plain close commits
-- nothing (the session has no onChange), so this is the only place an enum Pin Control commits.
function Editor:onControlDropdownSelect()
    local e = self.editing
    if e == nil then return end
    local label
    pcall(function() label = e.field.selectedLabel end)
    if label ~= nil and e.onSelect ~= nil then e.onSelect(label) end
    self:closeControlEditor()
end

--- Inline Control editing ---------------------------------------------------------------

-- Mounts a transient real ui.InputField on the overlay (ADR-0004's mechanism): styled so it
-- isn't invisible, positioned in absolute screen space from content-local (px,py), filtered,
-- seeded with initial content, and wired to `onChanged`. Shared by the node's inline Control
-- editor and the color popup's hex field. Returns the field, or nil if mounting failed.
function Editor:mountInputField(px, py, sw, sh, filterMode, maxLen, initialContent, onChanged)
    local parent = self:interactiveParent()
    if parent == nil then return nil end
    local ax, ay = self:toScreen(px, py)
    local field
    local ok = pcall(function()
        field = ui.InputField.new(parent)
        pcall(function() field.stylesheetID = safeButtonStyle() end)
        field.clickthrough = false
        field:SetPos(ax, ay)
        field:SetSize(sw, sh)
        field:Setup(enumv(ui.TextContentVisibilityMode, "VISIBLE"),
            enumv(ui.InputFieldFilterMode, filterMode), maxLen)
        field.content = initialContent
        field:Subscribe(enumv(ui.Hook, "ONCONTENTCHANGED"), onChanged)
    end)
    if not ok then return nil end
    return field
end

-- Drives the active Pin Control-mounted field's commit (ADR-0005). Both the live-write
-- (onControlContent) and the close path (closeControlEditor) funnel here; the Pin Control's own
-- onChange callback — handed to it when the host mounted the field — does the read-modify-write
-- and decides whether to commit at all. A dropdown editing session records no onChange (an enum
-- commits only from its ONSELECTIONCHANGED pick, via mountControlDropdown), so a plain close of a
-- dropdown is a no-op here — merely mounting then unmounting can't rewrite the value.
function Editor:commitField()
    local e = self.editing
    if e == nil then return end
    if e.onChange ~= nil then
        local raw, quantity = fieldContent(e.field)
        e.onChange(raw, quantity)
    end
end

-- ONCONTENTCHANGED: live-write every keystroke; close on a submit/focus-loss cause.
function Editor:onControlContent(cause, _newContent)
    if self.editing == nil then return end
    self:commitField()
    if isSubmitCause(cause) then self:closeControlEditor() end
end

-- Commits the active edit and destroys the transient editor.
---@param opts { skipUnpark: boolean }|nil
function Editor:closeControlEditor(opts)
    local e = self.editing
    if e == nil then return end
    self:commitField()
    self.editing = nil
    if e.field ~= nil then pcall(function() e.field:Destroy() end) end
    if e.kind == "nodeMode" and not (opts and opts.skipUnpark) then
        self:unparkControlEditor()
    end
end

--- Drawing -------------------------------------------------------------------------------

-- Fills the viewport and draws the grid, both bounded to the viewport rect so nothing
-- bleeds onto the game outside the Window.
function Editor:drawBackground()
    local vx, vy, vw, vh = self:viewportRect()
    self.canvas:AddRectangle(vx, vy, vw, vh, Theme.Vec4(Theme.COL_VIEWPORT_BG))

    local step = self.view:Scale(Theme.GRID_SPACING)
    if step < 6 then return end -- too dense to be useful when far out
    local gridCol = Theme.Vec4(Theme.COL_GRID)
    local panX, panY = self.view.panX, self.view.panY

    -- Grid lines sit at graph multiples of GRID_SPACING; draw only those falling in-viewport.
    for k = math.ceil((vx - panX) / step), math.floor((vx + vw - panX) / step) do
        local x = panX + k * step
        self.canvas:AddLine(x, vy, x, vy + vh, 1, gridCol)
    end
    for k = math.ceil((vy - panY) / step), math.floor((vy + vh - panY) / step) do
        local y = panY + k * step
        self.canvas:AddLine(vx, y, vx + vw, y, 1, gridCol)
    end
end

-- Whether a node's screen rect overlaps the viewport at all (cull test).
function Editor:geomVisible(geom, vx, vy, vw, vh)
    local x0, y0 = self.view:ToScreen(geom.x, geom.y)
    local x1 = x0 + self.view:Scale(geom.w)
    local y1 = y0 + self.view:Scale(geom.h)
    return not (x1 < vx or x0 > vx + vw or y1 < vy or y0 > vy + vh)
end

function Editor:drawConnections()
    for _, c in ipairs(self.graph:GetConnections()) do
        local fromGeom = self.geoms[c.fromNode]
        local toGeom = self.geoms[c.toNode]
        if fromGeom ~= nil and toGeom ~= nil then
            local ax, ay = Node.PinCenter(fromGeom, c.fromPin)
            local bx, by = Node.PinCenter(toGeom, c.toPin)
            local src = fromGeom.byName[c.fromPin]
            if ax and bx and src then
                local color = Wire.ColorFor(src.kind, src.dataType)
                Wire.DrawCurve(self.canvas, self.view, ax, ay, 1, bx, by, -1, color)
            end
        end
    end
end

function Editor:drawPendingWire()
    if self.mode ~= "wire" or self.wire == nil then return end
    local geom = self.geoms[self.wire.nodeId]
    if geom == nil then return end
    local fx, fy = Node.PinCenter(geom, self.wire.entry.name)
    if fx == nil then return end
    local gx, gy = self.view:ToGraph(self.mouse.x, self.mouse.y)
    local color = Wire.ColorFor(self.wire.entry.kind, self.wire.entry.dataType)
    local fixedDir = Wire.DirFor(self.wire.entry.direction)
    Wire.DrawCurve(self.canvas, self.view, fx, fy, fixedDir, gx, gy, -fixedDir, color)
end

function Editor:draw()
    if self.canvas == nil or not self.visible then return end
    self:syncContentOrigin()
    pcall(function() self.canvas:MoveToFront() end)
    -- Overlay chrome: capture under palette under Back/+ under transient editors.
    self:frontOverlayInteractives()
    self.canvas:Clear()

    self:buildGeoms()
    InvViewer.Sync(self)
    local vx, vy, vw, vh = self:viewportRect()

    self:drawBackground()
    self:drawConnections()

    for _, id in ipairs(self.nodeOrder) do
        local geom = self.geoms[id]
        if geom ~= nil and self:geomVisible(geom, vx, vy, vw, vh) then
            local editingHere = self.editing ~= nil and self.editing.nodeId == id
            Node.Draw(self.canvas, self.view, geom, self:meta(id, geom.typeKey),
                { selected = (id == self.selected),
                  mouseX = self.mouse.x, mouseY = self.mouse.y,
                  editingPin = editingHere and self.editing.pinName or nil,
                  editingKind = editingHere and self.editing.kind or nil,
                  editingAxis = editingHere and self.editing.axis or nil })
        end
    end

    self:drawPendingWire()

    -- The color popup draws last on the content Canvas, clamped inside the Viewport.
    -- (It and the Palette are mutually exclusive — see openColorPopup /
    -- openPaletteUnfiltered — so they never contend for the surface.)
    if self.colorPopup.open then
        self.colorPopup:Draw(self.canvas, vx, vy, vw, vh, self.mouse.x, self.mouse.y,
            { hexEditing = self.colorHexField ~= nil })
    end

    -- The Palette draws on its OWN full-screen Canvas in screen space, so it can extend past
    -- the content edges (the content Canvas above clips). Cleared every frame; fronted and
    -- redrawn only while open, clamped to the whole screen rather than the Viewport.
    if self.paletteCanvas ~= nil then
        pcall(function() self.paletteCanvas:Clear() end)
        if self.palette.open then
            pcall(function() self.paletteCanvas:MoveToFront() end)
            local sw, sh = self:screenSize()
            local msx, msy = self:toScreen(self.mouse.x, self.mouse.y)
            self.palette:Draw(self.paletteCanvas, 0, 0, sw, sh, msx, msy)
        end
    end
end

--- Visibility ----------------------------------------------------------------------------

-- Full-screen interface size, read from the overlay parent (fallback if unavailable).
-- Content Canvas is content-sized; palette / expandCapture need the true screen.
function Editor:screenSize()
    local w, h = 1920, 1080
    local p = self.overlayParent
    if p ~= nil then
        pcall(function()
            if p.width and p.width > 0 then w = p.width end
            if p.height and p.height > 0 then h = p.height end
        end)
    end
    return w, h
end

-- Resting capture tracks the live content screen rect (not the PrettyUI title bar), so
-- title-drag and close stay clickable outside it.
function Editor:positionCapture()
    if self.capture == nil then return end
    local win = self.window
    pcall(function()
        self.capture:SetPos(win.x, win.y)
        self.capture:SetSize(win.w, win.h)
    end)
end

-- Grow the Capture Layer to cover the whole screen (used during a drag / open palette so
-- the release reaches us wherever the cursor ends up). Also fronts the overlay parent so
-- capture/palette sit above the PrettyUI window (Show/title-drag bury siblings).
function Editor:expandCapture()
    if self.capture == nil then return end
    pcall(function()
        if self.overlayParent ~= nil and self.overlayParent.MoveToFront ~= nil then
            self.overlayParent:MoveToFront()
        end
        self.capture:SetPos(0, 0)
        self.capture:SetSize(0, 0, 1.0, 1.0)
    end)
    -- Keep Back/+ (and any open field) above the expanded capture so they stay clickable.
    self:frontOverlayInteractives()
end

-- Re-asserts overlay + capture + chrome z-order after another always-on overlay (e.g.
-- InfoBox drag) jumped in front. Mux RaiseToFront covers window chrome; this fronts the
-- Editor's overlay children. No-op while hidden.
function Editor:RaiseToFront()
    if not self.visible then return end
    pcall(function()
        if self.overlayParent ~= nil and self.overlayParent.MoveToFront ~= nil then
            self.overlayParent:MoveToFront()
        end
    end)
    self:frontOverlayInteractives()
end

-- Shell tucked away (mux SetVisible false / Close / F8) without Pop or surface SetVisible:
-- dismiss palette/popups and abandon gestures so a reopen doesn't leave a clickthrough
-- ghost. Does NOT flip self.visible or hide canvas — pan/zoom must survive F8.
function Editor:OnShellHide()
    self.pressed = false
    self.mode = "idle"
    self.wire = nil
    self.dragNodeId = nil
    self:closePalette()
    self:closeControlEditor()
    self:closeColorPopup()
    self:positionCapture()
end

-- The default framing (pan + zoom) applied on a fresh Mount and each time the surface is
-- opened. Centralized so the two callers can't drift. Recentering on open is deliberate:
-- pan or zoom far enough and your nodes scroll off-screen with no way back, so every open
-- snaps the graph transform back to this known origin.
function Editor:resetView()
    self.view.panX = 0
    self.view.panY = 0
    self.view.zoom = 1.0
end

function Editor:SetVisible(v)
    local becomingVisible = v and not self.visible
    self.visible = v and true or false
    -- Re-center the graph every time the surface opens, so a stray pan can never lose the nodes.
    if becomingVisible then self:resetView() end
    if not self.visible then
        -- Abandon any in-progress gesture (and dismiss the Palette / close the inline editor)
        -- so nothing resumes mid-interaction when reshown.
        self.pressed = false
        self.mode = "idle"
        self.wire = nil
        self.dragNodeId = nil
        self.palette:Close()
        self:closeControlEditor()
        self:closeColorPopup()
    end
    if self.canvas ~= nil then
        pcall(function() self.canvas.hidden = not self.visible end)
    end
    if self.plusButton ~= nil then
        pcall(function() self.plusButton.hidden = not self.visible end)
    end
    if self.backButton ~= nil then
        pcall(function() self.backButton.hidden = not self.visible end)
    end
    if self.paletteCanvas ~= nil then
        pcall(function() self.paletteCanvas.hidden = not self.visible end)
    end
    if self.capture ~= nil then
        pcall(function()
            self.capture.hidden = not self.visible
            self.capture.enabled = self.visible  -- stop intercepting game input while hidden
        end)
        -- On show, ensure the Capture Layer is back to content size (also recovers it if a
        -- prior drag left it expanded), so the toggle doubles as a reset.
        if self.visible then
            self:syncContentOrigin()
            self:positionCapture()
        end
    end
    InvViewer.Sync(self)
end

function Editor:Toggle()
    self:SetVisible(not self.visible)
end

--- Mount / unmount -----------------------------------------------------------------------

-- Keeps Back/+ in absolute screen space over the live content rect (overlay-mounted).
function Editor:layoutToolbar()
    local win = self.window
    local bs = TOOLBAR_BTN
    if self.plusButton ~= nil then
        pcall(function()
            self.plusButton:SetPos(win.x + win.w - bs - TOOLBAR_PAD, win.y + TOOLBAR_PAD)
            self.plusButton:SetSize(bs, bs)
        end)
    end
    if self.backButton ~= nil then
        pcall(function()
            self.backButton:SetPos(win.x + TOOLBAR_PAD, win.y + TOOLBAR_PAD)
            self.backButton:SetSize(4 * bs, bs)
        end)
    end
end

-- Mounts Canvas under contentParent; toolbar + capture + palette under overlayParent.
-- Window chrome is external (PrettyUI / Multiplexer). Abort if either parent or Canvas fails.
---@param contentParent ui.ComponentCollection
---@param overlayParent ui.ComponentCollection
function Editor:Mount(contentParent, overlayParent)
    if contentParent == nil or overlayParent == nil then
        if log ~= nil then log("Watchdog: Editor Mount needs contentParent and overlayParent") end
        return
    end
    if ui == nil or ui.Canvas == nil then
        if log ~= nil then log("Watchdog: ui.Canvas unavailable, aborting Editor Mount") end
        return
    end

    self.contentParent = contentParent
    self.overlayParent = overlayParent
    self:syncContentOrigin()

    local okCanvas, canvas = pcall(function() return ui.Canvas.new(contentParent) end)
    if not okCanvas or canvas == nil then
        self.contentParent = nil
        self.overlayParent = nil
        if log ~= nil then log("Watchdog: Canvas Mount failed") end
        return
    end
    self.canvas = canvas
    self.canvas:SetPos(0, 0)
    -- Fill the content parent; size tracks the host via relative anchors when resized.
    self.canvas:SetSize(0, 0, 1.0, 1.0)
    self.canvas.clickthrough = true

    -- Invisible Capture Layer on the overlay (not nested under content) so it can grow to
    -- true full-screen during a drag / open palette (see expandCapture).
    local okCap, capture = pcall(function() return ui.Button.new(overlayParent) end)
    if okCap and capture ~= nil then
        self.capture = capture
        self.capture.alpha = 0
        self.capture.clickthrough = false
    end

    -- Palette's full-screen Canvas on the overlay so it isn't clipped to content.
    local okPal, paletteCanvas = pcall(function() return ui.Canvas.new(overlayParent) end)
    if okPal and paletteCanvas ~= nil then
        self.paletteCanvas = paletteCanvas
        self.paletteCanvas:SetPos(0, 0)
        self.paletteCanvas:SetSize(0, 0, 1.0, 1.0)
        self.paletteCanvas.clickthrough = true
    end

    -- Toolbar on the overlay *above* capture (same parent) — contentParent children cannot
    -- out-rank the mux overlay once it sits above the PrettyUI window.
    self:mountToolbar(overlayParent)

    self:positionCapture()

    -- Start a gesture ONLY on ONCLICK (a mouse-DOWN this layer actually captured). ONHOLD is
    -- intentionally left unsubscribed: it also fires when a press that began elsewhere is
    -- dragged over us, and that foreign press's ONRELEASE never comes back to us — so binding
    -- it to beginPress strands the drag stuck-to-cursor. Movement is polled in update().
    if self.capture ~= nil then
        self.capture:Subscribe(ui.Hook.ONCLICK, function() self:beginPress() end)
        self.capture:Subscribe(ui.Hook.ONRELEASE, function() self:endPress() end)
        self.capture:Subscribe(ui.Hook.ONSCROLLWHEEL, function(...) self:onScroll(...) end)
    end

    self:frontOverlayInteractives()

    self:resetView()
    self:SetVisible(self.visible)
end

-- Back + "+" as overlay-mounted toolbar Buttons, absolute screen pos over the content rect.
---@param overlayParent ui.ComponentCollection
function Editor:mountToolbar(overlayParent)
    local win = self.window
    local bs = TOOLBAR_BTN

    local okPlus, plus = pcall(function() return ui.Button.new(overlayParent) end)
    if okPlus and plus ~= nil then
        pcall(function() plus.stylesheetID = safeButtonStyle() end)
        plus:SetPos(win.x + win.w - bs - TOOLBAR_PAD, win.y + TOOLBAR_PAD)
        plus:SetSize(bs, bs)
        plus.clickthrough = false
        plus.text.content = "+"
        plus:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
            self:openPaletteFromPlus()
            return true
        end)
        pcall(function()
            plus.cursorConfig.mouseOverCursor = id.Cursor.CURSOR_GOTO
        end)
        self.plusButton = plus
    end

    -- "Back" nav-up (#80): host onBack flushes/unbinds; falls back to self-hide when unwired.
    local okBack, back = pcall(function() return ui.Button.new(overlayParent) end)
    if okBack and back ~= nil then
        pcall(function() back.stylesheetID = safeButtonStyle() end)
        back:SetPos(win.x + TOOLBAR_PAD, win.y + TOOLBAR_PAD)
        back:SetSize(4 * bs, bs)
        back.clickthrough = false
        pcall(function() back.text.content = "Back" end)
        back:Subscribe(ui.Hook.ONBUTTONPRESSED, function() self:goBack() return true end)
        self.backButton = back
    end
end

-- Navigate up to the Manager: run the host's onBack if wired, else fall back to hiding this surface
-- (headless/standalone Editor with no Manager above). The nav owner's onBack flushes the bound
-- entry and unbinds; see main.lua.
function Editor:goBack()
    if self.onBack ~= nil then
        pcall(self.onBack)
    else
        self:SetVisible(false)
    end
end

function Editor:Unmount()
    self:closeControlEditor()  -- tear down any transient editor before its parent goes away
    self:closeColorPopup()
    InvViewer.DestroyAll(self)
    if self.paletteCanvas ~= nil then
        pcall(function() self.paletteCanvas:Destroy() end)
        self.paletteCanvas = nil
    end
    if self.capture ~= nil then
        pcall(function() self.capture:Destroy() end)
        self.capture = nil
    end
    if self.plusButton ~= nil then
        pcall(function() self.plusButton:Destroy() end)
        self.plusButton = nil
    end
    if self.backButton ~= nil then
        pcall(function() self.backButton:Destroy() end)
        self.backButton = nil
    end
    if self.canvas ~= nil then
        pcall(function() self.canvas:Destroy() end)
        self.canvas = nil
    end
    self.contentParent = nil
    self.overlayParent = nil
end

return Editor
