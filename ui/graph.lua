-- graph.lua — the Editor: the pannable/zoomable Viewport onto a live LibNodeGraph Graph.
--
-- Owns the View (pan/zoom), the Layout (nodeId -> Graph-space position), the input state
-- machine, and all hit-testing. Draws everything each frame onto one full-screen Canvas
-- (immediate mode, ADR-0001). Mutates the Graph through the engine's own Connect/Disconnect
-- so the picture and the model can't drift. UI presentation only — no graph structure is
-- invented here.
--
-- The editor lives in a draggable Window (a logical screen-space rect). The Canvas stays
-- full-screen — its coordinate space and clipping behavior are undocumented, so rather than
-- rely on canvas clipping we simply bound every draw to the Window rect and cull nodes fully
-- outside it. Input is caught by a Capture Layer sized to the Window, so the game still
-- receives clicks outside it. Dragging the Window header moves the rect (and pans content
-- with it); a keybind (wired in main) toggles visibility.

local Theme = require("ui/theme")
local View  = require("ui/view")
local Node  = require("ui/node")
local Wire  = require("ui/wire")

local Editor = {}
Editor.__index = Editor

-- graph, registry: the live LibNodeGraph objects. layout: optional { [id] = {x,y} }.
function Editor.new(graph, registry, layout)
    return setmetatable({
        graph = graph,
        registry = registry,
        view = View.new(),
        layout = layout or {},     -- nodeId -> {x, y} in Graph-space
        nodeOrder = {},            -- draw/z order, front-most last
        geoms = {},                -- per-frame geometry cache, nodeId -> geom
        mouse = { x = 0, y = 0 },
        pressed = false,
        mode = "idle",             -- idle | pan | dragnode | wire | dragwindow
        selected = nil,
        visible = true,
        window = {                 -- screen-space rect the editor occupies
            x = Theme.WINDOW_X, y = Theme.WINDOW_Y,
            w = Theme.WINDOW_W, h = Theme.WINDOW_H,
        },
        canvas = nil,
        capture = nil,
    }, Editor)
end

-- The content region (Window minus its header): x, y, w, h in screen space.
function Editor:viewportRect()
    local win = self.window
    return win.x, win.y + Theme.WINDOW_HEADER_H, win.w, win.h - Theme.WINDOW_HEADER_H
end

-- Whether a screen point is inside the Window's header strip.
function Editor:inHeader(sx, sy)
    local win = self.window
    return sx >= win.x and sx <= win.x + win.w
        and sy >= win.y and sy <= win.y + Theme.WINDOW_HEADER_H
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

local function clampv(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
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
    local present = {}
    for _, n in ipairs(self.graph:GetNodes()) do
        present[n.id] = n.typeKey
        local pos = self:posOf(n.id)
        local pins = self.graph:GetPins(n.id) or {}
        self.geoms[n.id] = Node.BuildGeometry(pins, pos.x, pos.y, Theme.NODE_WIDTH)
        self.geoms[n.id].typeKey = n.typeKey
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

function Editor:connectionInto(nodeId, pinName)
    for _, c in ipairs(self.graph:GetConnections()) do
        if c.toNode == nodeId and c.toPin == pinName then return c end
    end
    return nil
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
    self.pressed = true
    self.mouse.x, self.mouse.y = mx, my

    -- Grow the Capture Layer to full-screen for the duration of this gesture, so the
    -- release (and continued tracking) still reaches us if the cursor leaves the Window.
    -- Restored to Window size in endPress.
    self:expandCapture()

    -- Pressing the Window header drags the whole Window.
    if self:inHeader(mx, my) then
        self.selected = nil
        self.mode = "dragwindow"
        self.dragWinDX = mx - self.window.x  -- grab offset (absolute, avoids drift on clamp)
        self.dragWinDY = my - self.window.y
        return
    end

    local hitPin = self:pinAt(mx, my)
    if hitPin ~= nil then
        self:beginWire(hitPin)
        return
    end

    local hitNode = self:nodeAt(mx, my)
    if hitNode ~= nil then
        self.selected = hitNode
        self:bringToFront(hitNode)
        local pos = self:posOf(hitNode)
        local gx, gy = self.view:ToGraph(mx, my)
        self.mode = "dragnode"
        self.dragNodeId = hitNode
        self.dragDX, self.dragDY = gx - pos.x, gy - pos.y
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
    local mx, my = mousePos()
    if mx == nil then return end

    if self.pressed then
        local dx, dy = mx - self.mouse.x, my - self.mouse.y
        if self.mode == "pan" then
            self.view:PanBy(dx, dy)
        elseif self.mode == "dragwindow" then
            -- Follow the cursor via the grab offset, clamped so the Window (and its header)
            -- stays fully on screen; pan content by the Window's ACTUAL move so it rides along.
            local sw, sh = self:screenSize()
            local nx = clampv(mx - self.dragWinDX, 0, math.max(0, sw - self.window.w))
            local ny = clampv(my - self.dragWinDY, 0, math.max(0, sh - self.window.h))
            local adx, ady = nx - self.window.x, ny - self.window.y
            self.window.x, self.window.y = nx, ny
            self.view:PanBy(adx, ady)
            self:positionCapture()
        elseif self.mode == "dragnode" and self.dragNodeId ~= nil then
            local gx, gy = self.view:ToGraph(mx, my)
            local pos = self:posOf(self.dragNodeId)
            pos.x, pos.y = gx - self.dragDX, gy - self.dragDY
        end
        -- "wire" needs no state here; the loose end follows self.mouse in Draw.
    end

    self.mouse.x, self.mouse.y = mx, my
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

-- Resolves the pending Wire against whatever pin is under the cursor and connects if
-- legal. A miss (or illegal drop) simply discards — and if the gesture began by grabbing
-- a Connection off an input, that Connection stays removed (drop-on-empty = delete).
function Editor:commitWire()
    local mx, my = self.mouse.x, self.mouse.y
    local target = self:pinAt(mx, my)
    if target == nil then return end

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

    -- Data inputs take a single Connection (engine hard-asserts on a second): replace.
    if inEnd.entry.kind == "data" then
        local existing = self:connectionInto(inEnd.nodeId, inEnd.entry.name)
        if existing ~= nil then self.graph:Disconnect(existing.id) end
    end

    -- Connect can still reject (a cycle); guard so a bad drop never crashes the frame.
    local ok, err = pcall(function()
        self.graph:Connect(outEnd.nodeId, outEnd.entry.name, inEnd.nodeId, inEnd.entry.name)
    end)
    if not ok and log ~= nil then
        log("Watchdog: connect rejected — " .. tostring(err))
    end
end

function Editor:onScroll(...)
    local delta
    for _, v in ipairs({ ... }) do
        if type(v) == "number" then delta = v break end
    end
    if delta == nil or delta == 0 then return end
    local mx, my = mousePos()
    if mx == nil then mx, my = self.mouse.x, self.mouse.y end
    local factor = delta > 0 and (1 / 1.1) or 1.1
    self.view:ZoomAt(mx, my, factor, Theme.ZOOM_MIN, Theme.ZOOM_MAX)
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

-- The Window chrome, drawn on top of content: header band, border, title.
function Editor:drawChrome()
    local win = self.window
    self.canvas:AddRectangle(win.x, win.y, win.w, Theme.WINDOW_HEADER_H,
        Theme.Vec4(Theme.COL_WINDOW_HEADER))
    self.canvas:AddOutline(win.x, win.y, win.w, win.h, Theme.BORDER_THICKNESS,
        Theme.Vec4(Theme.COL_WINDOW_BORDER))
    local font = Theme.Font(14)  -- chrome text is screen-fixed, independent of graph zoom
    if font ~= nil then
        self.canvas:AddText(win.x + 10, win.y + 6, Theme.WINDOW_TITLE, font,
            Theme.Vec4(Theme.COL_WINDOW_TITLE))
    end
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
    self.canvas:Clear()

    self:buildGeoms()
    local vx, vy, vw, vh = self:viewportRect()

    self:drawBackground()
    self:drawConnections()

    for _, id in ipairs(self.nodeOrder) do
        local geom = self.geoms[id]
        if geom ~= nil and self:geomVisible(geom, vx, vy, vw, vh) then
            Node.Draw(self.canvas, self.view, geom, self:meta(id, geom.typeKey),
                { selected = (id == self.selected) })
        end
    end

    self:drawPendingWire()
    self:drawChrome()
end

--- Visibility ----------------------------------------------------------------------------

-- Full-screen interface size, read from the full-screen Canvas (fallback if unavailable).
function Editor:screenSize()
    local w, h = 1920, 1080
    if self.canvas ~= nil then
        pcall(function()
            if self.canvas.width and self.canvas.width > 0 then w = self.canvas.width end
            if self.canvas.height and self.canvas.height > 0 then h = self.canvas.height end
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
        -- Abandon any in-progress gesture so we don't resume mid-drag when reshown.
        self.pressed = false
        self.mode = "idle"
        self.wire = nil
        self.dragNodeId = nil
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
end

function Editor:Toggle()
    self:SetVisible(not self.visible)
end

--- Mount / unmount -----------------------------------------------------------------------

function Editor:Mount(parent)
    self.canvas = ui.Canvas.new(parent)
    self.canvas:SetPos(0, 0)
    self.canvas:SetSize(0, 0, 1.0, 1.0)   -- full-screen; every draw is bounded to the Window
    self.canvas.clickthrough = true

    -- Invisible Capture Layer sized to the Window, so the game still receives pointer events
    -- outside it. Catches the events the inert Canvas cannot.
    self.capture = ui.Button.new(parent)
    self.capture.alpha = 0
    self.capture.clickthrough = false

    -- Keep the Window on screen (in case defaults exceed this display), then size the capture.
    self:clampWindow()
    self:positionCapture()

    -- Start a gesture ONLY on ONCLICK (a mouse-DOWN this layer actually captured). ONHOLD is
    -- intentionally left unsubscribed: it also fires when a press that began elsewhere is
    -- dragged over us, and that foreign press's ONRELEASE never comes back to us — so binding
    -- it to beginPress strands the drag stuck-to-cursor. Movement is polled in update().
    self.capture:Subscribe(ui.Hook.ONCLICK, function() self:beginPress() end)
    self.capture:Subscribe(ui.Hook.ONRELEASE, function() self:endPress() end)
    self.capture:Subscribe(ui.Hook.ONSCROLLWHEEL, function(...) self:onScroll(...) end)

    -- Position content inside the Window on first mount.
    self.view.panX = self.window.x + 30
    self.view.panY = self.window.y + Theme.WINDOW_HEADER_H + 30

    self:SetVisible(self.visible)
end

function Editor:Unmount()
    if self.capture ~= nil then
        pcall(function() self.capture:Destroy() end)
        self.capture = nil
    end
    if self.canvas ~= nil then
        pcall(function() self.canvas:Destroy() end)
        self.canvas = nil
    end
end

return Editor
