-- The Watchdog window. Its Multiplexer swaps the Manager and the Editor.
-- Capture hide, the overlay, and the resize handle stay here.

local Resize = require("src/ui/window_resize")
local Dialog = require("src/ui/dialog")
local Multiplexer = require("src/ui/multiplexer")

---@class Watchdog.ShellOpts
---@field x number|nil
---@field y number|nil
---@field xAnchor number|nil
---@field yAnchor number|nil
---@field width number|nil
---@field height number|nil
---@field minWidth number|nil
---@field minHeight number|nil
---@field scrollable boolean|nil
---@field onShow (fun())|nil
---@field onHide (fun())|nil
---@field window Watchdog.MuxWindow|nil
---@field overlay any|nil
---@field useParentAsRoot boolean|nil

---@class Watchdog.Shell
---@field mux Watchdog.Multiplexer
---@field onShow (fun())|nil
---@field onHide (fun())|nil
---@field window Watchdog.MuxWindow|nil
---@field rootLayer any|nil
---@field resizeHandle any|nil
---@field _overlay any|nil
---@field _visible boolean
---@field _winOpts table
---@field _injected boolean
---@field _ownsRoot boolean
---@field _ownsOverlay boolean
---@field _inCloseCallback boolean
---@field _useParentAsRoot boolean
---@field _hiddenForCapture boolean
---@field _skipOnShow boolean
local Shell = {}
Shell.__index = Shell

---@param self Watchdog.Shell
---@return fun()
local function bindOnClose(self)
    return function()
        if self._inCloseCallback then return end
        self._inCloseCallback = true
        self:SetVisible(false)
        self._inCloseCallback = false
    end
end

-- Window.Close does not hide tooltips parented to the overlay.
---@param ctx any|nil
local function hidePrettyUiTooltipTree(ctx)
    if ctx == nil then return end
    for _, tip in ipairs(ctx.tooltips or {}) do
        pcall(function()
            if tip.Hide ~= nil then tip:Hide() end
        end)
    end
    for _, child in ipairs(ctx.children or {}) do
        hidePrettyUiTooltipTree(child)
    end
end

---@param opts Watchdog.ShellOpts|nil
---@return Watchdog.Shell
function Shell.new(opts)
    opts = opts or {}
    local self = setmetatable({
        onShow = opts.onShow,
        onHide = opts.onHide,
        window = nil,
        rootLayer = nil,
        resizeHandle = nil,
        _overlay = nil,
        _visible = false,
        _winOpts = {
            x = opts.x,
            y = opts.y,
            xAnchor = opts.xAnchor,
            yAnchor = opts.yAnchor,
            width = opts.width,
            height = opts.height,
            minWidth = opts.minWidth,
            minHeight = opts.minHeight,
            scrollable = opts.scrollable == true,
        },
        _injected = false,
        _ownsRoot = false,
        _ownsOverlay = false,
        _inCloseCallback = false,
        _hiddenForCapture = false,
        _skipOnShow = false,
        _useParentAsRoot = opts.useParentAsRoot == true,
        mux = Multiplexer.new(),
    }, Shell)

    if opts.window ~= nil then
        self.window = opts.window
        self._overlay = opts.overlay or {}
        self._injected = true
        self.mux:Bind(self.window)
        if self.window.onClose == nil then
            self.window.onClose = bindOnClose(self)
        end
    end

    return self
end

---@param parent any
---@return Watchdog.Shell
function Shell:Mount(parent)
    if self.window ~= nil then
        return self
    end

    local rootLayer
    if self._useParentAsRoot and parent ~= nil then
        rootLayer = parent
        self._ownsRoot = false
    else
        rootLayer = ui.Layer.new(parent)
        rootLayer:SetPos(0, 0)
        rootLayer:SetSize(0, 0, 1.0, 1.0)
        self._ownsRoot = true
    end
    self.rootLayer = rootLayer

    local winOpts = {
        title = "",
        x = self._winOpts.x,
        y = self._winOpts.y,
        xAnchor = self._winOpts.xAnchor,
        yAnchor = self._winOpts.yAnchor,
        width = self._winOpts.width,
        height = self._winOpts.height,
        minWidth = self._winOpts.minWidth,
        minHeight = self._winOpts.minHeight,
        scrollable = self._winOpts.scrollable,
        destroyOnClose = false,
        onClose = bindOnClose(self),
    }
    self.window = prettyui.Window.new(rootLayer, winOpts)
    self.mux:Bind(self.window)

    local overlay = ui.Layer.new(rootLayer)
    overlay:SetPos(0, 0)
    overlay:SetSize(0, 0, 1.0, 1.0)
    overlay.clickthrough = true
    self._overlay = overlay
    self.resizeHandle = Resize.new(self.window, rootLayer, overlay)
    self._ownsOverlay = true

    if self.window._RegisterOverlay ~= nil then
        pcall(function()
            self.window:_RegisterOverlay(overlay, function()
                return self._visible
            end, nil)
        end)
    end

    self._visible = false
    self.window:Close()
    pcall(function() overlay.hidden = true end)

    return self
end

function Shell:Unmount()
    if self.resizeHandle ~= nil then
        self.resizeHandle:Destroy()
        self.resizeHandle = nil
    end
    self.mux:Clear()

    if self.window ~= nil and self.window.Destroy ~= nil and not self._injected then
        pcall(function() self.window:Destroy() end)
    end
    self.window = nil

    if self._ownsOverlay and self._overlay ~= nil and self._overlay.Destroy ~= nil then
        pcall(function() self._overlay:Destroy() end)
    end
    self._overlay = nil
    self._ownsOverlay = false

    if self._ownsRoot and self.rootLayer ~= nil and self.rootLayer.Destroy ~= nil then
        pcall(function() self.rootLayer:Destroy() end)
    end
    self.rootLayer = nil
    self._ownsRoot = false
    self._visible = false
end

function Shell:Destroy()
    self:Unmount()
    self._injected = false
end

---@return any
function Shell:Content()
    if self.window == nil then return nil end
    return self.window.content
end

---@return Watchdog.MuxWindow|nil
function Shell:Window()
    return self.window
end

---@return any
function Shell:Overlay()
    return self._overlay
end

---@param surface Watchdog.MuxSurface
function Shell:Push(surface)
    self.mux:Push(surface)
end

---@return boolean
function Shell:Pop()
    return self.mux:Pop()
end

---@param id string
---@return boolean
function Shell:PopTo(id)
    return self.mux:PopTo(id)
end

---@return integer
function Shell:Depth()
    return self.mux:Depth()
end

---@return Watchdog.MuxSurface|nil
function Shell:Top()
    return self.mux:Top()
end

---@param id string
---@return boolean
function Shell:IsTop(id)
    return self.mux:IsTop(id)
end

function Shell:SyncTitle()
    self.mux:SyncTitle()
end

---@param v boolean
function Shell:SetVisible(v)
    v = not not v
    if self._visible == v then return end
    self._visible = v

    if self.resizeHandle ~= nil then self.resizeHandle:Sync(v) end
    if v then
        if self._overlay ~= nil then
            pcall(function() self._overlay.hidden = false end)
        end
        if self.window ~= nil and self.window.Show ~= nil then
            self.window:Show()
        end
        self:RaiseToFront()
        self.mux:SetShown(true)
        local skip = self._skipOnShow
        self._skipOnShow = false
        if not skip and self.onShow ~= nil then
            self.onShow()
        end
    else
        self.mux:SetShown(false)
        local top = self.mux:Top()
        if top ~= nil and top.OnShellHide ~= nil then
            pcall(function() top:OnShellHide() end)
        end
        hidePrettyUiTooltipTree(self.window and self.window.tooltipContext)
        if prettyui ~= nil and prettyui.Tooltip ~= nil and prettyui.Tooltip.getContext ~= nil then
            local content = self.window and self.window.content
            if content ~= nil then
                hidePrettyUiTooltipTree(prettyui.Tooltip.getContext(content))
            end
        end
        if self._overlay ~= nil then
            pcall(function() self._overlay.hidden = true end)
        end
        if self.window ~= nil and self.window.Close ~= nil and not self._inCloseCallback then
            self.window:Close()
        end
        if self.onHide ~= nil then
            self.onHide()
        end
    end
end

function Shell:HideForCapture()
    if self._hiddenForCapture or not self._visible then
        return
    end
    self._hiddenForCapture = true
    self:SetVisible(false)
end

function Shell:RestoreFromCapture()
    if not self._hiddenForCapture then
        return
    end
    self._skipOnShow = true
    self._hiddenForCapture = false
    self:SetVisible(true)
    self._skipOnShow = false
end

---@return boolean
function Shell:IsHiddenForCapture()
    return self._hiddenForCapture == true
end

function Shell:Toggle()
    self:SetVisible(not self._visible)
end

---@return boolean
function Shell:IsVisible()
    return self._visible
end

function Shell:RaiseToFront()
    local w = self.window
    if w == nil then return end
    if w.root ~= nil and w.root.MoveToFront ~= nil then
        w.root:MoveToFront()
        if w.titleDrag ~= nil and w.titleDrag.MoveToFront ~= nil then
            w.titleDrag:MoveToFront()
        end
    elseif w.MoveToFront ~= nil then
        w:MoveToFront()
    end
    self:SyncChrome()
end

function Shell:SyncChrome()
    if self.window == nil or not self._visible then return end
    if self._overlay ~= nil and self._overlay.MoveToFront ~= nil then
        self._overlay:MoveToFront()
    end
    local dialogOpen = Dialog.depth(self._overlay) > 0 or Dialog.depth(self.rootLayer) > 0
    if self.resizeHandle ~= nil then self.resizeHandle:Sync(true, not dialogOpen) end
    local top = self.mux:Top()
    if top ~= nil and top.FrontOverlayPopups ~= nil then
        top:FrontOverlayPopups()
    end
    Dialog.front(self.rootLayer)
end

return Shell
