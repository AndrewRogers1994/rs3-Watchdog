-- A stack of surfaces in a window it is given. Only the top surface is visible.
-- The shell owns the window (ADR 0020).

---@class Watchdog.MuxSurface
---@field id string                         # stable id for debugging / IsTop
---@field title string|fun():string         # window title while this surface is top
---@field SetVisible fun(self, v: boolean)
---@field OnPop fun(self)|nil               # pop dropped this surface; root omits it
---@field OnShellHide fun(self)|nil         # optional: shell tucked (F8/Close); stack kept
---@field FrontOverlayPopups fun(self)|nil

---@class Watchdog.MuxWindow
---@field content any
---@field Show fun(self)
---@field Close fun(self)
---@field SetTitle fun(self, title: string)
---@field Destroy fun(self)
---@field MoveToFront fun(self)|nil
---@field root any|nil
---@field titleDrag any|nil
---@field onClose (fun(self: Watchdog.MuxWindow))|nil
---@field _RegisterOverlay fun(self, component: any, isVisible: (fun(): boolean)|nil, layout: (fun())|nil)|nil
---@field title string|nil
---@field tooltipContext any|nil
---@field shown boolean|nil
---@field closeCount integer|nil
---@field showCount integer|nil
---@field destroyCount integer|nil
---@field raiseCount integer|nil

---@class Watchdog.Multiplexer
---@field window Watchdog.MuxWindow|nil
---@field _stack Watchdog.MuxSurface[]
---@field _shown boolean                   # host window is up; shell hide clears this without hiding surfaces
local Multiplexer = {}
Multiplexer.__index = Multiplexer

---@param window Watchdog.MuxWindow|nil
---@return Watchdog.Multiplexer
function Multiplexer.new(window)
    return setmetatable({
        window = window,
        _stack = {},
        _shown = false,
    }, Multiplexer)
end

---@param window Watchdog.MuxWindow|nil
function Multiplexer:Bind(window)
    self.window = window
end

---@return Watchdog.MuxWindow|nil
function Multiplexer:Window()
    return self.window
end

---@param surface Watchdog.MuxSurface|nil
---@return string
local function resolveTitle(surface)
    if surface == nil then return "" end
    local title = surface.title
    if type(title) == "function" then
        local result = title()
        if result ~= nil then return tostring(result) end
        return ""
    end
    if title == nil then return "" end
    return tostring(title)
end

---@param self Watchdog.Multiplexer
local function applyTitle(self)
    local top = self._stack[#self._stack]
    if self.window == nil or self.window.SetTitle == nil then return end
    self.window:SetTitle(resolveTitle(top))
end

---@param self Watchdog.Multiplexer
---@param showTop boolean
local function applySurfaceVisibility(self, showTop)
    local top = self._stack[#self._stack]
    for i = 1, #self._stack do
        local surface = self._stack[i]
        local want = showTop and surface == top
        if surface ~= nil and surface.SetVisible ~= nil then
            surface:SetVisible(want)
        end
    end
end

-- Closing the window does not hide surfaces. Pan, zoom, and a hidden field stay.
---@param v boolean
function Multiplexer:SetShown(v)
    v = not not v
    if self._shown == v then return end
    self._shown = v
    if v then
        applySurfaceVisibility(self, true)
        applyTitle(self)
    end
end

---@return boolean
function Multiplexer:IsShown()
    return self._shown
end

---@param surface Watchdog.MuxSurface
function Multiplexer:Push(surface)
    if surface == nil then return end
    local prev = self._stack[#self._stack]
    if prev ~= nil and prev.SetVisible ~= nil then
        prev:SetVisible(false)
    end
    self._stack[#self._stack + 1] = surface
    if surface.SetVisible ~= nil then
        surface:SetVisible(self._shown)
    end
    applyTitle(self)
end

---@return boolean  # false when already at root (depth <= 1); root stays
function Multiplexer:Pop()
    if #self._stack <= 1 then return false end
    local top = table.remove(self._stack)
    if top ~= nil and top.SetVisible ~= nil then
        top:SetVisible(false)
    end
    if top ~= nil and top.OnPop ~= nil then
        top:OnPop()
    end
    local prev = self._stack[#self._stack]
    if self._shown and prev ~= nil and prev.SetVisible ~= nil then
        prev:SetVisible(true)
    end
    applyTitle(self)
    return true
end

---@param id string
---@return boolean  # true if `id` is now top
function Multiplexer:PopTo(id)
    while #self._stack > 1 do
        local top = self._stack[#self._stack]
        if top ~= nil and top.id == id then break end
        if not self:Pop() then break end
    end
    return self:IsTop(id)
end

---@return integer
function Multiplexer:Depth()
    return #self._stack
end

---@return Watchdog.MuxSurface|nil
function Multiplexer:Top()
    return self._stack[#self._stack]
end

---@param id string
---@return boolean
function Multiplexer:IsTop(id)
    local top = self._stack[#self._stack]
    return top ~= nil and top.id == id
end

function Multiplexer:SyncTitle()
    applyTitle(self)
end

-- Hide surfaces and drop the stack. Do not OnPop: destroying each surface
-- first frees SpriteButtons ahead of their parent.
function Multiplexer:Clear()
    for i = #self._stack, 1, -1 do
        local surface = self._stack[i]
        if surface ~= nil and surface.SetVisible ~= nil then
            pcall(function() surface:SetVisible(false) end)
        end
    end
    self._stack = {}
    self.window = nil
    self._shown = false
end

return Multiplexer
