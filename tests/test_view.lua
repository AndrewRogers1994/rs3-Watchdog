-- Headless View zoom lattice. Expected rungs are literals / independent 1.1^k values.

local luaunit = require("luaunit")
local View = require("ui/view")

TestView = {}

-- k in [-14, 7]: 1.1^-14 > 0.25 > 1.1^-15 and 1.1^7 < 2 < 1.1^8. Plus endpoints → 24.
local INTERIOR_K_MIN = -14
local INTERIOR_K_MAX = 7
local EXPECTED_RUNG_COUNT = (INTERIOR_K_MAX - INTERIOR_K_MIN + 1) + 2

function TestView:testRungListIncludesMinMaxAndDefaultAndIsOrdered()
    local rungs = View.Rungs()
    luaunit.assertEquals(rungs[1], 0.25)
    luaunit.assertEquals(rungs[#rungs], 2.0)
    luaunit.assertEquals(#rungs, EXPECTED_RUNG_COUNT)

    local sawOne = false
    for i = 1, #rungs - 1 do
        luaunit.assertTrue(rungs[i] < rungs[i + 1])
        if rungs[i] == 1.0 then sawOne = true end
    end
    if rungs[#rungs] == 1.0 then sawOne = true end
    luaunit.assertTrue(sawOne)

    local function contains(z)
        for _, r in ipairs(rungs) do
            if math.abs(r - z) < 1e-12 then return true end
        end
        return false
    end
    luaunit.assertTrue(contains(1.1 ^ INTERIOR_K_MIN))
    luaunit.assertTrue(contains(1.1 ^ INTERIOR_K_MAX))
    luaunit.assertFalse(contains(1.1 ^ (INTERIOR_K_MIN - 1)))
    luaunit.assertFalse(contains(1.1 ^ (INTERIOR_K_MAX + 1)))
end

-- Positive delta zooms out (same sign as today's wheel).
function TestView:testStepFromDefaultLandsOnNeighbors()
    local v = View.new()
    luaunit.assertEquals(v.zoom, 1.0)
    v:StepZoomAt(0, 0, 1)
    luaunit.assertAlmostEquals(v.zoom, 1 / 1.1, 1e-12)
    v.zoom = 1.0
    v:StepZoomAt(0, 0, -1)
    luaunit.assertAlmostEquals(v.zoom, 1.1, 1e-12)
end

function TestView:testStepFromLastInteriorPowerLandsOnEndpoints()
    local v = View.new()
    v.zoom = 1.1 ^ INTERIOR_K_MAX
    v:StepZoomAt(0, 0, -1)
    luaunit.assertEquals(v.zoom, 2.0)
    v.zoom = 1.1 ^ INTERIOR_K_MIN
    v:StepZoomAt(0, 0, 1)
    luaunit.assertEquals(v.zoom, 0.25)
end

function TestView:testStepAtEndpointsIsNoOp()
    local v = View.new()
    v.zoom = 2.0
    v:StepZoomAt(0, 0, -1)
    luaunit.assertEquals(v.zoom, 2.0)
    v.zoom = 0.25
    v:StepZoomAt(0, 0, 1)
    luaunit.assertEquals(v.zoom, 0.25)
end

function TestView:testStepOffEndpointLandsOnLastInteriorPower()
    local v = View.new()
    v.zoom = 2.0
    v:StepZoomAt(0, 0, 1)
    luaunit.assertAlmostEquals(v.zoom, 1.1 ^ INTERIOR_K_MAX, 1e-12)
    v.zoom = 0.25
    v:StepZoomAt(0, 0, -1)
    luaunit.assertAlmostEquals(v.zoom, 1.1 ^ INTERIOR_K_MIN, 1e-12)
end

function TestView:testSetZoomAtKeepsGraphPointUnderScreenPointFixed()
    local v = View.new()
    v.panX, v.panY, v.zoom = 40, -20, 1.0
    local sx, sy = 100, 80
    local gx, gy = v:ToGraph(sx, sy)
    v:SetZoomAt(sx, sy, 2.0)
    luaunit.assertEquals(v.zoom, 2.0)
    local gx2, gy2 = v:ToGraph(sx, sy)
    luaunit.assertAlmostEquals(gx2, gx, 1e-12)
    luaunit.assertAlmostEquals(gy2, gy, 1e-12)
end

function TestView:testStepZoomAtKeepsGraphPointUnderScreenPointFixed()
    local v = View.new()
    v.panX, v.panY, v.zoom = 40, -20, 1.0
    local sx, sy = 100, 80
    local gx, gy = v:ToGraph(sx, sy)
    v:StepZoomAt(sx, sy, -1)
    luaunit.assertAlmostEquals(v.zoom, 1.1, 1e-12)
    local gx2, gy2 = v:ToGraph(sx, sy)
    luaunit.assertAlmostEquals(gx2, gx, 1e-12)
    luaunit.assertAlmostEquals(gy2, gy, 1e-12)
end

-- 1.02 is closer to 1.0 than to 1.1; snap then zoom out → 1/1.1.
function TestView:testOffLatticeZoomJoinsLatticeOnNextStep()
    local v = View.new()
    v.zoom = 1.02
    v:StepZoomAt(0, 0, 1)
    luaunit.assertAlmostEquals(v.zoom, 1 / 1.1, 1e-12)
end

function TestView:testRungIndexOfEndpointsAndDefault()
    luaunit.assertEquals(View.RungIndex(0.25), 1)
    luaunit.assertEquals(View.RungIndex(2.0), EXPECTED_RUNG_COUNT)
    luaunit.assertEquals(View.Rungs()[View.RungIndex(1.0)], 1.0)
end
