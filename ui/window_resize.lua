local IfaceScale = require("ui/iface_scale")
local Theme = require("ui/theme")

local Resize = {}
Resize.__index = Resize
local GRIP = 20
local MAX = Theme.WINDOW_MAX_BTN
local CLOSE = Theme.WINDOW_CLOSE_RESERVE
local TITLE_H = Theme.WINDOW_HEADER_H

local function gold()
    return Vector4.new(0.86, 0.76, 0.53, 1)
end

local function drawSquare(canvas, x, y, size)
    local c = gold()
    local x2, y2 = x + size, y + size
    canvas:AddLine(x, y, x2, y, 1, c)
    canvas:AddLine(x2, y, x2, y2, 1, c)
    canvas:AddLine(x2, y2, x, y2, 1, c)
    canvas:AddLine(x, y2, x, y, 1, c)
end

function Resize.new(window, viewport, chrome)
    chrome = chrome or viewport
    local self = setmetatable({ window = window, parent = viewport }, Resize)
    self.grip = ui.Layer.new(chrome)
    self.grip.clickthrough = false
    self.label = ui.Canvas.new(self.grip)
    self.label:SetSize(GRIP, GRIP)
    self.label.clickthrough = true
    local gripColor = gold()
    for offset = 0, 10, 5 do
        self.label:AddLine(3 + offset, 17, 17, 3 + offset, 1, gripColor)
    end
    self.maxHit = ui.Layer.new(chrome)
    self.maxHit.clickthrough = false
    self.maxIcon = ui.Canvas.new(self.maxHit)
    self.maxIcon:SetSize(MAX, MAX)
    self.maxIcon.clickthrough = true
    self.maxButton = { root = self.maxHit, content = { content = "Maximize" } }
    function self.maxButton:SetTooltip(options)
        self.tooltipOptions = options
    end
    self.maxHit:Subscribe(ui.Hook.ONCLICK, function()
        self:ToggleMaximize()
        return true
    end)
    self.grip:Subscribe(ui.Hook.ONCLICK, function()
        self:Begin()
        return true
    end)
    self.grip:Subscribe(ui.Hook.ONHOLD, function()
        self:Drag()
        return true
    end)
    self.grip:Subscribe(ui.Hook.ONRELEASE, function()
        self:Finish()
        return true
    end)
    self.grip:Subscribe(ui.Hook.ONDRAGCOMPLETE, function()
        self:Finish()
        return true
    end)
    self:paintMax()
    self:Sync(false)
    return self
end

function Resize:paintMax()
    self.maxIcon:Clear()
    if self.normalBounds ~= nil then
        drawSquare(self.maxIcon, 5, 8, 10)
        drawSquare(self.maxIcon, 9, 5, 10)
    else
        drawSquare(self.maxIcon, 7, 7, 10)
    end
end

function Resize:FitToParent()
    local w, h = self.parent.width, self.parent.height
    if w == nil or h == nil or w <= 0 or h <= 0 then
        return false
    end
    self.window.root:SetPos(0, 0)
    if self.window.root.width ~= w or self.window.root.height ~= h then
        self.window:SetSize(w, h)
    end
    return true
end

function Resize:layoutTitleDrag()
    local root = self.window.root
    local title = self.window.titleDrag
    if title == nil then return end
    title:SetPos(root.x, root.y)
    title:SetSize(root.width - CLOSE - MAX, TITLE_H)
end

function Resize:ToggleMaximize()
    if not self.visible then
        return
    end
    self:Finish()
    local root = self.window.root
    if self.normalBounds ~= nil then
        local b = self.normalBounds
        self.normalBounds = nil
        root:SetPos(b.x, b.y)
        self.window:SetSize(b.width, b.height)
        self.maxButton.content.content = "Maximize"
        self.maxButton:SetTooltip({ text = "Fill the game window" })
    else
        local bounds = { x = root.x, y = root.y, width = root.width, height = root.height }
        if not self:FitToParent() then
            return
        end
        self.normalBounds = bounds
        self.maxButton.content.content = "Restore"
        self.maxButton:SetTooltip({ text = "Restore previous size and position" })
    end
    self:paintMax()
    self:layoutTitleDrag()
    self:Sync(self.visible)
end

function Resize:Begin()
    if not self.visible or self.normalBounds ~= nil then
        return
    end
    local mouse = Mouse.GetPosition()
    if mouse == nil then
        return
    end
    local x, y = IfaceScale.ToInterface(mouse.x, mouse.y)
    self.start = { x = x, y = y, width = self.window.root.width, height = self.window.root.height }
    self.grip:SetPos(0, 0)
    self.grip:SetSize(0, 0, 1.0, 1.0)
    self.label.hidden = true
    self.grip:MoveToFront()
end

function Resize:Drag()
    if self.start == nil then
        return
    end
    local mouse = Mouse.GetPosition()
    if mouse == nil then
        return
    end
    local x, y = IfaceScale.ToInterface(mouse.x, mouse.y)
    self.window:SetSize(self.start.width + x - self.start.x, self.start.height + y - self.start.y)
    self:layoutTitleDrag()
    self.grip:MoveToFront()
end

function Resize:Finish()
    self.start = nil
    self.label.hidden = false
    self:Sync(self.visible)
end

function Resize:Sync(visible)
    self.visible = visible
    self.grip.hidden = not visible or self.normalBounds ~= nil
    self.maxHit.hidden = not visible
    if not visible then
        self.start = nil
        self.label.hidden = false
        if self.maxButton.tooltip ~= nil and self.maxButton.tooltip.Hide ~= nil then
            self.maxButton.tooltip:Hide()
        end
        return
    end
    if self.normalBounds ~= nil then
        self:FitToParent()
    end
    local root = self.window.root
    if self.window.titleDrag ~= nil then
        self.window.titleDrag.hidden = self.normalBounds ~= nil
    end
    self.maxHit:SetPos(root.x + root.width - CLOSE - MAX, root.y + math.floor((TITLE_H - MAX) / 2))
    self.maxHit:SetSize(MAX, MAX)
    self.maxHit:MoveToFront()
    self:layoutTitleDrag()
    if self.start == nil then
        self.grip:SetPos(root.x + root.width - GRIP, root.y + root.height - GRIP)
        self.grip:SetSize(GRIP, GRIP)
    end
    self.grip:MoveToFront()
    local tooltip = self.maxButton.tooltip
    if tooltip ~= nil and tooltip.root ~= nil then
        tooltip.options.x = math.max(6, root.x + root.width - 40 - (tooltip.width or 0))
        tooltip.options.y = root.y + TITLE_H + 3
        if not tooltip.root.hidden then
            tooltip:Show()
        end
    end
end

function Resize:Destroy()
    self.maxHit:Destroy()
    self.grip:Destroy()
end

return Resize
