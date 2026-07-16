-- infobox.lua — the shared InfoBox Area (#41): a RuneLite-style wrapping strip of fixed
-- square icon+text tiles drawn on the always-on effect overlay Canvas (effects.lua's own
-- Canvas, separate from the editor Window). Each `action.infobox` node owns exactly one tile;
-- this module owns the shared area they all draw into.
--
-- Deliberately its own registry-level layout component, NOT a free EffectRegistry handle:
-- unlike a Screen Flash or Popup (self-contained { update, draw }), the tiles need per-box
-- screen bounds so the area can wrap them, drag the whole strip as a unit, and hover-test a
-- tile for its tooltip — none of which the uniform effect handle exposes.
--
-- Model: an ordered set of boxes keyed by an opaque `owner` (the node id). Set() inserts a new
-- owner at the end or rewrites an existing one *in place* (its slot in the flow never moves on
-- re-update); Remove() drops it and everything after reflows up one slot. Layout is pure — a
-- horizontal flow from the anchor that wraps to a new row once a row would pass wrapWidth — so
-- insertion order + reflow-on-dismiss fall straight out of the order list. The anchor (the
-- strip's top-left, default top-left of the screen) is draggable as a unit and persisted
-- through an injected hook (SetPersistence), mirroring runtime.lua's Store seam.
--
-- Everything except Draw is pure table math (no client globals), unit-tested directly. Draw
-- resolves colors to Vector4 and calls ui.Canvas AddRectangle/AddSprite/AddText, guarded so a
-- missing font/sprite can't break the always-on draw loop; it's exercised in-client only.

local Theme = require("ui/theme")

local InfoBox = {}
InfoBox.__index = InfoBox

function InfoBox.new()
    return setmetatable({
        order = {},       -- ordered list of owner keys (insertion order; compacts on Remove)
        boxes = {},       -- owner -> { text, color, icon, title }
        anchor = { x = Theme.INFOBOX_DEFAULT_X, y = Theme.INFOBOX_DEFAULT_Y },
        wrapWidth = Theme.INFOBOX_WRAP_WIDTH,
        _drag = nil,          -- { dx, dy } grab offset while dragging the strip
        _persistence = nil,   -- { SaveAnchor = fn(x, y) }, injected
    }, InfoBox)
end

--- Node-facing pure helpers ----------------------------------------------------------------

-- The tile's display string: `tostring` of any value, nil -> "" (the issue's "shown via
-- tostring; no built-in formatting"). Static so the node can shape text before Set().
function InfoBox.ResolveText(value)
    if value == nil then return "" end
    return tostring(value)
end

-- Whether an `update` value counts as "empty" for the node's dismissWhenEmpty config: nil, the
-- number 0, or the empty string (matching the issue exactly). The string "0" is a real value.
function InfoBox.IsEmpty(value)
    return value == nil or value == 0 or value == ""
end

--- Ordered box set -------------------------------------------------------------------------

-- Inserts `owner`'s tile, or rewrites it in place if it already exists (its flow slot is
-- preserved — a re-update never reorders). `fields` is { text, color, icon, title }, each
-- optional; text defaults to "".
function InfoBox:Set(owner, fields)
    fields = fields or {}
    if self.boxes[owner] == nil then
        self.order[#self.order + 1] = owner
    end
    self.boxes[owner] = {
        text = fields.text or "",
        color = fields.color,
        icon = fields.icon,
        title = fields.title,
    }
end

function InfoBox:Has(owner)
    return self.boxes[owner] ~= nil
end

function InfoBox:Get(owner)
    return self.boxes[owner]
end

function InfoBox:Count()
    return #self.order
end

-- The owner keys in insertion order (a fresh copy — callers can't mutate the internal list).
function InfoBox:Order()
    local out = {}
    for i, owner in ipairs(self.order) do out[i] = owner end
    return out
end

-- Removes `owner`'s tile; everything after it slides up one slot (reflow-on-dismiss). Returns
-- true if a tile was removed, false if `owner` had none.
function InfoBox:Remove(owner)
    if self.boxes[owner] == nil then return false end
    self.boxes[owner] = nil
    for i, o in ipairs(self.order) do
        if o == owner then
            table.remove(self.order, i)
            break
        end
    end
    return true
end

function InfoBox:Clear()
    self.order = {}
    self.boxes = {}
end

--- Anchor / persistence --------------------------------------------------------------------

function InfoBox:GetAnchor()
    return self.anchor.x, self.anchor.y
end

function InfoBox:SetAnchor(x, y)
    self.anchor = { x = x, y = y }
end

function InfoBox:SetWrapWidth(w)
    self.wrapWidth = w
end

-- Injects the anchor-persistence hook ({ SaveAnchor = fn(x, y) }); EndDrag writes the moved
-- anchor through it so the strip's position survives a reload (main.lua wires it to the Store).
function InfoBox:SetPersistence(persistence)
    self._persistence = persistence
end

--- Layout: horizontal flow + wrap ----------------------------------------------------------

-- Fixed columns per row derived from the wrap width, so wrapping is a simple (index -> row/col)
-- map. At least one column always, however narrow the wrap width.
function InfoBox:_columns()
    local step = Theme.INFOBOX_BOX_SIZE + Theme.INFOBOX_GAP
    local cols = math.floor((self.wrapWidth + Theme.INFOBOX_GAP) / step)
    if cols < 1 then cols = 1 end
    return cols
end

-- Screen rects for every tile in flow order: { owner, box, x, y, w, h }. Pure — nothing here
-- reads or mutates draw/hover state, so BoxAt/Bounds/Draw all just call it.
function InfoBox:Layout()
    local size = Theme.INFOBOX_BOX_SIZE
    local step = size + Theme.INFOBOX_GAP
    local cols = self:_columns()
    local rects = {}
    for i, owner in ipairs(self.order) do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        rects[i] = {
            owner = owner,
            box = self.boxes[owner],
            x = self.anchor.x + col * step,
            y = self.anchor.y + row * step,
            w = size,
            h = size,
        }
    end
    return rects
end

-- The bounding rect of every tile ({x, y, w, h}), or nil when the area is empty. Used both to
-- gate a drag grab (only inside the strip) and, in-client, to know what the pointer overlays.
function InfoBox:Bounds()
    local rects = self:Layout()
    if #rects == 0 then return nil end
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    for _, r in ipairs(rects) do
        if r.x < minX then minX = r.x end
        if r.y < minY then minY = r.y end
        if r.x + r.w > maxX then maxX = r.x + r.w end
        if r.y + r.h > maxY then maxY = r.y + r.h end
    end
    return { x = minX, y = minY, w = maxX - minX, h = maxY - minY }
end

--- Hit-testing -----------------------------------------------------------------------------

local function inRect(r, px, py)
    return px >= r.x and px <= r.x + r.w and py >= r.y and py <= r.y + r.h
end

-- The owner of the tile under (px, py), or nil. Iterates in flow order; tiles never overlap so
-- the first hit is unambiguous.
function InfoBox:BoxAt(px, py)
    for _, r in ipairs(self:Layout()) do
        if inRect(r, px, py) then return r.owner end
    end
    return nil
end

-- The tooltip string to show at (px, py): the hovered tile's `title`, or nil when there's no
-- tile there or its title is unset/empty (an empty title means "no tooltip").
function InfoBox:TooltipAt(px, py)
    local owner = self:BoxAt(px, py)
    if owner == nil then return nil end
    local title = self.boxes[owner].title
    if title == nil or title == "" then return nil end
    return title
end

--- Drag-as-unit ----------------------------------------------------------------------------

-- Grabs the strip for a drag if (px, py) is within its bounds, recording the grab offset so
-- the anchor tracks the cursor without snapping. Returns true if grabbed.
function InfoBox:BeginDrag(px, py)
    local b = self:Bounds()
    if b == nil or not inRect(b, px, py) then return false end
    self._drag = { dx = px - self.anchor.x, dy = py - self.anchor.y }
    return true
end

-- Moves the anchor (and thus every tile) so the grab point stays under the cursor. No-op unless
-- a BeginDrag grabbed the strip.
function InfoBox:Drag(px, py)
    if self._drag == nil then return end
    self.anchor = { x = px - self._drag.dx, y = py - self._drag.dy }
end

-- Ends a drag and persists the resting anchor through the injected hook. No-op if not dragging.
function InfoBox:EndDrag()
    if self._drag == nil then return end
    self._drag = nil
    if self._persistence ~= nil and self._persistence.SaveAnchor ~= nil then
        pcall(self._persistence.SaveAnchor, self.anchor.x, self.anchor.y)
    end
end

function InfoBox:IsDragging()
    return self._drag ~= nil
end

--- Click-capture mount (client-only; untested under the standalone Lua harness) -----------
-- The overlay Canvas effects.lua mounts is `clickthrough = true` (Canvas drawables are inert,
-- CONTEXT.md's Capture Layer note), so dragging the strip needs its own small clickable
-- component — same alpha-0 ui.Button + ONCLICK/ONRELEASE idiom ui/graph.lua's own Capture
-- Layer uses (`mousePos()` there), sized to the strip's current Bounds rather than the whole
-- screen since this capture must never swallow clicks meant for the game or the editor.

local function mousePos()
    if Mouse == nil or Mouse.GetPosition == nil then return nil end
    local ok, pos = pcall(function() return Mouse.GetPosition() end)
    if ok and pos ~= nil then return pos.x, pos.y end
    return nil
end

-- Mounts the click-capture layer as a direct child of `rootParent` (the same root the effect
-- overlay Canvas mounts under). Idempotent: a second Mount before Unmount is a no-op.
function InfoBox:Mount(rootParent)
    if self._capture ~= nil then
        return
    end
    local area = self
    local ok, capture = pcall(function()
        local c = ui.Button.new(rootParent)
        c.alpha = 0
        c.clickthrough = false
        c:Subscribe(ui.Hook.ONCLICK, function()
            local mx, my = mousePos()
            if mx ~= nil then area:BeginDrag(mx, my) end
        end)
        c:Subscribe(ui.Hook.ONRELEASE, function() area:EndDrag() end)
        return c
    end)
    if ok then
        self._capture = capture
        self:Reposition()
    elseif log ~= nil then
        log("Watchdog infobox: Mount failed — " .. tostring(capture))
    end
end

function InfoBox:IsMounted()
    return self._capture ~= nil
end

function InfoBox:Unmount()
    if self._capture ~= nil then
        pcall(function() self._capture:Destroy() end)
        self._capture = nil
    end
end

-- Resizes/repositions the capture layer to the strip's current on-screen Bounds — called once
-- per Logic tick (main.lua, alongside runtime:Update) since Bounds shift as tiles are added or
-- removed. An empty area (no live tiles) shrinks the capture to nothing so it can't sit over
-- the game or editor with nothing to actually drag.
function InfoBox:Reposition()
    if self._capture == nil then
        return
    end
    local b = self:Bounds()
    pcall(function()
        if b == nil then
            self._capture:SetSize(0, 0)
        else
            self._capture:SetPos(b.x, b.y)
            self._capture:SetSize(b.w, b.h)
        end
    end)
end

--- Draw (client-only; untested under the bare Lua harness) ---------------------------------

-- Resolves a box's {r,g,b,a} (0..255) color to a Vector4, defaulting to white (an unset/nil
-- `color` data-in) so a box always draws with legible text.
local function textVec4(color)
    if color == nil then
        local c = Theme.COL_INFOBOX_TEXT
        return Vector4.new(c[1], c[2], c[3], c[4])
    end
    local a = (color.a == nil) and 255 or color.a
    return Vector4.new((color.r or 0) / 255, (color.g or 0) / 255, (color.b or 0) / 255, a / 255)
end

-- Draws every tile onto `canvas` (the overlay Canvas), plus the tooltip for the tile under
-- (hoverX, hoverY) when given. Each primitive is guarded so a missing font/sprite degrades
-- gracefully rather than breaking the always-on draw loop.
function InfoBox:Draw(canvas, hoverX, hoverY)
    if canvas == nil then return end
    local font = Theme.Font(Theme.INFOBOX_TEXT_PT)
    for _, r in ipairs(self:Layout()) do
        local box = r.box
        pcall(function() canvas:AddRectangle(r.x, r.y, r.w, r.h, Theme.Vec4(Theme.COL_INFOBOX_BG)) end)
        pcall(function()
            local bc = Theme.COL_INFOBOX_BORDER
            local t = Theme.BORDER_THICKNESS
            local bv = Vector4.new(bc[1], bc[2], bc[3], bc[4])
            canvas:AddRectangle(r.x, r.y, r.w, t, bv)
            canvas:AddRectangle(r.x, r.y + r.h - t, r.w, t, bv)
            canvas:AddRectangle(r.x, r.y, t, r.h, bv)
            canvas:AddRectangle(r.x + r.w - t, r.y, t, r.h, bv)
        end)
        if box.icon ~= nil then
            -- AddSprite(x, y, w, h, spriteID, colourRGBA) — stretch the icon to fill the tile
            -- (see docs/research/popup-frame-sprites.md; no built-in 9-slice). Untinted white.
            pcall(function() canvas:AddSprite(r.x, r.y, r.w, r.h, box.icon, 0xFFFFFFFF) end)
        end
        if font ~= nil and box.text ~= nil and box.text ~= "" then
            -- Bottom-left of the tile so the icon (top) and text (bottom) stack like RuneLite.
            pcall(function()
                canvas:AddText(r.x + 2, r.y + r.h - Theme.INFOBOX_TEXT_PT - 2, box.text, font, textVec4(box.color))
            end)
        end
    end
    if hoverX ~= nil and hoverY ~= nil then
        self:_drawTooltip(canvas, hoverX, hoverY)
    end
end

function InfoBox:_drawTooltip(canvas, hoverX, hoverY)
    local title = self:TooltipAt(hoverX, hoverY)
    if title == nil then return end
    local font = Theme.Font(Theme.INFOBOX_TOOLTIP_PT)
    if font == nil then return end
    local pad = Theme.INFOBOX_TOOLTIP_PAD
    local w = (Theme.TextWidth(Theme.INFOBOX_TOOLTIP_PT, title) or (#title * 7)) + pad * 2
    local h = Theme.INFOBOX_TOOLTIP_PT + pad * 2
    local x, y = hoverX + 12, hoverY + 12
    pcall(function() canvas:AddRectangle(x, y, w, h, Theme.Vec4(Theme.COL_INFOBOX_TIP_BG)) end)
    pcall(function() canvas:AddText(x + pad, y + pad, title, font, Theme.Vec4(Theme.COL_INFOBOX_TIP_TX)) end)
end

return InfoBox
