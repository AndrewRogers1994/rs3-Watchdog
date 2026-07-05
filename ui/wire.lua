-- wire.lua — draws a Wire as a horizontal-tangent cubic bezier, tessellated into
-- straight AddLine segments (Canvas has no native curve — see ADR-0001).
--
-- Endpoints are given in Graph-space with a horizontal tangent direction each: +1 means
-- the curve leaves the endpoint heading right (an output pin), -1 heading left (an input
-- pin). This one entry point serves committed Wires and the pending drag Wire alike.

local Theme = require("ui/theme")

local Wire = {}

-- Cubic bezier point at parameter t in [0,1]. Pure.
local function cubic(p0, p1, p2, p3, t)
    local u = 1 - t
    return u * u * u * p0
        + 3 * u * u * t * p1
        + 3 * u * t * t * p2
        + t * t * t * p3
end

-- Draws a wire between two Graph-space endpoints through the View.
-- color is a {r,g,b,a} theme color.
function Wire.DrawCurve(canvas, view, x0, y0, dir0, x1, y1, dir1, color)
    local s0x, s0y = view:ToScreen(x0, y0)
    local s1x, s1y = view:ToScreen(x1, y1)

    -- Tangent handle length: proportional to horizontal span, with a zoom-scaled floor
    -- so short/vertical wires still bow out into the recognizable Blueprint S.
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
        canvas:AddLine(px, py, nx, ny, thickness, vcol)
        px, py = nx, ny
    end
end

-- Color for a wire carrying a given pin kind/type: exec is neutral, data follows its tag.
function Wire.ColorFor(kind, dataType)
    if kind == "exec" then
        return Theme.COL_EXEC
    end
    return Theme.TypeColor(dataType)
end

-- Horizontal tangent direction for a pin by its side: outputs leave right, inputs left.
function Wire.DirFor(direction)
    return direction == "out" and 1 or -1
end

return Wire
