-- Canvas has no native curve - tessellate a cubic into AddLine segments.

local Theme = require("ui/theme")
local Clip  = require("ui/canvas_clip")

local Wire = {}

---@param p0 number
---@param p1 number
---@param p2 number
---@param p3 number
---@param t number
---@return number
local function cubic(p0, p1, p2, p3, t)
    local u = 1 - t
    return u * u * u * p0
        + 3 * u * u * t * p1
        + 3 * u * t * t * p2
        + t * t * t * p3
end

---@param canvas ui.Canvas
---@param view Watchdog.View
---@param x0 number
---@param y0 number
---@param dir0 number
---@param x1 number
---@param y1 number
---@param dir1 number
---@param color number[]
---@param vx number
---@param vy number
---@param vw number
---@param vh number
function Wire.DrawCurve(canvas, view, x0, y0, dir0, x1, y1, dir1, color, vx, vy, vw, vh)
    local s0x, s0y = view:ToScreen(x0, y0)
    local s1x, s1y = view:ToScreen(x1, y1)

    -- Floor the tangent so short/vertical wires still bow into an S.
    local tang = math.max(math.abs(s1x - s0x) * 0.5, view:Scale(60))
    local c0x, c0y = s0x + dir0 * tang, s0y
    local c1x, c1y = s1x + dir1 * tang, s1y

    local thickness = math.max(1, view:Scale(Theme.WIRE_THICKNESS))
    local vcol = Theme.Vec4(color)
    local segments = Theme.WIRE_SEGMENTS

    local px, py = s0x, s0y
    for i = 1, segments do
        local t = i / segments
        local nx = cubic(s0x, c0x, c1x, s1x, t)
        local ny = cubic(s0y, c0y, c1y, s1y, t)
        Clip.Line(canvas, px, py, nx, ny, thickness, vcol, vx, vy, vw, vh)
        px, py = nx, ny
    end
end

---@param kind string
---@param dataType string|nil
---@return number[]
function Wire.ColorFor(kind, dataType)
    if kind == "exec" then
        return Theme.COL_EXEC
    end
    return Theme.TypeColor(dataType)
end

---@param direction string
---@return number
function Wire.DirFor(direction)
    return direction == "out" and 1 or -1
end

return Wire
