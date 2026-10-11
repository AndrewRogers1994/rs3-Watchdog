local CaptureArm = {}

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
