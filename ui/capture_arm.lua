-- Pure Capture Arm decision (#71): given the currently-armed target (or nil) and the Control
-- the author just pressed, decide cancel (same Control re-click) vs arm (idle or retarget).
-- The Editor host applies the side effects (Cancel other kind, Arm/Cancel the chosen overlay).

local CaptureArm = {}

-- Returns "cancel" when the pressed Control is already the armed target; otherwise "arm"
-- (includes first arm and retarget onto a different node/pin).
---@param armedNodeId any
---@param armedPinName string|nil
---@param reqNodeId any
---@param reqPinName string
---@return "cancel"|"arm"
function CaptureArm.Decide(armedNodeId, armedPinName, reqNodeId, reqPinName)
    if armedNodeId ~= nil and armedNodeId == reqNodeId and armedPinName == reqPinName then
        return "cancel"
    end
    return "arm"
end

return CaptureArm
