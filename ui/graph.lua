-- graph.lua — the Editor: the pannable/zoomable Viewport onto a live LibNodeGraph Graph.
--
-- Owns the View (pan/zoom), the Layout (nodeId -> Graph-space position), the input state
-- machine, and all hit-testing. Draws everything each frame onto one Canvas (immediate
-- mode, ADR-0001) mounted as a child of a real GroupBox, which supplies the native
-- header/title/frame and hosts the toolbar Buttons. Mutates the Graph through the engine's
-- own Connect/Disconnect so the picture and the model can't drift. UI presentation only —
-- no graph structure is invented here.
--
-- The editor lives in a draggable Window (a logical screen-space rect). Because the Canvas
-- is a child of the GroupBox, and child components position in coordinates relative to
-- their parent's own origin (confirmed against DevTools/menu.lua's nested panels), every
-- draw call and hit-test in this file works in that same GroupBox-local frame — NOT
-- absolute screen coordinates. `self.window.x/y` (the Window's absolute screen position)
-- is only ever used to place the GroupBox and the Capture Layer themselves, or to convert
-- an incoming absolute Mouse.GetPosition() into local space via `toLocal`. Dragging the
-- Window just moves the GroupBox (and Capture); the Canvas and its content ride along for
-- free — no pan compensation needed. Input is caught by a Capture Layer sized to the
-- Window (kept as a separate, absolutely-positioned, full-screen-capable sibling — see
-- Mount — since child components can't size themselves to the true screen), so the game
-- still receives clicks outside it. A keybind (wired in main) toggles visibility.

local Theme    = require("ui/theme")
local View     = require("ui/view")
local Node     = require("ui/node")
local Placeholder = require("ui/placeholder")
local Wire     = require("ui/wire")
local Palette  = require("ui/palette")
local Controls = require("ui/controls")
local ColorPopup = require("ui/color_popup")

local Editor = {}
Editor.__index = Editor

-- The mode descriptor (from an object_marker.mode composite spec's `modes` list, #40) for a given
-- checkbox row's key, or nil. Drives the row's label / enabled-dim / "needs render API" reason.
local function modeDescriptor(spec, key)
    if spec == nil or spec.modes == nil then return nil end
    for _, m in ipairs(spec.modes) do
        if m.key == key then return m end
    end
    return nil
end

-- graph, registry: the live LibNodeGraph objects. layout: optional saved node positions.
-- runtime: optional (see runtime.lua) — only reached for its `screenMarkerCapture` (#39), the
-- full-screen "Draw on screen" capture overlay a Screen Marker node's `rect` Control arms.
-- The View (pan/zoom) is intentionally NOT restored: it resets to the default origin on every
-- open (see resetView), so there's nothing to thread in or persist.
---@param graph LibNodeGraph.Graph
---@param registry LibNodeGraph.Registry
---@param layout Watchdog.Layout|nil
---@param runtime table|nil
function Editor.new(graph, registry, layout, runtime)
    local self = setmetatable({
        graph = graph,
        registry = registry,
        runtime = runtime,
        view = View.new(),
        layout = layout or {},     -- nodeId -> {x, y} in Graph-space
        nodeOrder = {},            -- draw/z order, front-most last
        geoms = {},                -- per-frame geometry cache, nodeId -> geom
        mouse = { x = 0, y = 0 },
        pressed = false,
        mode = "idle",             -- idle | pan | dragnode | wire | dragwindow
        editing = nil,             -- active inline Control editor: {nodeId,pinName,spec,widget,field}
        selected = nil,
        visible = false,           -- starts closed; opened via F8 / the panel button
        palette = Palette.new(),   -- the Node-creation popup (modal while open)
        colorPopup = ColorPopup.new(),  -- the color-picker popup (#30, modal while open)
        colorHexField = nil,       -- transient real InputField over the popup's hex row
        tick = 0,                  -- Logic-tick counter, for double-click timing
        lastClickTick = -1000,     -- tick of the previous press (double-click pairing)
        lastClickX = 0,
        lastClickY = 0,
        window = {                 -- screen-space rect the editor occupies
            x = Theme.WINDOW_X, y = Theme.WINDOW_Y,
            w = Theme.WINDOW_W, h = Theme.WINDOW_H,
        },
        canvas = nil,
        paletteCanvas = nil,       -- separate full-screen Canvas for the Palette (screen space,
                                   -- unclipped) so it can render past the Window edges
        capture = nil,
        rootParent = nil,          -- the client's root component, kept for screenSize()
        groupBox = nil,            -- real GroupBox providing the native header/title/frame
        plusButton = nil,          -- real Button, top-right of the GroupBox
        closeButton = nil,         -- real Button, top-right of the GroupBox
    }, Editor)

    return self
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

-- The content region: x, y, w, h, in GroupBox-local (Canvas-draw) space. Its height is the
-- Window height MINUS the reserved header strip: the Canvas is a child that starts at the
-- content-area origin (WINDOW_HEADER_H below the frame top), so of its full win.h only
-- (win.h - WINDOW_HEADER_H) is actually visible — the GroupBox clips the overshooting bottom
-- strip. Verified in-client (clip probe, 2026-07-17): drawing past this height is silently cut
-- off, which is what let the Palette believe it had room it didn't and get its bottom clipped.
-- Width needs no such adjustment (the Canvas spans the full win.w). The native header (title
-- text) floats above local y=0 per the _TITLED stylesheet's overlap convention, so nothing
-- here paints over it.
function Editor:viewportRect()
    local win = self.window
    return 0, 0, win.w, win.h - Theme.WINDOW_HEADER_H
end

-- Whether a local-space point is inside the Window's header strip. `local` space is the
-- Canvas draw frame (see toLocal), whose Y=0 is the TOP of the content area; the header sits
-- just above it, so in local space it spans Y [-WINDOW_HEADER_H, 0].
function Editor:inHeader(sx, sy)
    local win = self.window
    return sx >= 0 and sx <= win.w and sy >= -Theme.WINDOW_HEADER_H and sy <= 0
end

-- Converts an absolute screen point (e.g. from Mouse.GetPosition()) into the Canvas's
-- draw frame, which is what every draw call and hit-test in this file works in. The Canvas
-- is a child of the GroupBox and starts BELOW the GroupBox's reserved header strip, so a
-- screen point's content-local Y is offset down by the header height — subtract it here so
-- `local` space lines up with where the Canvas actually paints (otherwise nodes, wires, and
-- popups all read one header-height too low). Ties to the same WINDOW_HEADER_H used for
-- SetHeaderLayout so the two can't drift.
function Editor:toLocal(sx, sy)
    return sx - self.window.x, sy - self.window.y - Theme.WINDOW_HEADER_H
end

-- Inverse of toLocal: a Canvas-draw-space (GroupBox-local) point back to absolute screen
-- coordinates. Used for the out-of-window Palette, which draws on its own full-screen Canvas
-- (paletteCanvas) in screen space so it can extend past the Window edges — the window Canvas
-- clips to its bounds (verified in-client), so an overflowing popup has to live on a
-- full-screen surface instead.
function Editor:toScreen(lx, ly)
    return lx + self.window.x, ly + self.window.y + Theme.WINDOW_HEADER_H
end

--- Small helpers ------------------------------------------------------------------------

local function mousePos()
    if Mouse == nil or Mouse.GetPosition == nil then return nil end
    local ok, pos = pcall(function() return Mouse.GetPosition() end)
    if ok and pos ~= nil then return pos.x, pos.y end
    return nil
end

local function dataCompatible(a, b)
    return a == b or a == "any" or b == "any"
end

-- An InputField's raw text content / pre-parsed numeric quantity (honors suffixes like
-- 1K/1M), read defensively since a field can be mid-teardown when these are read. Shared by
-- commitField and commitAxisField's field-extraction step.
local function fieldContent(field)
    local raw = ""
    pcall(function() raw = field.content or "" end)
    local quantity
    pcall(function() quantity = field.contentQuantity end)
    return raw, quantity
end

-- Enum choice lookups, by value or by label. Kept as the ONE place both directions of the
-- ComboField <-> Control value mapping happen — see the id caveat on Editor:openControlEditor's
-- enum branch for why label, not id, is the only field ComboField lets us trust.
local function choiceByValue(spec, value)
    for _, c in ipairs(spec.choices or {}) do
        if c.value == value then return c end
    end
    return nil
end

local function choiceByLabel(spec, label)
    for _, c in ipairs(spec.choices or {}) do
        if c.label == label then return c end
    end
    return nil
end

local function clampv(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
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

-- Native StyleSheet lookups for the GroupBox/Buttons (mirrors DevTools/menu.lua's
-- safeButtonStyle/safePanelStyle) — guarded since a stylesheet id can be absent/renamed.
local function safeButtonStyle()
    if id ~= nil and id.StyleSheet ~= nil and id.StyleSheet.BUTTON_DEFAULT ~= nil then
        return id.StyleSheet.BUTTON_DEFAULT
    end
    return nil
end

local function safePanelStyle()
    if id ~= nil and id.StyleSheet ~= nil and id.StyleSheet.GROUPBOX_CONTENT_PANEL_TITLED ~= nil then
        -- return id.StyleSheet.GROUPBOX_MAIN_MODAL_TITLED
        return id.StyleSheet.GROUPBOX_CONTENT_PANEL_TITLED
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
            -- A Pin Control (ADR-0005) owns its own display projection; the Editor just asks it
            -- for each sub-rect's text and never branches on the control's kind. Every tag still
            -- on the old Control-Spec path falls through to the kind switch below (the bridge).
            if ctrl.pinControl ~= nil then
                ctrl.display = ctrl.pinControl.Display(ctrl)
            elseif ctrl.kind == "field" then
                local axisVal = (type(ctrl.value) == "table") and ctrl.value[ctrl.axis] or nil
                ctrl.display = (axisVal ~= nil) and tostring(axisVal) or ""
            elseif ctrl.kind == "action" then
                ctrl.display = "Set to current position"
            elseif ctrl.kind == "needle" then
                -- The matcher needle text field (#56): shows just the `needle` string; an empty
                -- needle falls back to the sub-rect's placeholder (drawn dimmed in node.lua).
                local m = (type(ctrl.value) == "table") and ctrl.value or nil
                ctrl.display = (m ~= nil and type(m.needle) == "string") and m.needle or ""
            elseif ctrl.kind == "toggle" then
                -- The matcher mode toggle (#56): a button labelled with the current mode, flipped
                -- on click. Defaults to Substring when the stored matcher has no explicit mode.
                local m = (type(ctrl.value) == "table") and ctrl.value or nil
                local mode = (m ~= nil and m.mode) or "substring"
                ctrl.display = (mode == "pattern") and "Pattern" or "Substring"
            elseif ctrl.kind == "mode" then
                -- An object_marker mode checkbox row (#40): a real checkbox glyph (drawn in
                -- node.lua from ctrl.checked) plus a left-aligned label. Disabled rows are
                -- dimmed and carry their "needs render API" reason (the unavailable-node idiom).
                local mode = modeDescriptor(ctrl.spec, ctrl.axis)
                local enabled = mode ~= nil and mode.enabled
                local label = (mode ~= nil and mode.label) or tostring(ctrl.axis)
                if mode ~= nil and not enabled and mode.reason then
                    label = label .. " — " .. mode.reason
                end
                ctrl.display = label
                ctrl.checked = enabled and type(ctrl.value) == "table" and ctrl.value[ctrl.axis] == true
                ctrl.disabled = not enabled
            else
                ctrl.display = Controls.Format(ctrl.spec, ctrl.value)
            end
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
    local mx, my = mousePos()
    if mx == nil then return end
    local lx, ly = self:toLocal(mx, my)
    self.mouse.x, self.mouse.y = lx, ly

    -- Any press that reaches the Capture Layer landed OUTSIDE the transient editor field
    -- (which captures its own clicks), so it's a click-away: commit and close the editor
    -- before doing anything else. A press that then lands on another Control reopens below.
    if self.editing ~= nil then self:closeControlEditor() end

    -- The Palette is modal: while it's open, a click either picks a Node Type or dismisses
    -- it — never a drag gesture, so this is handled before pressed/expandCapture. It hit-tests
    -- in SCREEN space (it draws on the full-screen paletteCanvas), so pass the raw mouse, not
    -- the toLocal'd coords.
    if self.palette.open then
        self:handlePaletteClick(mx, my)
        return
    end

    -- The color popup (#30) is modal too, but unlike the Palette some of its parts (the SV
    -- field, hue strip, R/G/B/A rows) DO drag — handleColorPopupClick sets up pressed/
    -- expandCapture itself for those, so it's not a plain return-only branch like above.
    if self.colorPopup.open then
        self:handleColorPopupClick(lx, ly)
        return
    end

    -- The toolbar +/x are real Buttons (children of the GroupBox, stacked in front of the
    -- Capture Layer) with their own ONBUTTONPRESSED handlers, so they never reach here.

    -- Pair this press with the previous one for double-click detection (recorded for every
    -- press; only acted on when the second click lands on empty space, below).
    local dbl = (self.tick - self.lastClickTick) <= Theme.DOUBLECLICK_TICKS
        and math.abs(lx - self.lastClickX) <= Theme.DOUBLECLICK_DIST
        and math.abs(ly - self.lastClickY) <= Theme.DOUBLECLICK_DIST
    self.lastClickTick, self.lastClickX, self.lastClickY = self.tick, lx, ly

    -- From here it's a real drag gesture. Grow the Capture Layer to full-screen for its
    -- duration, so the release (and continued tracking) still reaches us if the cursor
    -- leaves the Window. Restored to Window size in endPress.
    self.pressed = true
    self:expandCapture()

    -- Pressing the Window header drags the whole Window.
    if self:inHeader(lx, ly) then
        self.selected = nil
        self.mode = "dragwindow"
        -- Grab offset in true Window-frame space (matches the absolute mouse coords the
        -- dragwindow branch subtracts it from) — NOT the header-adjusted local coords.
        self.dragWinDX, self.dragWinDY = mx - self.window.x, my - self.window.y
        return
    end

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

    local hitPin = self:pinAt(lx, ly)
    if hitPin ~= nil then
        self:beginWire(hitPin)
        return
    end

    -- A Control box opens its inline editor. Not a drag, so unwind the gesture setup the way
    -- the close-button branch does (the box sits in the value column, clear of the pin glyph).
    -- A composite Control's "action" box (#25, e.g. coordgrid's "set to current position") is
    -- not an editable field — the dispatcher branches on `kind` and fires it immediately
    -- instead of opening the transient InputField.
    local hitCtrl = self:controlAt(lx, ly)
    if hitCtrl ~= nil then
        self.pressed = false
        self:positionCapture()
        self.selected = hitCtrl.nodeId
        self:bringToFront(hitCtrl.nodeId)
        -- A Pin Control (ADR-0005) owns its own click behavior: the Editor hands it a host and
        -- the clicked sub-rect and does no per-control branching. Every other control still
        -- falls through to the old `kind` switches below — the temporary bridge that keeps the
        -- editor working control-by-control during the migration sweep.
        if hitCtrl.ctrl.pinControl ~= nil then
            hitCtrl.ctrl.pinControl.Press(self:controlHost(hitCtrl.nodeId, hitCtrl.ctrl), hitCtrl.ctrl)
        elseif hitCtrl.ctrl.kind == "action" then
            self:setCoordgridToCurrentPosition(hitCtrl.nodeId, hitCtrl.ctrl.pinName)
        elseif hitCtrl.ctrl.kind == "swatch" then
            self:openColorPopup(hitCtrl.nodeId, hitCtrl.ctrl)
        elseif hitCtrl.ctrl.kind == "mode" then
            self:toggleMode(hitCtrl.nodeId, hitCtrl.ctrl)
        elseif hitCtrl.ctrl.kind == "toggle" then
            self:toggleMatcherMode(hitCtrl.nodeId, hitCtrl.ctrl)
        elseif hitCtrl.ctrl.kind == "capture" then
            -- The capture widget is shared: Screen Marker's rect uses the drag overlay, Object
            -- Marker's object uses the MiniMenu select mode (spec.captureKind == "object").
            if hitCtrl.ctrl.spec ~= nil and hitCtrl.ctrl.spec.captureKind == "object" then
                self:armObjectMarkerCapture(hitCtrl.nodeId, hitCtrl.ctrl.pinName)
            else
                self:armScreenMarkerCapture(hitCtrl.nodeId, hitCtrl.ctrl.pinName)
            end
        else
            self:openControlEditor(hitCtrl.nodeId, hitCtrl.ctrl)
        end
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
    local mx, my = mousePos()   -- absolute; converted to local per-branch below
    if mx == nil then return end

    if self.pressed then
        if self.mode == "pan" then
            local lx, ly = self:toLocal(mx, my)
            self.view:PanBy(lx - self.mouse.x, ly - self.mouse.y)
        elseif self.mode == "dragwindow" then
            -- Follow the cursor via the grab offset, clamped so the Window (and its header)
            -- stays fully on screen. No pan compensation needed: the Canvas is a child of
            -- the GroupBox we're moving, so its content rides along for free.
            local sw, sh = self:screenSize()
            local nx = clampv(mx - self.dragWinDX, 0, math.max(0, sw - self.window.w))
            local ny = clampv(my - self.dragWinDY, 0, math.max(0, sh - self.window.h))
            self.window.x, self.window.y = nx, ny
            self:positionCapture()
            self:positionGroupBox()
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

-- Opens the Palette listing every Node Type; the new Node lands where it was opened.
-- `lx, ly` are Canvas-local (the caller's frame); the Palette draws in SCREEN space on its
-- own full-screen Canvas, so the anchor is converted with toScreen, while the new-node
-- position stays graph-space (view:ToGraph of the local point). Expands the Capture Layer to
-- full-screen so rows drawn past the Window edge are still clickable (closePalette restores it).
function Editor:openPaletteUnfiltered(lx, ly)
    -- The toolbar + is a real Button (bypasses beginPress's colorPopup-modal check), so
    -- mutual exclusion with the color popup has to be enforced here too.
    self:closeColorPopup()
    local gx, gy = self.view:ToGraph(lx, ly)
    local scx, scy = self:toScreen(lx, ly)
    self.palette:Open(self.registry, nil,
        { screenX = scx, screenY = scy, anchorGX = gx, anchorGY = gy, connect = nil })
    self:expandCapture()
    self.mode = "idle"
    self.selected = nil
end

-- Opens the Palette filtered to Node Types with a Pin that could receive `source` (the
-- dragged Wire's Pin): matching kind, opposite direction, and (for Data) a compatible
-- Type Tag. The first such Pin per type is recorded as the auto-connect target.
function Editor:openPaletteFiltered(lx, ly, source)
    local gx, gy = self.view:ToGraph(lx, ly)
    local scx, scy = self:toScreen(lx, ly)
    local want = source.entry
    local wantDir = (want.direction == "out") and "in" or "out"
    local filter = function(def)
        for _, pinName in ipairs(def.pinOrder) do
            local p = def.pins[pinName]
            if p.kind == want.kind and p.direction == wantDir then
                if p.kind ~= "data" or dataCompatible(p.dataType, want.dataType) then
                    return pinName
                end
            end
        end
        return nil
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
-- auto-connects the source Pin to the recorded target Pin.
function Editor:placeFromPalette(row)
    local anchorGX, anchorGY = self.palette.anchorGX, self.palette.anchorGY
    local connect = self.palette.connect
    local targetPin = row.targetPin
    self:closePalette()

    local ok, newId = pcall(function() return self.graph:AddNode(row.typeKey) end)
    if not ok or newId == nil then
        if log ~= nil then log("Watchdog: AddNode failed — " .. tostring(newId)) end
        return
    end
    self.layout[newId] = { x = anchorGX, y = anchorGY }
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

--- Composite Control actions ------------------------------------------------------------

-- coordgrid's "set to current position" button (#25): overwrites the whole {x,z,level}
-- Control in one shot from the live player position. Silent no-op when unavailable. Only
-- IsAvailable() is guarded — a documented state check, not a client-global existence check
-- (see pcall-defensive-style: Player is guaranteed present at load).
function Editor:setCoordgridToCurrentPosition(nodeId, pinName)
    if not Player.IsAvailable() then return end
    local entity = Player.GetEntity()
    self:setControl(nodeId, pinName,
        { x = entity.coordGrid.x, z = entity.coordGrid.z, level = entity.coordGrid.level })
end

--- Screen Marker capture (#39) -----------------------------------------------------------

-- Arms the shared full-screen "Draw on screen" capture overlay (runtime.screenMarkerCapture,
-- see ui/screen_marker_capture.lua) for this node's `rect` pin. The overlay owns its own
-- click-capture layer and drag state machine (mounted/driven from main.lua, same as the
-- InfoBox Area's own drag-as-unit capture) — the Editor's only job is arming it and handing
-- it a commit callback that writes the finished rect through the normal setControl path,
-- same as every other Control edit. Silent no-op if no runtime was wired in (e.g. a
-- headless Editor in a future test).
function Editor:armScreenMarkerCapture(nodeId, pinName)
    if self.runtime == nil or self.runtime.screenMarkerCapture == nil then return end
    self.runtime.screenMarkerCapture:Arm(nodeId, pinName, function(rect)
        self:setControl(nodeId, pinName, rect)
    end)
end

--- Object Marker capture (#40) -----------------------------------------------------------

-- Arms the shared MiniMenu select mode (runtime.objectMarkerCapture, see
-- ui/object_marker_capture.lua) for this node's `object` pin. Unlike Screen Marker's drag
-- overlay, the capture subscribes Event.MiniMenuEntrySelected and commits on an Examine of a LOC,
-- writing the captured `{ name, coordGrid, subjectHash }` back through the normal setControl path.
-- Silent no-op if no runtime was wired in (e.g. a headless Editor in a future test).
function Editor:armObjectMarkerCapture(nodeId, pinName)
    if self.runtime == nil or self.runtime.objectMarkerCapture == nil then return end
    self.runtime.objectMarkerCapture:Arm(nodeId, pinName, function(object)
        self:setControl(nodeId, pinName, object)
    end)
end

--- Object Marker mode multi-select (#40) --------------------------------------------------

-- Toggles one enabled mode checkbox (only Tile is enabled today) in the composite `mode` table
-- Control, read-modify-write against the whole stored table. A disabled row ("needs render API")
-- is inert — clicking it does nothing.
function Editor:toggleMode(nodeId, ctrl)
    local mode = modeDescriptor(ctrl.spec, ctrl.axis)
    if mode == nil or not mode.enabled then return end
    -- Base the flip on the value the row actually shows (ctrl.value, already default-resolved
    -- in the geometry rebuild) rather than the raw stored Control — otherwise the first click on
    -- a checkbox that reads as ticked only because of the pin default would re-tick it (nil ->
    -- true) instead of clearing it.
    local updated = {}
    if type(ctrl.value) == "table" then
        for k, v in pairs(ctrl.value) do updated[k] = v end
    end
    updated[ctrl.axis] = not (updated[ctrl.axis] == true)
    self:setControl(nodeId, ctrl.pinName, updated)
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
-- one hex field through (via Controls.Format/Parse, which prefer a spec's own hooks) — so the popup
-- keeps working with no Control Spec. It falls back to ctrl.spec for the old bridge path (the
-- vestigial `kind == "swatch"` branch, live until #61 deletes it), which still carries a spec.
function Editor:openColorPopup(nodeId, ctrl, codec)
    if self.editing ~= nil then self:closeControlEditor() end
    local geom = self.geoms[nodeId]
    if geom == nil then return end
    local cp = self.colorPopup
    local sx, sy = self.view:ToScreen(geom.x + ctrl.x, geom.y + ctrl.y + ctrl.h)
    local current = self.graph:GetControl(nodeId, ctrl.pinName)
    if current == nil then current = ctrl.default end
    cp:Open(nodeId, ctrl.pinName, codec or ctrl.spec, current, sx, sy)
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
-- — the color spec's parse hook (Color.ParseHex8, via Controls.Parse below) already strips
-- non-hex characters on commit, so the field just needs to accept whatever's typed and let
-- the parse sort it out, same latitude a "text" widget gets in openControlEditor.
function Editor:openColorHexEditor()
    self:closeColorHexEditor()
    if self.groupBox == nil or ui == nil then return end
    local cp = self.colorPopup
    local r = cp.rect and cp.rect.hex
    if r == nil then return end

    -- The popup lives in the same fixed GroupBox-local frame the Canvas draws in (like the
    -- Palette), so its rect's coords are the field's coords directly — no View scaling, no
    -- header offset (mirrors openControlEditor's own no-offset finding).
    local field = self:mountInputField(r.x, r.y, r.w, r.h, "NONE", 8,
        Controls.Format(cp.spec, cp:Value()),
        function(_, cause, newContent) self:onColorHexContent(cause, newContent) end)
    if field == nil then return end
    self.colorHexField = field
    pcall(function() field:MoveToFront() end)
    pcall(function() field:SetFocus() end)
end

-- ONCONTENTCHANGED: live-parse every keystroke into the popup's working value through the
-- spec's own parse hook (Controls.Parse -> Color.ParseHex8's guard, so a too-short/
-- unparsable string is a no-op and a mid-typed hex never nukes the color); close just the
-- hex field (not the whole popup) on a submit/focus-loss cause.
function Editor:onColorHexContent(cause, _newContent)
    if self.colorHexField == nil then return end
    local raw = ""
    pcall(function() raw = self.colorHexField.content or "" end)
    local cp = self.colorPopup
    cp:SetValue(Controls.Parse(cp.spec, raw, cp:Value()))
    self:commitColorPopupValue()
    if isSubmitCause(cause) then self:closeColorHexEditor() end
end

function Editor:closeColorHexEditor()
    if self.colorHexField == nil then return end
    pcall(function() self.colorHexField:Destroy() end)
    self.colorHexField = nil
end

-- Esc dismisses the color popup (#30's third dismiss trigger, alongside outside-click and
-- re-click) and cancels an in-progress Screen Marker capture (#39) or Object Marker select
-- mode (#40). Wired from main.lua's existing KeyDown subscription.
function Editor:onEscape()
    if self.colorPopup.open then self:closeColorPopup() end
    if self.runtime ~= nil and self.runtime.screenMarkerCapture ~= nil then
        self.runtime.screenMarkerCapture:Cancel()
    end
    if self.runtime ~= nil and self.runtime.objectMarkerCapture ~= nil then
        self.runtime.objectMarkerCapture:Cancel()
    end
end

-- Screen rect for a transient editor field mounted over a Control box `ctrl`. The field's
-- native font is a fixed pixel size (it can't scale with the View), so the component is sized
-- in screen pixels: a fixed readable height, width tracking the box but never below the min,
-- centered vertically on the box row so a taller-than-box field straddles it evenly. A GroupBox
-- child positions in the SAME frame the Canvas draws in (both measured from the content-area
-- origin), so the box's draw coords are the field's coords directly — no header offset (verified
-- in-client: adding WINDOW_HEADER_H put the field a header-height too low). Shared by both mount
-- paths — the inline editor (openControlEditor) and the Pin Control host (mountControlField).
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
function Editor:mountControlField(pinControl, nodeId, ctrl, opts, onChange)
    if self.editing ~= nil then self:closeControlEditor() end
    if self.groupBox == nil or ui == nil then return end
    local geom = self.geoms[nodeId]
    if geom == nil then return end

    local px, py, sw, sh = self:controlEditRect(geom, ctrl)
    local field = self:mountInputField(px, py, sw, sh, opts.filter or "NONE", opts.maxLen or 128,
        opts.initial or "",
        function(_, cause, _newContent) self:onControlContent(cause, _newContent) end)
    if field == nil then return end

    self.editing = { nodeId = nodeId, pinName = ctrl.pinName, field = field,
        kind = ctrl.kind, axis = ctrl.axis, pinControl = pinControl, onChange = onChange }
    pcall(function() field:MoveToFront() end)
    pcall(function() field:SetFocus() end)
end

-- Mounts the host's transient DROPDOWN for a Pin Control edit (the enum path). Mirrors the enum
-- branch of openControlEditor — a real ui.ComboField styled so it isn't invisible, entries Add'd by
-- label, the current label pre-selected, and ONSELECTIONCHANGED wired to commit — but routes the
-- pick back through the Pin Control's own `onSelect(label)` instead of the old spec/choice path.
-- Like an enum's inline editor it commits ONLY on an actual selection change: the editing session
-- records no `onChange`, so a plain close (commitField's Pin Control branch) is a no-op — merely
-- mounting then unmounting the dropdown can't rewrite the value (the bool-flip bug ADR-0004 fixed).
function Editor:mountControlDropdown(pinControl, nodeId, ctrl, opts, onSelect)
    if self.editing ~= nil then self:closeControlEditor() end
    if self.groupBox == nil or ui == nil then return end
    local geom = self.geoms[nodeId]
    if geom == nil then return end

    local px, py, sw, sh = self:controlEditRect(geom, ctrl)
    local field
    local ok = pcall(function()
        field = ui.ComboField.new(self.groupBox)
        pcall(function() field.stylesheetID = safeComboStyle() end)
        field.clickthrough = false
        field:SetPos(px, py)
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
        kind = ctrl.kind, axis = ctrl.axis, pinControl = pinControl, onSelect = onSelect }
    pcall(function() field:MoveToFront() end)
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

-- Mounts a transient real ui.InputField as a child of the GroupBox (ADR-0004's mechanism):
-- styled so it isn't invisible (no stylesheet -> no background sprite, the gotcha ADR-0004
-- documents), positioned/sized in the caller's coords, filtered, seeded with initial content,
-- and wired to `onChanged` (an ONCONTENTCHANGED callback of `fn(component, cause, newContent)`).
-- Shared by the node's own inline Control editor (openControlEditor, below) and the color
-- popup's hex field (openColorHexEditor, #30) — the two differ only in where the field goes
-- and what its filter/initial content/commit path are. Returns the field, or nil if mounting
-- failed (caller decides what "no field" means for it — both bail out entirely).
function Editor:mountInputField(px, py, sw, sh, filterMode, maxLen, initialContent, onChanged)
    local field
    local ok = pcall(function()
        field = ui.InputField.new(self.groupBox)
        pcall(function() field.stylesheetID = safeButtonStyle() end)
        field.clickthrough = false
        field:SetPos(px, py)
        field:SetSize(sw, sh)
        field:Setup(enumv(ui.TextContentVisibilityMode, "VISIBLE"),
            enumv(ui.InputFieldFilterMode, filterMode), maxLen)
        field.content = initialContent
        field:Subscribe(enumv(ui.Hook, "ONCONTENTCHANGED"), onChanged)
    end)
    if not ok then return nil end
    return field
end

-- Mounts the transient editor component over a Control box. One at a time; any previous
-- editor is committed and torn down first. The component is a child of the GroupBox, so it
-- rides the Window; its position adds WINDOW_HEADER_H because the Canvas content origin sits
-- that far below the GroupBox top (see toLocal / the coordinate-model note). It's re-fronted
-- each frame in draw() since canvas:MoveToFront() would otherwise bury it.
-- `ctrl` is the clicked Control box from this frame's geometry cache (as returned by
-- controlAt) — for a composite Control (#25) it's one of several sharing `ctrl.pinName`,
-- distinguished by `ctrl.kind`/`ctrl.axis` (nil for a scalar Control's single box).
function Editor:openControlEditor(nodeId, ctrl)
    if self.editing ~= nil then self:closeControlEditor() end
    if self.groupBox == nil or ui == nil then return end

    local geom = self.geoms[nodeId]
    if geom == nil then return end
    local pinName, kind, axis = ctrl.pinName, ctrl.kind, ctrl.axis

    local px, py, sw, sh = self:controlEditRect(geom, ctrl)

    local spec = ctrl.spec
    -- Prefill from the stored Control, falling back to the pin's default so an unseeded pin
    -- opens showing its default rather than an empty box (which would then commit 0/"").
    -- A "field" box (#25) prefills from just its own axis of the whole composite table.
    local current
    if kind == "field" then
        local whole = self.graph:GetControl(nodeId, pinName)
        if whole == nil then whole = ctrl.default end
        current = (type(whole) == "table") and whole[axis] or nil
    elseif kind == "needle" then
        -- The matcher's text field edits just the `needle` string of the whole {needle, mode}
        -- table (committed back read-modify-write in commitNeedleField, so the mode survives).
        local whole = self.graph:GetControl(nodeId, pinName)
        if whole == nil then whole = ctrl.default end
        current = (type(whole) == "table") and whole.needle or nil
    else
        current = self.graph:GetControl(nodeId, pinName)
        if current == nil then current = ctrl.default end
    end
    local field

    if spec.widget == "enum" then
        local ok = pcall(function()
            field = ui.ComboField.new(self.groupBox)
            -- Without a stylesheet the field has no background sprite and renders invisibly
            -- (mirrors MenuInterface's addInput, which styles its InputField the same way).
            pcall(function() field.stylesheetID = safeComboStyle() end)
            field.clickthrough = false
            field:SetPos(px, py)
            field:SetSize(sw, sh)
            -- DISCOVERED IN-CLIENT (contradicts the docs' implication that Add's id param is
            -- caller-controlled): the id passed to Add is checked only for uniqueness (a
            -- collision is rejected/no-op'd) — it does NOT control storage order or the id the
            -- entry ends up with. ComboField always sorts its entries alphabetically by label
            -- and reassigns them sequential IDs 1..N in THAT sorted order: Add("Z", 0) then
            -- Add("A", 99) ends up A=1, Z=2, not 99/0. The `i` passed below only guarantees no
            -- collision. Since id is unreliable, the Editor never trusts one: selection is
            -- read and written entirely by LABEL TEXT (choiceByValue/choiceByLabel above,
            -- selectedChoice below), which is the one thing ComboField reports accurately.
            for i, choice in ipairs(spec.choices or {}) do
                field:Add(choice.label, i)
            end
            local currentChoice = choiceByValue(spec, current)
            local sel = 1
            if currentChoice ~= nil then
                for i, e in ipairs(field.entries) do
                    if e.text == currentChoice.label then
                        sel = i
                        break
                    end
                end
            end
            field:Select(sel, false)
            field:Subscribe(enumv(ui.Hook, "ONSELECTIONCHANGED"), function()
                self:onControlSelect()
            end)
        end)
        if not ok or field == nil then return end
    else
        -- A composite "field" box (#25, e.g. coordgrid's x/z/level) is a numeric field
        -- exactly like the "number" widget; it just commits into one axis, not the whole
        -- Control (see commitField's axis branch).
        local filter = (spec.widget == "number" or kind == "field") and "NUMERIC" or "NONE"
        field = self:mountInputField(px, py, sw, sh, filter, 128,
            (current ~= nil) and tostring(current) or "",
            function(_, cause, newContent) self:onControlContent(cause, newContent) end)
        if field == nil then return end
    end

    self.editing = { nodeId = nodeId, pinName = pinName, spec = spec,
        widget = spec.widget, field = field, kind = kind, axis = axis, default = ctrl.default }
    pcall(function() field:MoveToFront() end)
    -- No focus API is exposed (no SetFocus/RequestFocus on Component or InputField in the
    -- docs), so the user clicks the freshly-mounted field once to focus it. Kept as a
    -- best-effort in case a future client adds one; harmless (pcall'd) when absent.
    pcall(function() field:SetFocus() end)
end

-- The choice a ComboField currently shows, read from `selectedLabel` — NOT `selectedID`,
-- which is just the widget's alphabetical sort rank and carries no information about which
-- choice it was (see the Add note in openControlEditor). Returns the choice table or nil.
function Editor:selectedChoice(e)
    local label
    pcall(function() label = e.field.selectedLabel end)
    if label == nil then return nil end
    return choiceByLabel(e.spec, label)
end

function Editor:commitField()
    local e = self.editing
    if e == nil then return end
    -- A Pin Control-mounted field (ADR-0005) commits through the Pin Control's OWN callback,
    -- handed to it when the host mounted the field. Both the live-write (onControlContent) and
    -- the close path (closeControlEditor) funnel here, so this one bridge covers both; the
    -- Pin Control's callback does the read-modify-write and decides whether to commit at all.
    if e.pinControl ~= nil then
        if e.onChange ~= nil then
            local raw, quantity = fieldContent(e.field)
            e.onChange(raw, quantity)
        end
        return
    end
    -- Enums commit ONLY from the ONSELECTIONCHANGED event (onControlSelect), never on a plain
    -- close. Committing an enum on close read the dropdown's `selectedID` unconditionally, so
    -- merely mounting then unmounting the field wrote whatever it happened to show — opening a
    -- `false` bool would flip it to `true`. Re-picking the already-selected value needs no
    -- commit (the value is already that), so there is no close case an enum must cover here.
    if e.widget == "enum" then return end
    -- The matcher needle (#56) commits into just the `needle` key of the whole {needle, mode}
    -- table (read-modify-write), so flipping the toggle and typing don't clobber each other.
    -- Unlike a numeric axis field, an empty needle is a MEANINGFUL value (matches everything),
    -- so it has its own commit rather than the empty-box-guarded coordgrid path below.
    if e.kind == "needle" then
        self:commitNeedleField()
        return
    end
    -- A composite Control's "field" box (#25) commits into just its own axis, read-modify-
    -- write against the whole stored table — see Controls.CommitAxis.
    if e.axis ~= nil then
        self:commitAxisField()
        return
    end
    local raw, quantity = fieldContent(e.field)
    -- An empty box means "leave the Control alone" — but ONLY for numeric widgets, where
    -- opening then closing a field without typing must not overwrite the stored value (or a
    -- nil default) with 0 (a numeric field reports contentQuantity == 0 for empty content,
    -- which is what nuked soundID). For a TEXT widget an empty/whitespace box is a MEANINGFUL
    -- value — it's how the user clears the field (e.g. InfoBox `title`) — so it must commit
    -- verbatim rather than snap back to the previous text. (Same principle as commitNeedleField.)
    if e.widget ~= "text" and type(raw) == "string" and raw:match("^%s*$") then return end

    -- Prefer the field's own parsed integer (honors quantity suffixes like 1K/1M).
    local value = (e.widget == "number") and quantity or nil
    if value == nil then
        value = Controls.Parse(e.spec, raw, self.graph:GetControl(e.nodeId, e.pinName))
    end
    self:setControl(e.nodeId, e.pinName, value)
end

-- Commits a composite Control's single axis (#25) via Controls.CommitAxis's pure
-- read-modify-write + empty-box guard, then writes the (possibly unchanged) table back.
function Editor:commitAxisField()
    local e = self.editing
    local raw, quantity = fieldContent(e.field)
    local current = self.graph:GetControl(e.nodeId, e.pinName)
    local value, changed = Controls.CommitAxis(current, e.axis, raw, quantity)
    if changed then
        self:setControl(e.nodeId, e.pinName, value)
    end
end

-- Read-modify-write helper for the matcher's {needle, mode} table Control (#56): starts from the
-- stored value (or the pin default when unseeded), copies it, and returns the copy so a caller
-- can mutate one key without dropping the other. Always yields a table with both keys present.
local function matcherRMW(stored, default)
    local updated = { needle = "", mode = "substring" }
    local base = (type(stored) == "table") and stored or ((type(default) == "table") and default or nil)
    if base ~= nil then
        if type(base.needle) == "string" then updated.needle = base.needle end
        if base.mode == "pattern" or base.mode == "substring" then updated.mode = base.mode end
    end
    return updated
end

-- Commits the matcher needle (#56): writes the field's text into the `needle` key, preserving the
-- stored `mode`. Empty text is committed verbatim (an empty needle is a valid "match everything"
-- filter), unlike the coordgrid axis path which guards empty as "leave alone".
function Editor:commitNeedleField()
    local e = self.editing
    if e == nil then return end
    local raw = fieldContent(e.field)
    if type(raw) ~= "string" then raw = "" end
    local updated = matcherRMW(self.graph:GetControl(e.nodeId, e.pinName), e.default)
    updated.needle = raw
    self:setControl(e.nodeId, e.pinName, updated)
end

-- Flips the matcher's Substring <-> Pattern mode (#56), read-modify-write against the whole
-- {needle, mode} table so the needle text survives the toggle. Bases the flip on ctrl.value
-- (already default-resolved in the geometry rebuild) so the first flip off a default-only
-- matcher toggles from the shown mode rather than re-deriving nil.
function Editor:toggleMatcherMode(nodeId, ctrl)
    local updated = matcherRMW(ctrl.value, ctrl.default)
    updated.mode = (updated.mode == "pattern") and "substring" or "pattern"
    self:setControl(nodeId, ctrl.pinName, updated)
end

-- ONCONTENTCHANGED: live-write every keystroke; close on a submit/focus-loss cause.
function Editor:onControlContent(cause, _newContent)
    if self.editing == nil then return end
    self:commitField()
    if isSubmitCause(cause) then self:closeControlEditor() end
end

-- ONSELECTIONCHANGED: a dropdown pick is a complete edit. This event fires only on an actual
-- selection change, so it's the ONLY place an enum commits — writing the just-picked value
-- (read from the authoritative selectedID), then tearing the field down. A plain close
-- commits nothing (commitField no-ops enums), so opening/closing without a pick can't mutate.
function Editor:onControlSelect()
    local e = self.editing
    if e == nil then return end
    local choice = self:selectedChoice(e)
    if choice ~= nil then
        self:setControl(e.nodeId, e.pinName, choice.value)
    end
    self:closeControlEditor()
end

-- Commits (for text/number) and destroys the transient editor.
function Editor:closeControlEditor()
    local e = self.editing
    if e == nil then return end
    self:commitField()
    self.editing = nil
    if e.field ~= nil then pcall(function() e.field:Destroy() end) end
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

-- The Window border, drawn on top of content. The header band, title, and toolbar Buttons
-- are the real GroupBox this Canvas is a child of (see Mount) — its header shows through
-- here because the Canvas never paints above viewportRect's top edge.
function Editor:drawChrome()
    local vx, vy, vw, vh = self:viewportRect()
    self.canvas:AddOutline(vx, vy, vw, vh, Theme.BORDER_THICKNESS,
        Theme.Vec4(Theme.COL_WINDOW_BORDER))
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
    pcall(function() self.canvas:MoveToFront() end)
    -- The grid background now paints all the way up to y=0 (viewportRect), which would
    -- otherwise get buried under the +/x Buttons since they're siblings under the same
    -- GroupBox and the canvas just claimed front-most. Re-front the Buttons every frame so
    -- they stay visually above the grid.
    if self.plusButton ~= nil then pcall(function() self.plusButton:MoveToFront() end) end
    if self.closeButton ~= nil then pcall(function() self.closeButton:MoveToFront() end) end
    -- Keep the transient Control editor above the just-fronted Canvas.
    if self.editing ~= nil and self.editing.field ~= nil then
        pcall(function() self.editing.field:MoveToFront() end)
    end
    if self.colorHexField ~= nil then
        pcall(function() self.colorHexField:MoveToFront() end)
    end
    self.canvas:Clear()

    self:buildGeoms()
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
    self:drawChrome()

    -- The color popup draws last on the content Canvas, on top of the chrome, clamped inside
    -- the Viewport. (It and the Palette are mutually exclusive — see openColorPopup /
    -- openPaletteUnfiltered — so they never contend for the surface.)
    if self.colorPopup.open then
        self.colorPopup:Draw(self.canvas, vx, vy, vw, vh, self.mouse.x, self.mouse.y,
            { hexEditing = self.colorHexField ~= nil })
    end

    -- The Palette draws on its OWN full-screen Canvas in screen space, so it can extend past
    -- the Window edges (the content Canvas above clips to the Window). Cleared every frame;
    -- fronted and redrawn only while open, clamped to the whole screen rather than the Viewport.
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

-- Full-screen interface size, read from the client's root component (fallback if
-- unavailable). Can't read this off the Canvas any more since it's Window-sized now,
-- not full-screen, now that it's mounted as a child of the GroupBox.
function Editor:screenSize()
    local w, h = 1920, 1080
    if self.rootParent ~= nil then
        pcall(function()
            if self.rootParent.width and self.rootParent.width > 0 then w = self.rootParent.width end
            if self.rootParent.height and self.rootParent.height > 0 then h = self.rootParent.height end
        end)
    end
    return w, h
end

function Editor:positionCapture()
    if self.capture == nil then return end
    local win = self.window
    pcall(function()
        self.capture:SetPos(win.x, win.y)
        self.capture:SetSize(win.w, win.h)
    end)
end

-- Keeps the GroupBox (the real header/frame) tracking the Window rect, same as the
-- Capture Layer. The toolbar Buttons are its children and ride along for free.
function Editor:positionGroupBox()
    if self.groupBox == nil then return end
    local win = self.window
    pcall(function()
        self.groupBox:SetPos(win.x, win.y)
        self.groupBox:SetSize(win.w, win.h)
    end)
end

-- Grow the Capture Layer to cover the whole screen (used during a drag so the release
-- reaches us wherever the cursor ends up).
function Editor:expandCapture()
    if self.capture == nil then return end
    pcall(function()
        self.capture:SetPos(0, 0)
        self.capture:SetSize(0, 0, 1.0, 1.0)
    end)
end

-- Re-asserts the editor's front-most z-order after another always-on overlay (the InfoBox
-- Area's drag capture) temporarily jumped its capture in front of ours mid-drag. Fronts the
-- Capture Layer first, then the GroupBox on top of it — the same relative order Mount
-- establishes (GroupBox + toolbar Buttons out-rank Capture, Capture out-ranks everything
-- else). No-op while hidden: a closed editor's capture is disabled and shouldn't out-rank the
-- InfoBox. Called from main.lua the tick an InfoBox drag ends.
function Editor:RaiseToFront()
    if not self.visible then return end
    pcall(function() if self.capture ~= nil then self.capture:MoveToFront() end end)
    pcall(function() if self.groupBox ~= nil then self.groupBox:MoveToFront() end end)
end

-- Clamps the Window fully on screen so the header can never be dragged out of reach.
function Editor:clampWindow()
    local sw, sh = self:screenSize()
    self.window.x = clampv(self.window.x, 0, math.max(0, sw - self.window.w))
    self.window.y = clampv(self.window.y, 0, math.max(0, sh - self.window.h))
end

-- The default framing (pan + zoom) applied on a fresh Mount and each time the Window is
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
    -- Re-center the graph every time the Window opens, so a stray pan can never lose the nodes.
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
    if self.paletteCanvas ~= nil then
        pcall(function() self.paletteCanvas.hidden = not self.visible end)
    end
    if self.capture ~= nil then
        pcall(function()
            self.capture.hidden = not self.visible
            self.capture.enabled = self.visible  -- stop intercepting game input while hidden
        end)
        -- On show, ensure the Capture Layer is back to Window size (also recovers it if a
        -- prior drag left it expanded), so the toggle doubles as a reset.
        if self.visible then self:positionCapture() end
    end
    if self.groupBox ~= nil then
        -- Hiding the GroupBox also hides its child Buttons, so they don't need this too.
        pcall(function() self.groupBox.hidden = not self.visible end)
    end
end

function Editor:Toggle()
    self:SetVisible(not self.visible)
end

--- Mount / unmount -----------------------------------------------------------------------

function Editor:Mount(parent)
    self.rootParent = parent  -- kept for screenSize(), now that Canvas isn't full-screen

    -- The GroupBox must exist before the Canvas, since the Canvas mounts as its child.
    self:mountGroupBox(parent)
    if self.groupBox == nil then
        if log ~= nil then log("Watchdog: ui.GroupBox unavailable, aborting Mount") end
        return
    end

    self.canvas = ui.Canvas.new(self.groupBox)
    self.canvas:SetPos(0, 0)
    -- Height excludes the reserved header strip: the Canvas starts at the content-area origin
    -- (WINDOW_HEADER_H below the frame top), so sizing it the full win.h overshoots the box
    -- bottom by that much and the GroupBox clips it. Size it to the true content area so the
    -- Canvas's own bounds match what's visible (see viewportRect).
    self.canvas:SetSize(self.window.w, self.window.h - Theme.WINDOW_HEADER_H)
    self.canvas.clickthrough = true

    -- Invisible Capture Layer sized to the Window. Kept as a separate, absolutely-
    -- positioned sibling (not nested under the GroupBox) because it must be able to grow
    -- to cover the true full screen during a drag (see expandCapture) — a nested child
    -- can only size itself relative to its own parent, never past it.
    self.capture = ui.Button.new(parent)
    self.capture.alpha = 0
    self.capture.clickthrough = false

    -- The Palette's own drawing surface: a full-screen Canvas mounted on the root parent (NOT
    -- the GroupBox), so it isn't clipped to the Window and its rows can extend past the Window
    -- edges. Screen-space coords (SetPos 0,0 + full-screen SetSize), inert/clickthrough like
    -- the content Canvas — clicks fall through to the Capture Layer, which is expanded to
    -- full-screen while the Palette is open (see openPalette*/closePalette) so out-of-window
    -- rows are still hit-testable. Re-fronted each frame it's open (draw); Cleared otherwise.
    self.paletteCanvas = ui.Canvas.new(parent)
    self.paletteCanvas:SetPos(0, 0)
    self.paletteCanvas:SetSize(0, 0, 1.0, 1.0)
    self.paletteCanvas.clickthrough = true

    -- Keep the Window on screen (in case defaults exceed this display), then size the
    -- capture and re-sync the GroupBox's position (mountGroupBox positioned it once
    -- before clampWindow had a chance to adjust self.window.x/y).
    self:clampWindow()
    self:positionCapture()
    self:positionGroupBox()

    -- Start a gesture ONLY on ONCLICK (a mouse-DOWN this layer actually captured). ONHOLD is
    -- intentionally left unsubscribed: it also fires when a press that began elsewhere is
    -- dragged over us, and that foreign press's ONRELEASE never comes back to us — so binding
    -- it to beginPress strands the drag stuck-to-cursor. Movement is polled in update().
    self.capture:Subscribe(ui.Hook.ONCLICK, function() self:beginPress() end)
    self.capture:Subscribe(ui.Hook.ONRELEASE, function() self:endPress() end)
    self.capture:Subscribe(ui.Hook.ONSCROLLWHEEL, function(...) self:onScroll(...) end)

    -- The Capture Layer is a sibling created AFTER the GroupBox, so it lands in front of the
    -- GroupBox and its child toolbar Buttons — swallowing their clicks (dead +/x). Re-front
    -- the GroupBox now that Capture exists so its Buttons out-rank it. Content-area clicks
    -- still reach Capture because the GroupBox and Canvas are both clickthrough, so a miss on
    -- a Button falls straight through to the Capture behind.
    pcall(function() self.groupBox:MoveToFront() end)

    -- Frame content at the default origin on first mount (SetVisible re-applies this on every
    -- subsequent open, so a stray pan/zoom can never lose the nodes).
    self:resetView()

    self:SetVisible(self.visible)
end

-- The real GroupBox supplying the native header/title/frame, plus the toolbar Buttons
-- (top-right of the box, not inside the header itself). Created before the Canvas (which
-- mounts as its child, see Mount) and moved to front so its Buttons out-rank the Capture
-- Layer's full-window hit area — Capture itself stays reachable everywhere else because
-- the GroupBox is clickthrough, so a miss just falls through to it.
function Editor:mountGroupBox(parent)
    if ui.GroupBox == nil then return end  -- degrade to border-only chrome if unavailable
    local win = self.window

    local ok = pcall(function() self.groupBox = ui.GroupBox.new(parent) end)
    if not ok or self.groupBox == nil then return end

    pcall(function() self.groupBox.stylesheetID = safePanelStyle() end)
    self.groupBox.clickthrough = true
    self:positionGroupBox()

    -- headerWidth is a Uint8 (0..255) in the docs even though the Window itself is wider —
    -- clamp rather than pass the raw Window width and risk it wrapping/clamping oddly.
    local ok2, err2 = pcall(function()
        self.groupBox:SetHeaderLayout(math.min(win.w, 255), Theme.WINDOW_HEADER_H,
            0, 0, ui.GroupBoxHeaderAlignMode.LEFT)
    end)
    if not ok2 and log ~= nil then log("Watchdog: SetHeaderLayout failed — " .. tostring(err2)) end

    local ok3, err3 = pcall(function() self.groupBox.headerText.content = Theme.WINDOW_TITLE end)
    if not ok3 and log ~= nil then log("Watchdog: headerText failed — " .. tostring(err3)) end

    -- The content area (below the header) is left to the Canvas's own draw calls, which
    -- render on top of it as a child — this just guards against any default sprite fill
    -- showing through at the edges the Canvas doesn't paint.
    -- pcall(function() self.groupBox.contentBackgroundSprite.alpha = 0 end)
    self.groupBox.headerText.font = id.Font.MUSEO_SANS_15PT_REGULAR
    -- self.groupBox.headerBackgroundSprite.sprite = 35539
    -- self.groupBox.contentBackgroundSprite.sprite = 32376
    -- local popupSprite = ui.Sprite.new(popupLayer, 160, 2)
    -- popupSprite:SetPos(2, 2)
    -- popupSprite:SetSize(-4, -4, 1.0, 1.0)
    -- popupSprite.sprite = Plugin.resources.runescape_guy
    -- self.groupBox.headerBackgroundSprite.sprite = Plugin.resources.images.ToolbarCategoryLogistics


    -- Zero the content margin so child components (the +/x toolbar Buttons) aren't inset by
    -- the GroupBox's default padding. NOTE: this does NOT move the child Canvas's draw origin
    -- — the Canvas still starts below the reserved header strip (SetHeaderLayout height). That
    -- header inset is compensated for in `toLocal`, which is what actually keeps hit-tests
    -- lined up with what the Canvas paints.
    pcall(function() self.groupBox.contentMargin = ui.Margin.new() end)
    self.groupBox:MoveToFront()

    local bs = Theme.WINDOW_HEADER_H - 10
    local function toolbarButton(label, offsetFromRight, onPress)
        local button = nil
        local ok4 = pcall(function() button = ui.Button.new(self.groupBox) end)
        if not ok4 or button == nil then return nil end

        pcall(function() button.stylesheetID = safeButtonStyle() end)
        button:SetPos(win.w - offsetFromRight, 5)  -- local: relative to the GroupBox
        button:SetSize(bs, bs)
        button.clickthrough = false
        button.text.content = label
        button:Subscribe(ui.Hook.ONBUTTONPRESSED, function() onPress() return true end)
        pcall(function() button:MoveToFront() end)
        return button
    end

    self.closeButton = toolbarButton("X", bs + 6, function() self:SetVisible(false) end)
    self.plusButton = toolbarButton("+", 2 * bs + 12, function()
        -- Local coordinates (the GroupBox's own frame) — matches the button's own position.
        self:openPaletteUnfiltered(win.w - 2 * bs - 12, 5 + bs)
    end)
    self.plusButton.cursorConfig.mouseOverCursor = id.Cursor.CURSOR_GOTO
end

function Editor:Unmount()
    self:closeControlEditor()  -- tear down any transient editor before its parent goes away
    self:closeColorPopup()
    if self.paletteCanvas ~= nil then
        -- A sibling of the GroupBox (mounted on the root parent), so groupBox:Destroy() below
        -- won't take it — tear it down explicitly.
        pcall(function() self.paletteCanvas:Destroy() end)
        self.paletteCanvas = nil
    end
    if self.capture ~= nil then
        pcall(function() self.capture:Destroy() end)
        self.capture = nil
    end
    if self.groupBox ~= nil then
        pcall(function() self.groupBox:Destroy() end)  -- takes the Canvas + Buttons with it
        self.groupBox = nil
        self.canvas = nil
        self.plusButton = nil
        self.closeButton = nil
    end
end

return Editor
