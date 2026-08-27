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

function View:ToScreen(gx, gy)
    return gx * self.zoom + self.panX, gy * self.zoom + self.panY
end

function View:ToGraph(sx, sy)
    return (sx - self.panX) / self.zoom, (sy - self.panY) / self.zoom
end

function View:Scale(len)
    return len * self.zoom
end

function View:PanBy(dsx, dsy)
    self.panX = self.panX + dsx
    self.panY = self.panY + dsy
end

function View:ZoomAt(sx, sy, factor, minZoom, maxZoom)
    local gx, gy = self:ToGraph(sx, sy)
    self.zoom = clamp(self.zoom * factor, minZoom, maxZoom)
    -- Keep the graph point under the cursor fixed after zoom.
    self.panX = sx - gx * self.zoom
    self.panY = sy - gy * self.zoom
end

return View
