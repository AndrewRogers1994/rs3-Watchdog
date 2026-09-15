-- Confirm dialog: PrettyUI Window + Cancel (neutral) / confirm FancyButtons.

local Confirm = {}

Confirm.DEFAULT_TITLE = "CONFIRM"
Confirm.DEFAULT_CONFIRM_LABEL = "CONFIRM"
Confirm.DEFAULT_CANCEL_LABEL = "CANCEL"
Confirm.DEFAULT_CONFIRM_VARIANT = "positive"
Confirm.DEFAULT_WIDTH = 328
Confirm.DEFAULT_HEIGHT = 150

---@class Watchdog.ConfirmOpts
---@field title string|nil
---@field body string|nil
---@field cancelLabel string|nil
---@field confirmLabel string|nil
---@field confirmVariant string|nil
---@field width integer|nil
---@field height integer|nil
---@field modal boolean|nil  # full-screen input block + dim behind the window
---@field onConfirm fun()|nil
---@field onCancel fun()|nil

---@param opts Watchdog.ConfirmOpts|nil
---@return Watchdog.ConfirmOpts
function Confirm.resolve(opts)
    opts = opts or {}
    return {
        title = opts.title or Confirm.DEFAULT_TITLE,
        body = opts.body or "",
        cancelLabel = opts.cancelLabel or Confirm.DEFAULT_CANCEL_LABEL,
        confirmLabel = opts.confirmLabel or Confirm.DEFAULT_CONFIRM_LABEL,
        confirmVariant = opts.confirmVariant or Confirm.DEFAULT_CONFIRM_VARIANT,
        width = opts.width or Confirm.DEFAULT_WIDTH,
        height = opts.height or Confirm.DEFAULT_HEIGHT,
        modal = opts.modal ~= false,
        onConfirm = opts.onConfirm,
        onCancel = opts.onCancel,
    }
end

---@param parent any
---@return any
local function mountModal(parent)
    local blocker = ui.Layer.new(parent)
    blocker:SetPos(0, 0)
    blocker:SetSize(0, 0, 1.0, 1.0)
    blocker.clickthrough = false
    local dim = ui.Rectangle.new(blocker)
    dim.fill = true
    dim.clickthrough = false
    dim:SetPos(0, 0)
    dim:SetSize(0, 0, 1.0, 1.0)
    dim.colour = Vector4.new(0, 0, 0, 0.4)
    return blocker
end

---@param win any|nil
function Confirm.destroy(win)
    if win == nil then return end
    pcall(function()
        win.onClose = nil
        win:Destroy()
    end)
end

---@param parent any
---@param opts Watchdog.ConfirmOpts|nil
---@return any|nil window
function Confirm.mount(parent, opts)
    if parent == nil or prettyui == nil or prettyui.Window == nil then return nil end
    opts = Confirm.resolve(opts)
    local win
    local closed = false
    local function dismiss()
        if closed then return end
        closed = true
        local w = win
        win = nil
        Confirm.destroy(w)
        if opts.onCancel ~= nil then opts.onCancel() end
    end
    local function confirm()
        if closed then return end
        closed = true
        local w = win
        win = nil
        Confirm.destroy(w)
        if opts.onConfirm ~= nil then opts.onConfirm() end
    end
    local ok = pcall(function()
        local w, h = opts.width, opts.height
        win = prettyui.Window.new(parent, {
            title = opts.title,
            x = -math.floor(w / 2),
            y = -math.floor(h / 2),
            xAnchor = 0.5,
            yAnchor = 0.5,
            width = w,
            height = h,
            minWidth = w,
            minHeight = h,
            maxWidth = w,
            maxHeight = h,
            destroyOnClose = true,
            onClose = function()
                if closed then return end
                closed = true
                win = nil
                if opts.onCancel ~= nil then opts.onCancel() end
            end,
        })
    end)
    if not ok or win == nil then return nil end
    win:AddText(opts.body)
    win:AddFancyButton(opts.cancelLabel, dismiss, {
        variant = "neutral",
        xAnchor = 0,
        yAnchor = 1,
        y = -35,
    })
    local width = prettyui.FancyButton.getSize(opts.confirmLabel)
    win:AddFancyButton(opts.confirmLabel, confirm, {
        variant = opts.confirmVariant,
        xAnchor = 1,
        yAnchor = 1,
        x = -width - 10,
        y = -35,
    })
    if opts.modal then
        pcall(function()
            local modal = mountModal(parent)
            local innerDestroy = win.Destroy
            function win:Destroy()
                pcall(function() modal:Destroy() end)
                innerDestroy(self)
            end
        end)
    end
    win:Show()
    return win
end

return Confirm
