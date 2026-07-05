-- view.lua — the View: the pan+zoom transform mapping Graph-space to Screen-space.
--
-- Pure math, no client globals. The Editor holds one View; drawing applies it,
-- hit-testing inverts it. Screen-space here means absolute interface units (the
-- full-screen Canvas coordinate space).

local View = {}
View.__index = View

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function View.new()
    return setmetatable({
        panX = 0,   -- screen-space offset of Graph-space origin
        panY = 0,
        zoom = 1.0,
    }, View)
end

-- Graph-space point -> Screen-space point.
function View:ToScreen(gx, gy)
    return gx * self.zoom + self.panX, gy * self.zoom + self.panY
end

-- Screen-space point -> Graph-space point.
function View:ToGraph(sx, sy)
    return (sx - self.panX) / self.zoom, (sy - self.panY) / self.zoom
end

-- Scale a Graph-space length into Screen-space.
function View:Scale(len)
    return len * self.zoom
end

-- Pan by a screen-space delta (e.g. a mouse drag on empty canvas).
function View:PanBy(dsx, dsy)
    self.panX = self.panX + dsx
    self.panY = self.panY + dsy
end

-- Zoom toward a screen anchor (the cursor), keeping the Graph-space point currently
-- under the anchor fixed on screen. `factor` multiplies the current zoom; the result
-- is clamped to [minZoom, maxZoom].
function View:ZoomAt(sx, sy, factor, minZoom, maxZoom)
    local gx, gy = self:ToGraph(sx, sy)
    self.zoom = clamp(self.zoom * factor, minZoom, maxZoom)
    -- Re-derive pan so (gx,gy) maps back onto (sx,sy) at the new zoom.
    self.panX = sx - gx * self.zoom
    self.panY = sy - gy * self.zoom
end

return View
