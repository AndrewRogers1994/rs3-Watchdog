-- overlay.lua — OverlayStack: the shared, registry-level substrate every `action.overlay`
-- node (#36) draws its toasts onto. Rides on top of effects.lua's EffectRegistry (its
-- Stack policy already gives cap+evict-oldest+onDone for free) via ONE shared owner key
-- (`Overlay.OWNER`) so every Overlay node in every graph competes for the same 10 slots,
-- oldest evicted first — "One shared registry-level stack for all Overlay nodes" (#36 AC).
--
-- On top of that shared Stack, this module keeps its own bookkeeping the EffectRegistry has
-- no concept of:
--   - `live`: the ordered list of currently-visible toasts (mirrors the shared Stack's
--     order), used to lay out the vertical stack under the anchor at draw time.
--   - `byOwner`: nodeKey -> { handle, ... }, so a node re-firing `show` STACKS a new toast
--     alongside its earlier ones (rather than replacing), and `dismiss` can clear every
--     live toast that belongs to that one node without touching another node's.
--   - `anchor`: one shared, draggable {dx, dy} pixel offset from the default top-center
--     point, persisted via the injected `persistence` hook (`{ Load()->pos|nil, Save(pos) }`,
--     mirrors store.lua's own PersistentDB seam) so the position survives a reload.
--
-- TTL/sticky lifecycle rides the same uniform `update(dt) -> alive` contract as every other
-- effect (#29's EffectRegistry): a non-sticky toast counts its own `remaining` down and goes
-- not-alive at zero (default 5s, RuneLite parity); a sticky one always returns true and is
-- only ever removed by an explicit Dismiss.
--
-- Drag is modeled as three pure calls — BeginDrag/DragTo/EndDrag — driven by mouse press
-- state a caller (main.lua) polls off the client `Mouse` global and a small capture
-- component, mirroring the Editor's own press-then-poll gesture (ui/graph.lua's
-- beginPress/positionCapture); only EndDrag persists, so a live drag doesn't spam
-- PersistentDB every tick. See `Mount`/`Update` below for the client-only (untested under
-- the bare interpreter) half of that wiring.

local Util = require("util")
local Theme = require("ui/theme")

local function callOrLog(context, fn, ...)
    return Util.CallOrLog("overlay", context, fn, ...)
end

local Overlay = {}
Overlay.__index = Overlay

-- The single owner key every Overlay node's toasts share in the EffectRegistry's Stack, so
-- the cap below applies across the whole graph (all alerts), not per node.
Overlay.OWNER = "overlay"
Overlay.MAX_STACK = 10
Overlay.DEFAULT_TTL = 5.0

-- `effects` is the EffectRegistry (runtime.effects) this stack pushes its toast handles
-- into. `persistence` is optional: `{ Load() -> {dx,dy}|nil, Save({dx,dy}) }`; omitted (or
-- both nil, the bare-interpreter default) just means the anchor never survives a reload.
function Overlay.new(effects, persistence)
    assert(effects ~= nil, "OverlayStack requires an EffectRegistry")
    local self = setmetatable({
        effects = effects,
        persistence = persistence,
        live = {},      -- ordered list of live toast handles, oldest first
        byOwner = {},   -- nodeKey -> { handle, ... }, oldest first
        anchor = { dx = 0, dy = 0 },
        drag = nil,     -- { startMouse = {x,y}, startAnchor = {dx,dy} } while a drag is live
        capture = nil,  -- client-only NON-clickthrough drag-capture component, see Mount
        rootParent = nil, -- client root component, kept for screen width (see _screenWidth)
    }, Overlay)
    self:_loadAnchor()
    return self
end

--- Anchor persistence -----------------------------------------------------------------

function Overlay:_loadAnchor()
    if self.persistence == nil or self.persistence.Load == nil then
        return
    end
    local ok, pos = pcall(self.persistence.Load)
    if ok and type(pos) == "table" and type(pos.dx) == "number" and type(pos.dy) == "number" then
        self.anchor = { dx = pos.dx, dy = pos.dy }
    end
end

function Overlay:_saveAnchor()
    if self.persistence == nil or self.persistence.Save == nil then
        return
    end
    callOrLog("anchor Save", self.persistence.Save, { dx = self.anchor.dx, dy = self.anchor.dy })
end

-- The current anchor as a {dx, dy} pixel offset from the default top-center point (see
-- Theme.OVERLAY_TOP_MARGIN for that default's own screen placement — client-only concern,
-- kept out of this pure module).
function Overlay:GetAnchorOffset()
    return { dx = self.anchor.dx, dy = self.anchor.dy }
end

--- Drag ---------------------------------------------------------------------------------

function Overlay:BeginDrag(mousePos)
    self.drag = {
        startMouse = { x = mousePos.x, y = mousePos.y },
        startAnchor = { dx = self.anchor.dx, dy = self.anchor.dy },
    }
end

function Overlay:DragTo(mousePos)
    if self.drag == nil then
        return
    end
    local dx = mousePos.x - self.drag.startMouse.x
    local dy = mousePos.y - self.drag.startMouse.y
    self.anchor = { dx = self.drag.startAnchor.dx + dx, dy = self.drag.startAnchor.dy + dy }
end

-- Ends the gesture and persists the final position — the only point in a drag that writes
-- through the persistence hook, so dragging doesn't re-encode/save every polled frame.
function Overlay:EndDrag()
    if self.drag == nil then
        return
    end
    self.drag = nil
    self:_saveAnchor()
end

--- Show / Dismiss --------------------------------------------------------------------------

-- `params`: { text, color, icon, sticky }. Pushes a new toast handle for `nodeKey` onto the
-- shared Stack (cap MAX_STACK, oldest evicted first — see effects.lua:PushStack) and tracks
-- it under `nodeKey` so a later Dismiss(nodeKey) can find it. A node re-firing `show` calls
-- this again and gets a SECOND handle stacked alongside the first (#36: "same-node re-fire
-- STACKs"), never replacing it.
function Overlay:Show(nodeKey, params)
    params = params or {}
    local sticky = params.sticky and true or false
    local state = {
        nodeKey = nodeKey,
        text = params.text or "",
        color = params.color,
        icon = params.icon,
        sticky = sticky,
        remaining = sticky and nil or (params.ttl or Overlay.DEFAULT_TTL),
    }

    local self_ = self
    local handle
    handle = {
        kind = "overlay",
        state = state,
        update = function(dt)
            if state.sticky then
                return true
            end
            state.remaining = state.remaining - dt
            return state.remaining > 0
        end,
        draw = function(canvas) self_:_drawHandle(canvas, handle) end,
        onDone = function() self_:_forget(handle) end,
    }

    self.live[#self.live + 1] = handle
    local owned = self.byOwner[nodeKey]
    if owned == nil then
        owned = {}
        self.byOwner[nodeKey] = owned
    end
    owned[#owned + 1] = handle

    self.effects:PushStack(Overlay.OWNER, handle, Overlay.MAX_STACK)
    return handle
end

-- Removes `handle` from `live`/`byOwner` bookkeeping (called from its own onDone, whether it
-- left the live set via natural TTL expiry, an explicit Dismiss, or a cap eviction — all
-- three route through EffectRegistry's onDone the same way).
function Overlay:_forget(handle)
    for i, h in ipairs(self.live) do
        if h == handle then
            table.remove(self.live, i)
            break
        end
    end
    local owned = self.byOwner[handle.state.nodeKey]
    if owned == nil then
        return
    end
    for i, h in ipairs(owned) do
        if h == handle then
            table.remove(owned, i)
            break
        end
    end
    if #owned == 0 then
        self.byOwner[handle.state.nodeKey] = nil
    end
end

-- Clears every live toast belonging to `nodeKey` (#36: "dismiss clears all of that node's
-- live overlays" — including sticky ones, which never expire on their own). No-op for a
-- node with nothing live. Snapshots the owned list first since each Dismiss's onDone
-- mutates `byOwner[nodeKey]` in place.
function Overlay:Dismiss(nodeKey)
    local owned = self.byOwner[nodeKey]
    if owned == nil then
        return
    end
    local toDismiss = {}
    for i, h in ipairs(owned) do
        toDismiss[i] = h
    end
    for _, h in ipairs(toDismiss) do
        self.effects:Dismiss(h)
    end
end

function Overlay:LiveCount()
    return #self.live
end

--- Canvas drawing (client-only; untested under the standalone Lua test harness) -----------

-- Full-screen width, read from the client's root component (the same source, and fallback,
-- as the Editor's own screenSize() in ui/graph.lua — the Canvas can't be measured for this).
-- Falls back to a fixed guess so this never errors outside the client.
function Overlay:_screenWidth()
    local w = 1920
    if self.rootParent ~= nil then
        pcall(function()
            if self.rootParent.width and self.rootParent.width > 0 then w = self.rootParent.width end
        end)
    end
    return w
end

-- The default top-center anchor point in absolute screen space, before the user's own drag offset.
function Overlay:_anchorPoint()
    return {
        x = self:_screenWidth() * 0.5 + self.anchor.dx,
        y = Theme.OVERLAY_TOP_MARGIN + self.anchor.dy,
    }
end

-- Body + left accent bar (the `color` data pin's dynamic tint) + outline + optional icon
-- sprite + text (#36 AC) — Canvas primitives only, not ui.GroupBox. Stacked vertically below
-- the shared anchor in `live` order (oldest on top), independent of which node owns which.
function Overlay:_drawHandle(canvas, handle)
    local index
    for i, h in ipairs(self.live) do
        if h == handle then index = i; break end
    end
    if index == nil then
        return
    end

    local anchor = self:_anchorPoint()
    local x = anchor.x - Theme.OVERLAY_W * 0.5
    local y = anchor.y + (index - 1) * (Theme.OVERLAY_H + Theme.OVERLAY_GAP)
    local w, h = Theme.OVERLAY_W, Theme.OVERLAY_H
    local state = handle.state

    canvas:AddRectangle(x, y, w, h, Theme.Vec4(Theme.COL_OVERLAY_BG))
    local accent = state.color
    if accent ~= nil then
        canvas:AddRectangle(x, y, Theme.OVERLAY_ACCENT_W, h,
            Vector4.new((accent.r or 255) / 255, (accent.g or 255) / 255, (accent.b or 255) / 255,
                (accent.a or 255) / 255))
    end
    canvas:AddOutline(x, y, w, h, Theme.BORDER_THICKNESS, Theme.Vec4(Theme.COL_OVERLAY_BORDER))

    local textX = x + Theme.OVERLAY_ACCENT_W + Theme.OVERLAY_PAD_X
    if state.icon ~= nil then
        local iconY = y + (h - Theme.OVERLAY_ICON_SIZE) * 0.5
        -- AddSprite's colour arg is a Uint RGBA, not a Vector4 (see
        -- docs/research/popup-frame-sprites.md); untinted white, like InfoBox.
        canvas:AddSprite(textX, iconY, Theme.OVERLAY_ICON_SIZE, Theme.OVERLAY_ICON_SIZE, state.icon,
            0xFFFFFFFF)
        textX = textX + Theme.OVERLAY_ICON_SIZE + Theme.OVERLAY_PAD_X
    end

    local font = Theme.Font(12)
    if font ~= nil then
        canvas:AddText(textX, y + h * 0.5 - 6, state.text, font, Theme.Vec4(Theme.COL_OVERLAY_TEXT))
    end
end

-- Draws every live toast (client-only entry point; main.lua calls this from the same
-- onDraw that already drives runtime.effects:Draw()). `canvas` defaults to the mounted
-- capture's own canvas — but the toasts actually draw on the shared effect overlay Canvas
-- (effects.lua), passed in by the caller, same as every other effect kind.
function Overlay:Draw(canvas)
    if canvas == nil then
        return
    end
    for _, handle in ipairs(self.live) do
        callOrLog("draw error", handle.draw, canvas)
    end
end

--- Drag capture mount (client-only; untested under the standalone Lua test harness) -------

-- The always-on effect overlay Canvas (effects.lua) is `clickthrough = true` so it never
-- steals a game click — dragging instead needs a small, separate, NON-clickthrough capture
-- component sized to the live toast stack's own bounds, mounted only while something is
-- live and repositioned every frame, mirroring the Editor's own Capture Layer (ui/graph.lua)
-- press-then-poll gesture: ONCLICK begins the drag, Mouse.GetPosition() is polled each Logic
-- tick while pressed (see Update below), ONRELEASE ends and persists it.
function Overlay:Mount(rootParent)
    self.rootParent = rootParent  -- kept for _screenWidth() (anchor centering)
    if self.capture ~= nil then
        return
    end
    local ok, capture = pcall(function()
        local c = ui.Panel.new(rootParent)
        c.clickthrough = false
        local self_ = self
        c:Subscribe(ui.Hook.ONCLICK, function()
            local pos = (Mouse ~= nil and Mouse.GetPosition ~= nil) and Mouse.GetPosition() or nil
            if pos ~= nil then
                self_:BeginDrag(pos)
                self_._pressed = true
            end
        end)
        c:Subscribe(ui.Hook.ONRELEASE, function()
            self_._pressed = false
            self_:EndDrag()
        end)
        return c
    end)
    if ok then
        self.capture = capture
    elseif log ~= nil then
        log("Watchdog overlay: Mount failed — " .. tostring(capture))
    end
end

function Overlay:Unmount()
    if self.capture ~= nil then
        pcall(function() self.capture:Destroy() end)
        self.capture = nil
    end
end

-- Called once per Logic tick (main.lua, alongside runtime:Update): while a press is held,
-- polls Mouse.GetPosition() to drag the anchor, and repositions the capture component over
-- the current stack bounds so it only ever intercepts clicks that actually land on a toast.
function Overlay:Update(dt)
    if self._pressed and Mouse ~= nil and Mouse.GetPosition ~= nil then
        local ok, pos = pcall(Mouse.GetPosition)
        if ok and pos ~= nil then
            self:DragTo(pos)
        end
    end
    if self.capture == nil or #self.live == 0 then
        return
    end
    local anchor = self:_anchorPoint()
    local x = anchor.x - Theme.OVERLAY_W * 0.5
    local h = #self.live * Theme.OVERLAY_H + math.max(0, #self.live - 1) * Theme.OVERLAY_GAP
    pcall(function()
        self.capture:SetPos(x, anchor.y)
        self.capture:SetSize(Theme.OVERLAY_W, h)
    end)
end

return Overlay
