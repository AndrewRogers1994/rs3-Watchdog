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
local Wire     = require("ui/wire")
local Palette  = require("ui/palette")
local Controls = require("ui/controls")

local Editor = {}
Editor.__index = Editor

-- graph, registry: the live LibNodeGraph objects. layout: optional { [id] = {x,y} }.
-- view: optional restored { panX, panY, zoom }; when given, Mount skips its default framing.
function Editor.new(graph, registry, layout, view)
    local self = setmetatable({
        graph = graph,
        registry = registry,
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
        tick = 0,                  -- Logic-tick counter, for double-click timing
        lastClickTick = -1000,     -- tick of the previous press (double-click pairing)
        lastClickX = 0,
        lastClickY = 0,
        window = {                 -- screen-space rect the editor occupies
            x = Theme.WINDOW_X, y = Theme.WINDOW_Y,
            w = Theme.WINDOW_W, h = Theme.WINDOW_H,
        },
        canvas = nil,
        capture = nil,
        rootParent = nil,          -- the client's root component, kept for screenSize()
        groupBox = nil,            -- real GroupBox providing the native header/title/frame
        plusButton = nil,          -- real Button, top-right of the GroupBox
        closeButton = nil,         -- real Button, top-right of the GroupBox
    }, Editor)

    -- A restored View overrides the default framing Mount would otherwise apply.
    if view ~= nil then
        self.view.panX = view.panX or self.view.panX
        self.view.panY = view.panY or self.view.panY
        self.view.zoom = view.zoom or self.view.zoom
        self._viewProvided = true
    end

    return self
end

-- Current View as a plain, persistable table (see store.lua). Read live, so it reflects
-- whatever the user last panned/zoomed to.
function Editor:GetView()
    return { panX = self.view.panX, panY = self.view.panY, zoom = self.view.zoom }
end

-- The live Layout map (nodeId -> {x,y}); mutated in place as nodes are dragged/created.
function Editor:GetLayout()
    return self.layout
end

-- Whether the editor Window is currently open. Editing only happens while it's shown, so
-- the host uses this to persist only during an editing session (see main.lua's autosave).
function Editor:IsVisible()
    return self.visible
end

-- The content region: x, y, w, h, in GroupBox-local space. Covers the WHOLE box, including
-- the strip behind the toolbar Buttons — the native header (title text) actually floats
-- above the box's own top edge (straddling local y=0, per the _TITLED stylesheet's overlap
-- convention), so nothing here paints over it; drawBackground's grid just fills what used to
-- be an uncovered gap behind the +/x row instead of leaving the contentBackgroundSprite show
-- through it.
function Editor:viewportRect()
    local win = self.window
    return 0, 0, win.w, win.h
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

function Editor:meta(nodeId, typeKey)
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

    local present = {}
    for _, n in ipairs(self.graph:GetNodes()) do
        present[n.id] = n.typeKey
        local pos = self:posOf(n.id)
        local pins = self.graph:GetPins(n.id) or {}
        local geom = Node.BuildGeometry(pins, pos.x, pos.y, Theme.NODE_WIDTH,
            { connected = connectedIn[n.id] or {} })
        geom.typeKey = n.typeKey
        -- Fill each Control box's current value + display string (Node stays graph-only).
        for _, ctrl in ipairs(geom.controls) do
            ctrl.value = self.graph:GetControl(n.id, ctrl.pinName)
            -- A nil stored Control (e.g. a graph saved before this pin had a default) shows
            -- the pin's default, so the box reflects the value the node would actually run with.
            if ctrl.value == nil then ctrl.value = ctrl.default end
            ctrl.display = Controls.Format(ctrl.spec, ctrl.value)
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

-- Topmost pin under a screen point: { nodeId, entry } or nil. Front-most node wins.
function Editor:pinAt(sx, sy)
    for i = #self.nodeOrder, 1, -1 do
        local id = self.nodeOrder[i]
        local geom = self.geoms[id]
        if geom ~= nil then
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
    -- it — never a drag gesture, so this is handled before pressed/expandCapture.
    if self.palette.open then
        self:handlePaletteClick(lx, ly)
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
    local hitCtrl = self:controlAt(lx, ly)
    if hitCtrl ~= nil then
        self.pressed = false
        self:positionCapture()
        self.selected = hitCtrl.nodeId
        self:bringToFront(hitCtrl.nodeId)
        self:openControlEditor(hitCtrl.nodeId, hitCtrl.ctrl.pinName)
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
        if conn ~= nil then
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
    self:positionCapture()  -- shrink the Capture Layer back to the Window
end

-- Commits one output->input link, honoring the engine rules the UI enforces: a Data input
-- takes a single Connection (the engine hard-asserts on a second) so the existing one is
-- replaced first, and Connect itself is guarded because it can still reject a cycle — a bad
-- link must never crash the frame. Shared by Wire drops and Palette auto-connect.
function Editor:linkPins(outNode, outPin, inNode, inPin, isData)
    if isData then
        local existing = self:connectionInto(inNode, inPin)
        if existing ~= nil then self.graph:Disconnect(existing.id) end
    end
    local ok, err = pcall(function()
        self.graph:Connect(outNode, outPin, inNode, inPin)
    end)
    if not ok and log ~= nil then
        log("Watchdog: connect rejected — " .. tostring(err))
    end
    return ok
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
function Editor:openPaletteUnfiltered(sx, sy)
    local gx, gy = self.view:ToGraph(sx, sy)
    self.palette:Open(self.registry, nil,
        { screenX = sx, screenY = sy, anchorGX = gx, anchorGY = gy, connect = nil })
    self.mode = "idle"
    self.selected = nil
end

-- Opens the Palette filtered to Node Types with a Pin that could receive `source` (the
-- dragged Wire's Pin): matching kind, opposite direction, and (for Data) a compatible
-- Type Tag. The first such Pin per type is recorded as the auto-connect target.
function Editor:openPaletteFiltered(sx, sy, source)
    local gx, gy = self.view:ToGraph(sx, sy)
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
        screenX = sx, screenY = sy, anchorGX = gx, anchorGY = gy,
        connect = { nodeId = source.nodeId, entry = source.entry },
    })
end

-- Routes a click while the Palette is open: pick an item, or dismiss on an outside click.
function Editor:handlePaletteClick(mx, my)
    local row = self.palette:RowAt(mx, my)
    if row ~= nil then
        self:placeFromPalette(row)
    elseif not self.palette:Contains(mx, my) then
        self.palette:Close()
    end
    -- A click on a header row or inner padding is ignored, keeping the Palette open.
end

-- Creates the chosen Node Type at the Palette's anchor and, in drag-to-create mode,
-- auto-connects the source Pin to the recorded target Pin.
function Editor:placeFromPalette(row)
    local anchorGX, anchorGY = self.palette.anchorGX, self.palette.anchorGY
    local connect = self.palette.connect
    local targetPin = row.targetPin
    self.palette:Close()

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
    -- commit and close it first.
    if self.editing ~= nil then self:closeControlEditor() end
    local mx, my = mousePos()
    local lx, ly
    if mx ~= nil then lx, ly = self:toLocal(mx, my) else lx, ly = self.mouse.x, self.mouse.y end
    local factor = delta > 0 and (1 / 1.1) or 1.1
    self.view:ZoomAt(lx, ly, factor, Theme.ZOOM_MIN, Theme.ZOOM_MAX)
end

--- Inline Control editing ---------------------------------------------------------------

-- The current Control box geometry for (nodeId, pinName) from this frame's cache, or nil.
function Editor:findControl(nodeId, pinName)
    local geom = self.geoms[nodeId]
    if geom == nil then return nil end
    for _, ctrl in ipairs(geom.controls) do
        if ctrl.pinName == pinName then return geom, ctrl end
    end
    return nil
end

-- Mounts the transient editor component over a Control box. One at a time; any previous
-- editor is committed and torn down first. The component is a child of the GroupBox, so it
-- rides the Window; its position adds WINDOW_HEADER_H because the Canvas content origin sits
-- that far below the GroupBox top (see toLocal / the coordinate-model note). It's re-fronted
-- each frame in draw() since canvas:MoveToFront() would otherwise bury it.
function Editor:openControlEditor(nodeId, pinName)
    if self.editing ~= nil then self:closeControlEditor() end
    if self.groupBox == nil or ui == nil then return end

    local geom, ctrl = self:findControl(nodeId, pinName)
    if ctrl == nil then return end

    local sx, sy = self.view:ToScreen(geom.x + ctrl.x, geom.y + ctrl.y)
    -- The field's native font is a fixed pixel size (it can't scale with the View), so the
    -- component is sized in screen pixels: a fixed readable height, width tracking the box
    -- but never below the min. Centered vertically on the box row so a taller-than-box field
    -- straddles the row evenly instead of hanging below it.
    local boxH = self.view:Scale(ctrl.h)
    local sw = math.max(self.view:Scale(ctrl.w), Theme.CONTROL_EDIT_MIN_W)
    local sh = Theme.CONTROL_EDIT_H
    -- A GroupBox child positions in the SAME frame the Canvas draws in (both measured from
    -- the content-area origin), so the Control box's draw coords are the field's coords
    -- directly — no header offset. (Verified in-client: adding WINDOW_HEADER_H put the field
    -- a header-height too low.)
    local px, py = sx, sy + (boxH - sh) * 0.5

    local spec = ctrl.spec
    -- Prefill from the stored Control, falling back to the pin's default so an unseeded pin
    -- opens showing its default rather than an empty box (which would then commit 0/"").
    local current = self.graph:GetControl(nodeId, pinName)
    if current == nil then current = ctrl.default end
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
        local ok = pcall(function()
            field = ui.InputField.new(self.groupBox)
            -- Without a stylesheet the field has no background sprite and renders invisibly
            -- (MenuInterface's working addInput styles its InputField with BUTTON_DEFAULT).
            pcall(function() field.stylesheetID = safeButtonStyle() end)
            field.clickthrough = false
            field:SetPos(px, py)
            field:SetSize(sw, sh)
            local filter = (spec.widget == "number") and "NUMERIC" or "NONE"
            field:Setup(enumv(ui.TextContentVisibilityMode, "VISIBLE"),
                enumv(ui.InputFieldFilterMode, filter), 128)
            field.content = (current ~= nil) and tostring(current) or ""
            field:Subscribe(enumv(ui.Hook, "ONCONTENTCHANGED"), function(_, cause, newContent)
                self:onControlContent(cause, newContent)
            end)
        end)
        if not ok or field == nil then return end
    end

    self.editing = { nodeId = nodeId, pinName = pinName, spec = spec,
        widget = spec.widget, field = field }
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
    -- Enums commit ONLY from the ONSELECTIONCHANGED event (onControlSelect), never on a plain
    -- close. Committing an enum on close read the dropdown's `selectedID` unconditionally, so
    -- merely mounting then unmounting the field wrote whatever it happened to show — opening a
    -- `false` bool would flip it to `true`. Re-picking the already-selected value needs no
    -- commit (the value is already that), so there is no close case an enum must cover here.
    if e.widget == "enum" then return end
    local raw = ""
    pcall(function() raw = e.field.content or "" end)
    -- An empty box means "leave the Control alone" — opening then closing a field without
    -- typing must not overwrite the stored value (or a nil default) with 0/"". A numeric
    -- field reports contentQuantity == 0 for empty content, which is what nuked soundID.
    if type(raw) == "string" and raw:match("^%s*$") then return end

    local value
    if e.widget == "number" then
        -- Prefer the field's own parsed integer (honors quantity suffixes like 1K/1M).
        local ok, q = pcall(function() return e.field.contentQuantity end)
        if ok and q ~= nil then value = q end
    end
    if value == nil then
        value = Controls.Parse(e.spec, raw, self.graph:GetControl(e.nodeId, e.pinName))
    end
    pcall(function() self.graph:SetControl(e.nodeId, e.pinName, value) end)
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
        pcall(function() self.graph:SetControl(e.nodeId, e.pinName, choice.value) end)
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
    local win = self.window
    self.canvas:AddOutline(0, 0, win.w, win.h, Theme.BORDER_THICKNESS,
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
    self.canvas:Clear()

    self:buildGeoms()
    local vx, vy, vw, vh = self:viewportRect()

    self:drawBackground()
    self:drawConnections()

    for _, id in ipairs(self.nodeOrder) do
        local geom = self.geoms[id]
        if geom ~= nil and self:geomVisible(geom, vx, vy, vw, vh) then
            local editingPin = (self.editing ~= nil and self.editing.nodeId == id)
                and self.editing.pinName or nil
            Node.Draw(self.canvas, self.view, geom, self:meta(id, geom.typeKey),
                { selected = (id == self.selected),
                  mouseX = self.mouse.x, mouseY = self.mouse.y,
                  editingPin = editingPin })
        end
    end

    self:drawPendingWire()
    self:drawChrome()

    -- The Palette draws last, on top of the chrome, clamped inside the Viewport.
    if self.palette.open then
        self.palette:Draw(self.canvas, vx, vy, vw, vh, self.mouse.x, self.mouse.y)
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

-- Clamps the Window fully on screen so the header can never be dragged out of reach.
function Editor:clampWindow()
    local sw, sh = self:screenSize()
    self.window.x = clampv(self.window.x, 0, math.max(0, sw - self.window.w))
    self.window.y = clampv(self.window.y, 0, math.max(0, sh - self.window.h))
end

function Editor:SetVisible(v)
    self.visible = v and true or false
    if not self.visible then
        -- Abandon any in-progress gesture (and dismiss the Palette / close the inline editor)
        -- so nothing resumes mid-interaction when reshown.
        self.pressed = false
        self.mode = "idle"
        self.wire = nil
        self.dragNodeId = nil
        self.palette:Close()
        self:closeControlEditor()
    end
    if self.canvas ~= nil then
        pcall(function() self.canvas.hidden = not self.visible end)
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
    self.canvas:SetSize(self.window.w, self.window.h)  -- local: fills the whole GroupBox
    self.canvas.clickthrough = true

    -- Invisible Capture Layer sized to the Window. Kept as a separate, absolutely-
    -- positioned sibling (not nested under the GroupBox) because it must be able to grow
    -- to cover the true full screen during a drag (see expandCapture) — a nested child
    -- can only size itself relative to its own parent, never past it.
    self.capture = ui.Button.new(parent)
    self.capture.alpha = 0
    self.capture.clickthrough = false

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

    -- Position content inside the Window on first mount (local space now) — unless a
    -- persisted View was restored (see Editor.new), in which case honor the saved pan/zoom.
    if not self._viewProvided then
        self.view.panX = 30
        self.view.panY = Theme.WINDOW_HEADER_H + 30
    end

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
