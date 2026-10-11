-- CaptureArm.Decide (#71): same-control re-click cancels; anything else arms.
local luaunit = require("luaunit")
local CaptureArm = require("src/ui/capture_arm")

TestCaptureArmDecide = {}

function TestCaptureArmDecide:testIdleAlwaysArms()
    luaunit.assertEquals(CaptureArm.Decide(nil, nil, 1, "rect"), "arm")
end

function TestCaptureArmDecide:testSameTargetCancels()
    luaunit.assertEquals(CaptureArm.Decide(1, "rect", 1, "rect"), "cancel")
end

function TestCaptureArmDecide:testDifferentPinRetargets()
    luaunit.assertEquals(CaptureArm.Decide(1, "rect", 1, "object"), "arm")
end

function TestCaptureArmDecide:testDifferentNodeRetargets()
    luaunit.assertEquals(CaptureArm.Decide(1, "rect", 2, "rect"), "arm")
end

return TestCaptureArmDecide
