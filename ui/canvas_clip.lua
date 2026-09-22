-- Native Canvas clips box draws to the component; AddLine / AddTriangle do not.

---@class Watchdog.ClipPoint
---@field x number
---@field y number

local Clip = {}

-- Intersect a segment's parameter range with one viewport axis.
---@param origin number
---@param delta number
---@param minimum number
---@param maximum number
---@param first number
---@param last number
---@return number|nil
---@return number|nil
local function clipAxis(origin, delta, minimum, maximum, first, last)
    if delta == 0 then
        if origin < minimum or origin > maximum then return nil end
        return first, last
    end
    local a, b = (minimum - origin) / delta, (maximum - origin) / delta
    if a > b then a, b = b, a end
    first, last = math.max(first, a), math.min(last, b)
    if first > last then return nil end
    return first, last
end

-- Inset by the stroke extent so caps and integer rounding cannot cross chrome.
---@param thickness number
---@param vx number
---@param vy number
---@param vw number
---@param vh number
---@return number|nil left
---@return number|nil top
---@return number|nil right
---@return number|nil bottom
local function strokeBounds(thickness, vx, vy, vw, vh)
    local inset = math.ceil(thickness) + 1
    local left, top = vx + inset, vy + inset
    local right, bottom = vx + vw - inset, vy + vh - inset
    if right < left or bottom < top then return nil end
    return left, top, right, bottom
end

---@param canvas ui.Canvas
---@param x0 number
---@param y0 number
---@param x1 number
---@param y1 number
---@param thickness number
---@param color Vector4
---@param vx number
---@param vy number
---@param vw number
---@param vh number
function Clip.Line(canvas, x0, y0, x1, y1, thickness, color, vx, vy, vw, vh)
    local left, top, right, bottom = strokeBounds(thickness, vx, vy, vw, vh)
    if left == nil then return end
    local dx, dy = x1 - x0, y1 - y0
    local first, last = clipAxis(x0, dx, left, right, 0, 1)
    if first then first, last = clipAxis(y0, dy, top, bottom, first, last) end
    if first then
        canvas:AddLine(x0 + dx * first, y0 + dy * first,
            x0 + dx * last, y0 + dy * last, thickness, color)
    end
end

---@param p Watchdog.ClipPoint
---@param q Watchdog.ClipPoint
---@param x number
---@return Watchdog.ClipPoint
local function intersectX(p, q, x)
    local dx = q.x - p.x
    if dx == 0 then return { x = x, y = p.y } end
    local t = (x - p.x) / dx
    return { x = x, y = p.y + (q.y - p.y) * t }
end

---@param p Watchdog.ClipPoint
---@param q Watchdog.ClipPoint
---@param y number
---@return Watchdog.ClipPoint
local function intersectY(p, q, y)
    local dy = q.y - p.y
    if dy == 0 then return { x = p.x, y = y } end
    local t = (y - p.y) / dy
    return { x = p.x + (q.x - p.x) * t, y = y }
end

---@param poly Watchdog.ClipPoint[]
---@param inside fun(p: Watchdog.ClipPoint): boolean
---@param intersect fun(p: Watchdog.ClipPoint, q: Watchdog.ClipPoint): Watchdog.ClipPoint
---@return Watchdog.ClipPoint[]
local function clipPoly(poly, inside, intersect)
    local out = {}
    local n = #poly
    if n == 0 then return out end
    local prev = poly[n]
    for i = 1, n do
        local curr = poly[i]
        if inside(curr) then
            if not inside(prev) then
                out[#out + 1] = intersect(prev, curr)
            end
            out[#out + 1] = curr
        elseif inside(prev) then
            out[#out + 1] = intersect(prev, curr)
        end
        prev = curr
    end
    return out
end

---@param canvas ui.Canvas
---@param p0x number
---@param p0y number
---@param p1x number
---@param p1y number
---@param p2x number
---@param p2y number
---@param color Vector4
---@param vx number
---@param vy number
---@param vw number
---@param vh number
function Clip.Triangle(canvas, p0x, p0y, p1x, p1y, p2x, p2y, color, vx, vy, vw, vh)
    local left, top, right, bottom = vx, vy, vx + vw, vy + vh
    if right <= left or bottom <= top then return end

    local minx = math.min(p0x, p1x, p2x)
    local maxx = math.max(p0x, p1x, p2x)
    local miny = math.min(p0y, p1y, p2y)
    local maxy = math.max(p0y, p1y, p2y)
    if maxx < left or minx > right or maxy < top or miny > bottom then return end

    if minx >= left and maxx <= right and miny >= top and maxy <= bottom then
        canvas:AddTriangle(p0x, p0y, p1x, p1y, p2x, p2y, color)
        return
    end

    local poly = { { x = p0x, y = p0y }, { x = p1x, y = p1y }, { x = p2x, y = p2y } }
    poly = clipPoly(poly, function(p) return p.x >= left end, function(p, q) return intersectX(p, q, left) end)
    poly = clipPoly(poly, function(p) return p.x <= right end, function(p, q) return intersectX(p, q, right) end)
    poly = clipPoly(poly, function(p) return p.y >= top end, function(p, q) return intersectY(p, q, top) end)
    poly = clipPoly(poly, function(p) return p.y <= bottom end, function(p, q) return intersectY(p, q, bottom) end)

    if #poly < 3 then return end
    for _, p in ipairs(poly) do
        p.x = math.min(right, math.max(left, p.x))
        p.y = math.min(bottom, math.max(top, p.y))
    end
    local a = poly[1]
    for i = 2, #poly - 1 do
        local b, c = poly[i], poly[i + 1]
        canvas:AddTriangle(a.x, a.y, b.x, b.y, c.x, c.y, color)
    end
end

---@param canvas ui.Canvas
---@param vx number
---@param vy number
---@param vw number
---@param vh number
---@return ui.Canvas
function Clip.Wrap(canvas, vx, vy, vw, vh)
    local wrapped = {}
    function wrapped:AddLine(x, y, endX, endY, thickness, colour)
        Clip.Line(canvas, x, y, endX, endY, thickness, colour, vx, vy, vw, vh)
    end
    function wrapped:AddTriangle(p0x, p0y, p1x, p1y, p2x, p2y, colour)
        Clip.Triangle(canvas, p0x, p0y, p1x, p1y, p2x, p2y, colour, vx, vy, vw, vh)
    end
    return setmetatable(wrapped, {
        __index = function(_, key)
            local v = canvas[key]
            if type(v) == "function" then
                return function(_, ...)
                    return v(canvas, ...)
                end
            end
            return v
        end,
    })
end

return Clip
