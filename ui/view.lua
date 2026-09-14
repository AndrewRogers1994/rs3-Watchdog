local Theme = require("ui/theme")

---@class Watchdog.View
---@field panX number
---@field panY number
---@field zoom number
local View = {}
View.__index = View

-- {ZOOM_MIN} + 1.0 * ZOOM_STEP^k strictly inside (min, max) + {ZOOM_MAX}.
-- Anchored at 1.0 so wheel and slider cannot drift onto path-dependent zooms.
local function buildRungs()
    local minZ, maxZ, step = Theme.ZOOM_MIN, Theme.ZOOM_MAX, Theme.ZOOM_STEP
    local interior = {}
    local k = 0
    while true do
        local z = step ^ k
        if z >= maxZ then break end
        if z > minZ then interior[#interior + 1] = z end
        k = k + 1
    end
    k = -1
    while true do
        local z = step ^ k
        if z <= minZ then break end
        interior[#interior + 1] = z
        k = k - 1
    end
    table.sort(interior)
    local rungs = { minZ }
    for i = 1, #interior do
        rungs[#rungs + 1] = interior[i]
    end
    rungs[#rungs + 1] = maxZ
    return rungs
end

local RUNGS = buildRungs()

---@return number[]
function View.Rungs()
    return RUNGS
end

local function nearestIndex(zoom)
    local bestI = 1
    local bestD = math.abs(RUNGS[1] - zoom)
    for i = 2, #RUNGS do
        local d = math.abs(RUNGS[i] - zoom)
        if d < bestD then
            bestI = i
            bestD = d
        end
    end
    return bestI
end

-- Ties go to the lower zoom.
---@param zoom number
---@return number
function View.NearestRung(zoom)
    return RUNGS[nearestIndex(zoom)]
end

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

---@param sx number
---@param sy number
---@param zoom number
function View:SetZoomAt(sx, sy, zoom)
    local gx, gy = self:ToGraph(sx, sy)
    self.zoom = clamp(zoom, Theme.ZOOM_MIN, Theme.ZOOM_MAX)
    -- Keep the graph point under (sx, sy) fixed after zoom.
    self.panX = sx - gx * self.zoom
    self.panY = sy - gy * self.zoom
end

-- Positive delta zooms out. Off-lattice: nearest rung, then one step.
---@param sx number
---@param sy number
---@param delta number
function View:StepZoomAt(sx, sy, delta)
    if delta == 0 then return end
    local dir = delta > 0 and -1 or 1
    local i = clamp(nearestIndex(self.zoom) + dir, 1, #RUNGS)
    self:SetZoomAt(sx, sy, RUNGS[i])
end

return View
