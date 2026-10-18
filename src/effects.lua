local Util = require("src/util")

local function callOrLog(context, fn, ...)
    return Util.CallOrLog("effects", context, fn, ...)
end

local EffectRegistry = {}
EffectRegistry.__index = EffectRegistry

function EffectRegistry.new()
    return setmetatable({
        canvas = nil,
        stacks = {}, -- owner -> { handle, ... }, oldest first
        queues = {}, -- owner -> { active = handle|nil, pending = { handle, ... } }
    }, EffectRegistry)
end

--- Canvas mount (client-only; untested under the standalone Lua test harness) -------------

-- Full-screen overlay on `rootParent`. Idempotent until Unmount.
function EffectRegistry:Mount(rootParent)
    if self.canvas ~= nil then
        return
    end
    local ok, canvas = pcall(function()
        local c = ui.Canvas.new(rootParent)
        c:SetPos(0, 0)
        c:SetSize(0, 0, 1.0, 1.0)
        c.clickthrough = true
        return c
    end)
    if ok then
        self.canvas = canvas
    elseif log ~= nil then
        log("Watchdog effects: Mount failed - " .. tostring(canvas))
    end
end

function EffectRegistry:IsMounted()
    return self.canvas ~= nil
end

function EffectRegistry:GetCanvas()
    return self.canvas
end

function EffectRegistry:Unmount()
    if self.canvas ~= nil then
        pcall(function() self.canvas:Destroy() end)
        self.canvas = nil
    end
end

--- Pushing handles ------------------------------------------------------------------------

function EffectRegistry:_stackFor(owner)
    local list = self.stacks[owner]
    if list == nil then
        list = {}
        self.stacks[owner] = list
    end
    return list
end

function EffectRegistry:_queueFor(owner)
    local q = self.queues[owner]
    if q == nil then
        q = { active = nil, pending = {} }
        self.queues[owner] = q
    end
    return q
end

function EffectRegistry:PushStack(owner, handle, max)
    local list = self:_stackFor(owner)
    list[#list + 1] = handle
    if max ~= nil then
        while #list > max do
            local evicted = table.remove(list, 1)
            self:_finish(evicted)
        end
    end
end

function EffectRegistry:PushQueue(owner, handle)
    local q = self:_queueFor(owner)
    if q.active == nil then
        q.active = handle
    else
        q.pending[#q.pending + 1] = handle
    end
end

--- Per-frame reset ------------------------------------------------------------------------

-- Wipe retained canvas drawables once per frame. Distinct from Clear() (handle teardown).
function EffectRegistry:BeginFrame(canvas)
    canvas = canvas or self.canvas
    if canvas == nil then
        return
    end
    callOrLog("clear error", function() canvas:Clear() end)
end

--- Removal / lifecycle --------------------------------------------------------------------

function EffectRegistry:_finish(handle)
    if handle.onDone ~= nil then
        callOrLog("onDone error", handle.onDone)
    end
end

function EffectRegistry:_promote(q)
    if q.active == nil and #q.pending > 0 then
        q.active = table.remove(q.pending, 1)
    end
end

-- Snapshot first: Dismiss mutates the stack and queue lists this walk reads.
function EffectRegistry:DismissIf(pred)
    local matches = {}
    local function consider(handle)
        if pred(handle) then
            matches[#matches + 1] = handle
        end
    end
    for _, list in pairs(self.stacks) do
        for _, handle in ipairs(list) do
            consider(handle)
        end
    end
    for _, q in pairs(self.queues) do
        if q.active ~= nil then
            consider(q.active)
        end
        for _, handle in ipairs(q.pending) do
            consider(handle)
        end
    end
    for _, handle in ipairs(matches) do
        self:Dismiss(handle)
    end
end

function EffectRegistry:Dismiss(handle)
    for _, list in pairs(self.stacks) do
        for i, h in ipairs(list) do
            if h == handle then
                table.remove(list, i)
                self:_finish(handle)
                return
            end
        end
    end
    for _, q in pairs(self.queues) do
        if q.active == handle then
            q.active = nil
            self:_finish(handle)
            self:_promote(q)
            return
        end
        for i, h in ipairs(q.pending) do
            if h == handle then
                table.remove(q.pending, i)
                self:_finish(handle)
                return
            end
        end
    end
end

function EffectRegistry:Update(dt)
    for _, list in pairs(self.stacks) do
        local i = 1
        while i <= #list do
            local handle = list[i]
            local ok, alive = callOrLog("update error", handle.update, dt)
            if ok and alive then
                i = i + 1
            else
                table.remove(list, i)
                self:_finish(handle)
            end
        end
    end
    for _, q in pairs(self.queues) do
        if q.active ~= nil then
            local ok, alive = callOrLog("update error", q.active.update, dt)
            if not (ok and alive) then
                local handle = q.active
                q.active = nil
                self:_finish(handle)
                self:_promote(q)
            end
        end
    end
end

function EffectRegistry:Draw(canvas)
    canvas = canvas or self.canvas
    if canvas == nil then
        return
    end
    for _, list in pairs(self.stacks) do
        for _, handle in ipairs(list) do
            callOrLog("draw error", handle.draw, canvas)
        end
    end
    for _, q in pairs(self.queues) do
        if q.active ~= nil then
            callOrLog("draw error", q.active.draw, canvas)
        end
    end
end

-- Teardown wipe: no onDone. Use Dismiss for a graceful per-handle exit.
function EffectRegistry:Clear()
    self.stacks = {}
    self.queues = {}
end

--- Inspection (tests) ----------------------------------------------------------------------

function EffectRegistry:StackCount(owner)
    local list = self.stacks[owner]
    return list ~= nil and #list or 0
end

return EffectRegistry
