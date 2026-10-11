_G.Vector4 = _G.Vector4 or { new = function(r, g, b, a) return { r, g, b, a } end }

local luaunit = require("luaunit")
local Clip    = require("src/ui/canvas_clip")
local Node    = require("src/ui/node")
local View    = require("src/ui/view")
local Theme   = require("src/ui/theme")

local function recordingCanvas()
    local c = { triangles = {}, lines = {}, rects = 0 }
    function c:AddTriangle(x0, y0, x1, y1, x2, y2, color)
        self.triangles[#self.triangles + 1] = { x0, y0, x1, y1, x2, y2, color }
    end
    function c:AddLine(x0, y0, x1, y1, thickness, color)
        self.lines[#self.lines + 1] = { x0, y0, x1, y1, thickness, color }
    end
    function c:AddRectangle() self.rects = self.rects + 1 end
    function c:AddOutline() end
    function c:AddText() end
    return c
end

local VX, VY, VW, VH = 0, 0, 200, 150

local function assertTriangleInside(tri, left, top, right, bottom)
    for i = 1, 5, 2 do
        luaunit.assertTrue(tri[i] >= left - 1e-9)
        luaunit.assertTrue(tri[i] <= right + 1e-9)
        luaunit.assertTrue(tri[i + 1] >= top - 1e-9)
        luaunit.assertTrue(tri[i + 1] <= bottom + 1e-9)
    end
end

local function assertLineInside(line, vx, vy, vw, vh)
    local thickness = line[5]
    for i = 1, 3, 2 do
        luaunit.assertTrue(line[i] - thickness >= vx - 1e-9)
        luaunit.assertTrue(line[i] + thickness <= vx + vw + 1e-9)
        luaunit.assertTrue(line[i + 1] - thickness >= vy - 1e-9)
        luaunit.assertTrue(line[i + 1] + thickness <= vy + vh + 1e-9)
    end
end

TestCanvasClip = {}

function TestCanvasClip:testTriangleFullyInsideIsPassedThrough()
    local canvas = recordingCanvas()
    Clip.Triangle(canvas, 10, 10, 20, 10, 15, 20, "c", VX, VY, VW, VH)
    luaunit.assertEquals(#canvas.triangles, 1)
    luaunit.assertEquals(canvas.triangles[1][1], 10)
    luaunit.assertEquals(canvas.triangles[1][2], 10)
    luaunit.assertEquals(canvas.triangles[1][5], 15)
end

function TestCanvasClip:testTriangleFullyOutsideIsNotDrawn()
    local canvas = recordingCanvas()
    Clip.Triangle(canvas, 400, 10, 410, 10, 405, 20, "c", VX, VY, VW, VH)
    luaunit.assertEquals(#canvas.triangles, 0)
end

function TestCanvasClip:testTriangleCrossingRightEdgeStaysInside()
    local canvas = recordingCanvas()
    Clip.Triangle(canvas, 190, 40, 190, 60, 210, 50, "c", VX, VY, VW, VH)
    luaunit.assertTrue(#canvas.triangles >= 1)
    for _, tri in ipairs(canvas.triangles) do
        assertTriangleInside(tri, VX, VY, VX + VW, VY + VH)
    end
end

function TestCanvasClip:testLineCrossingLeftEdgeStaysInsideStroke()
    local canvas = recordingCanvas()
    Clip.Line(canvas, -20, 40, 40, 40, 2, "c", VX, VY, VW, VH)
    luaunit.assertEquals(#canvas.lines, 1)
    assertLineInside(canvas.lines[1], VX, VY, VW, VH)
end

function TestCanvasClip:testLineFullyOutsideIsNotDrawn()
    local canvas = recordingCanvas()
    Clip.Line(canvas, 300, 40, 340, 40, 2, "c", VX, VY, VW, VH)
    luaunit.assertEquals(#canvas.lines, 0)
end

function TestCanvasClip:testWrapClipsTriangleAndForwardsRect()
    local inner = recordingCanvas()
    local wrapped = Clip.Wrap(inner, VX, VY, VW, VH)
    wrapped:AddRectangle(0, 0, 10, 10, "c")
    wrapped:AddTriangle(190, 40, 190, 60, 210, 50, "c")
    luaunit.assertEquals(inner.rects, 1)
    luaunit.assertTrue(#inner.triangles >= 1)
    for _, tri in ipairs(inner.triangles) do
        assertTriangleInside(tri, VX, VY, VX + VW, VY + VH)
    end
end

function TestCanvasClip:testNodeExecPinAndCloseStayInsideViewport()
    local pins = {
        { name = "out", kind = "exec", direction = "out", label = "out" },
        { name = "val", kind = "data", direction = "out", dataType = "number", label = "a" },
    }
    local geom = Node.BuildGeometry(pins, 0, 0, Theme.NODE_WIDTH)
    local view = View.new()
    -- Glyph center on the right edge so the triangle and close X straddle it.
    view.panX = VW - (geom.x + geom.byName.out.cx)
    view.panY = 10

    local inner = recordingCanvas()
    local wrapped = Clip.Wrap(inner, VX, VY, VW, VH)
    Node.Draw(wrapped, view, geom, { title = "n", category = "pure" }, {})

    luaunit.assertTrue(#inner.triangles >= 1)
    luaunit.assertTrue(#inner.lines >= 2)
    for _, tri in ipairs(inner.triangles) do
        assertTriangleInside(tri, VX, VY, VX + VW, VY + VH)
    end
    for _, line in ipairs(inner.lines) do
        assertLineInside(line, VX, VY, VW, VH)
    end
end
