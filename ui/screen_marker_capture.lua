-- screen_marker_capture.lua — the transient full-screen capture overlay behind
-- action.screen_marker's "Draw on screen" button (#39): drag corner-to-corner anywhere on
-- screen to write one {x, y, w, h} rect (pixels, no clamp) back to the pin's Control value;
-- Esc cancels. Mirrors ui/infobox.lua's Mount/Reposition/Unmount click-capture idiom (#41) --
-- its own alpha-0 ui.Button, sized to the true full screen only while armed/dragging
-- (0,0,1.0,1.0, matching effects.lua's own Mount), never the windowed editor Canvas (see
-- ui/graph.lua's coordinate-model note: the editor Canvas is Window-sized, not full-screen,
-- so it can't host this overlay's drag capture or draw). Its dim/selection-box Draw is meant
-- to ride the always-on overlay Canvas (runtime.effects), same as every other effect.
--
-- The state machine (Arm/Cancel/BeginDrag/UpdateDrag/EndDrag + the static Rect() normalizer)
-- is pure and unit-tested directly, no client globals; Mount/Reposition/Unmount/Draw are
-- client-only, same disclaimer as ui/infobox.lua's own click-capture section.

local Theme = require("ui/theme")
local IfaceScale = require("ui/iface_scale")

local ScreenMarkerCapture = {}
ScreenMarkerCapture.__index = ScreenMarkerCapture

function ScreenMarkerCapture.new()
    return setmetatable({
        armed = false,
        dragging = false,
        nodeId = nil,
        pinName = nil,
        onCommit = nil,
        startX = nil, startY = nil,
        curX = nil, curY = nil,
        _capture = nil,
    }, ScreenMarkerCapture)
end

--- Pure drag math --------------------------------------------------------------------------

-- Normalizes two corner points into a {x, y, w, h} rect (pixels, no clamp -- the issue's
-- "no typed fields... no clamp" spec): a top-left corner plus always-positive width/height,
-- regardless of which direction the drag went.
function ScreenMarkerCapture.Rect(x0, y0, x1, y1)
    return {
        x = math.min(x0, x1), y = math.min(y0, y1),
        w = math.abs(x1 - x0), h = math.abs(y1 - y0),
    }
end

--- State machine ---------------------------------------------------------------------------

-- Arms a capture for one node/pin: the next BeginDrag starts the actual corner-to-corner
-- drag. `onCommit(rect)` fires once, on EndDrag, with the finished {x,y,w,h}. Re-arming
-- (e.g. a second click of the button before finishing) just retargets -- no stacked state.
function ScreenMarkerCapture:Arm(nodeId, pinName, onCommit)
    self.armed = true
    self.dragging = false
    self.nodeId, self.pinName, self.onCommit = nodeId, pinName, onCommit
    self.startX, self.startY, self.curX, self.curY = nil, nil, nil, nil
    self:Reposition()
end

function ScreenMarkerCapture:IsArmed()
    return self.armed
end

function ScreenMarkerCapture:IsDragging()
    return self.dragging
end

-- Aborts an armed-but-not-yet-dragging capture, or a drag already in progress -- no commit
-- either way (Esc cancels, per the issue). Safe to call when already idle.
function ScreenMarkerCapture:Cancel()
    self.armed = false
    self.dragging = false
    self.nodeId, self.pinName, self.onCommit = nil, nil, nil
    self.startX, self.startY, self.curX, self.curY = nil, nil, nil, nil
    self:Reposition()
end

-- The first corner (mouse-down while armed). No-op if not armed or a drag is already live.
function ScreenMarkerCapture:BeginDrag(px, py)
    if not self.armed or self.dragging then return end
    self.dragging = true
    self.startX, self.startY, self.curX, self.curY = px, py, px, py
end

-- Tracks the live cursor mid-drag. No-op unless a drag is in progress.
function ScreenMarkerCapture:UpdateDrag(px, py)
    if not self.dragging then return end
    self.curX, self.curY = px, py
end

-- The second corner (mouse-up): commits the normalized rect through `onCommit` and resets
-- to idle. No-op if not dragging.
function ScreenMarkerCapture:EndDrag()
    if not self.dragging then return end
    local rect = ScreenMarkerCapture.Rect(self.startX, self.startY, self.curX, self.curY)
    local onCommit = self.onCommit
    self:Cancel()
    if onCommit ~= nil then
        onCommit(rect)
    end
end

--- Click-capture mount (client-only; untested under the standalone Lua harness) -----------

local function mousePos()
    if Mouse == nil or Mouse.GetPosition == nil then return nil end
    local ok, pos = pcall(function() return Mouse.GetPosition() end)
    if ok and pos ~= nil then
        return IfaceScale.ToInterface(pos.x, pos.y)
    end
    return nil
end

-- Mounts the full-screen click-capture layer as a direct child of `rootParent` (the same
-- root the effect overlay Canvas mounts under, see effects.lua's own Mount). Idempotent: a
-- second Mount before Unmount is a no-op.
function ScreenMarkerCapture:Mount(rootParent)
    if self._capture ~= nil then
        return
    end
    local sm = self
    local ok, capture = pcall(function()
        local c = ui.Button.new(rootParent)
        c.alpha = 0
        c.clickthrough = false
        c:Subscribe(ui.Hook.ONCLICK, function()
            local mx, my = mousePos()
            if mx ~= nil then sm:BeginDrag(mx, my) end
        end)
        c:Subscribe(ui.Hook.ONRELEASE, function() sm:EndDrag() end)
        return c
    end)
    if ok then
        self._capture = capture
        self:Reposition()
    elseif log ~= nil then
        log("Watchdog screen_marker: Mount failed — " .. tostring(capture))
    end
end

function ScreenMarkerCapture:IsMounted()
    return self._capture ~= nil
end

function ScreenMarkerCapture:Unmount()
    if self._capture ~= nil then
        pcall(function() self._capture:Destroy() end)
        self._capture = nil
    end
end

-- Sizes the capture layer to the true full screen while armed/dragging, or to nothing when
-- idle -- so it can't swallow game/editor clicks the rest of the time (same reasoning as
-- ui/infobox.lua's empty-area shrink, just gated on armed instead of tile count). Called
-- from Arm/Cancel; main.lua doesn't need to poll this every tick the way InfoBox's Bounds-
-- driven Reposition does, since "armed" only ever changes on those two calls.
function ScreenMarkerCapture:Reposition()
    if self._capture == nil then
        return
    end
    pcall(function()
        if self.armed then
            self._capture:SetPos(0, 0)
            self._capture:SetSize(0, 0, 1.0, 1.0)
        else
            self._capture:SetSize(0, 0)
        end
    end)
end

--- Draw (client-only; untested under the bare Lua harness) ---------------------------------

-- Dims the whole screen and outlines the in-progress rect while dragging, onto `canvas` (the
-- always-on overlay Canvas -- see effects.lua). No-op unless actively dragging (an
-- armed-but-not-yet-dragging capture draws nothing, matching a plain unpressed button).
function ScreenMarkerCapture:Draw(canvas)
    if canvas == nil or not self.dragging then
        return
    end
    local w, h = 1920, 1080
    pcall(function()
        if canvas.width and canvas.width > 0 then w = canvas.width end
        if canvas.height and canvas.height > 0 then h = canvas.height end
    end)
    pcall(function()
        canvas:AddRectangle(0, 0, w, h, Theme.Vec4(Theme.COL_SCREEN_MARKER_DIM))
    end)
    local r = ScreenMarkerCapture.Rect(self.startX, self.startY, self.curX, self.curY)
    pcall(function()
        canvas:AddOutline(r.x, r.y, r.w, r.h, Theme.BORDER_THICKNESS,
            Theme.Vec4(Theme.COL_SCREEN_MARKER_DRAG))
    end)
end

return ScreenMarkerCapture
