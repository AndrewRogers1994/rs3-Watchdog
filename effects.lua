-- effects.lua — EffectRegistry: the shared substrate every self-drawn on-screen effect node
-- (Overlay, Screen Flash, Popup, Screen/Object Marker, InfoBox) draws onto. Owns its own
-- always-on full-screen overlay Canvas, mounted on root and separate from the editor's own
-- window Canvas, so effects keep drawing while the editor Window is closed.
--
-- Uniform effect handle: `{ kind, state, update(dt) -> alive, draw(canvas), onDone }`. TTL
-- and animation fold into `update`; there are no bounds and no ids — dismissal is by direct
-- handle reference. In-memory only, never serialized (persistence rides each effect node's
-- own params instead). Reached via `runtime.effects` (see runtime.lua); advanced on Logic,
-- drawn on Draw; `Clear()` empties it on Stop.
--
-- Two concurrency policies, picked per owner key by the caller:
--   Stack — up to `max` concurrent handles live at once (nil max = unbounded); pushing past
--           `max` evicts the oldest. Every live handle advances and draws every frame.
--   Queue — at most one handle per owner is ever live; the rest wait. When the live handle
--           leaves the live set (expires or is dismissed), the next pending handle is
--           promoted automatically.
-- In both cases, "leaving the live set" (natural expiry via update() returning falsy, or an
-- explicit Dismiss) fires the handle's onDone. Clear() is a silent teardown wipe — no onDone.

local Util = require("util")

-- A bad node-authored update/draw/onDone can't be allowed to break every other live effect.
-- See util.lua.
local function callOrLog(context, fn, ...)
    return Util.CallOrLog("effects", context, fn, ...)
end

local EffectRegistry = {}

function EffectRegistry.new()
    EffectRegistry.__index = EffectRegistry
    return setmetatable({
        canvas = nil,
        stacks = {}, -- owner -> { handle, ... }, oldest first
        queues = {}, -- owner -> { active = handle|nil, pending = { handle, ... } }
    }, EffectRegistry)
end

--- Canvas mount (client-only; untested under the standalone Lua test harness) -------------

-- Mounts the always-on full-screen overlay Canvas as a direct child of `rootParent` (the
-- same client root the editor Window mounts under — see main.lua's getRootParent), sized to
-- always fill it (0,0 + 100% parent dimensions) so it tracks window resizes without needing
-- to poll screen size. Idempotent: a second Mount before Unmount is a no-op.
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
        log("Watchdog effects: Mount failed — " .. tostring(canvas))
    end
end

function EffectRegistry:IsMounted()
    return self.canvas ~= nil
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

-- Adds `handle` to `owner`'s Stack. If `max` is given and pushing puts the stack over it,
-- the oldest handle(s) are evicted (removed + onDone), same as any other departure.
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

-- Adds `handle` to `owner`'s Queue. Becomes the live/active handle immediately if the queue
-- is empty; otherwise waits pending until the current active handle leaves the live set.
function EffectRegistry:PushQueue(owner, handle)
    local q = self:_queueFor(owner)
    if q.active == nil then
        q.active = handle
    else
        q.pending[#q.pending + 1] = handle
    end
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

-- Removes `handle` from wherever it currently lives — a Stack list, or a Queue's active slot
-- or pending list — matched by direct reference (no ids/bounds, per the uniform handle
-- contract). Fires onDone and, if the handle was a Queue's active slot, promotes the next
-- pending handle. No-op if `handle` isn't currently live anywhere.
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

-- Advances every live handle by `dt` (called once per Logic tick — see runtime.lua). A
-- handle whose update() returns falsy (or errors) has left the live set: it's removed,
-- onDone fires, and — for a Queue — the next pending handle is promoted.
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

-- Draws every live handle (every Stack member, plus each Queue's active handle only —
-- pending handles never draw). `canvas` defaults to the mounted overlay Canvas so callers in
-- tests can pass a fake one without mounting.
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

-- Empties every Stack and Queue with no onDone callbacks — a teardown wipe (Stop), not a
-- graceful per-handle dismissal.
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
