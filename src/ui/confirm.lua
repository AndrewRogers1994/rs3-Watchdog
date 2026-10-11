-- Confirm dialog: Dialog wrapper with Cancel + confirm actions.
-- Delete copy (title/label/variant/body) is the caller's — Confirm does not know about delete.
-- Titlebar X is onCancel via onDismiss; the Cancel button is onCancel via onClick.

local Dialog = require("src/ui/dialog")

local Confirm = {}

Confirm.DEFAULT_TITLE = "CONFIRM"
Confirm.DEFAULT_CONFIRM_LABEL = "CONFIRM"
Confirm.DEFAULT_CANCEL_LABEL = "CANCEL"
Confirm.DEFAULT_CONFIRM_VARIANT = "positive"
Confirm.DEFAULT_WIDTH = Dialog.DEFAULT_WIDTH
Confirm.DEFAULT_HEIGHT = Dialog.DEFAULT_HEIGHT

---@class Watchdog.ConfirmOpts
---@field title string|nil
---@field body string|nil
---@field cancelLabel string|nil
---@field confirmLabel string|nil
---@field confirmVariant string|nil
---@field width integer|nil
---@field height integer|nil
---@field modal boolean|nil
---@field onConfirm (fun(): boolean|nil)|nil  # true/nil = dismiss; false = stay
---@field onCancel (fun(): boolean|nil)|nil   # X always dismisses; button honors the return

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

-- Lua callbacks return nil by default; pinning Confirm open on that would be a footgun.
---@param result any
---@return boolean
local function shouldClose(result)
    return result ~= false
end

---@param parent any
---@param opts Watchdog.ConfirmOpts|nil
---@return any|nil window
function Confirm.mount(parent, opts)
    opts = Confirm.resolve(opts)
    local body = opts.body
    return Dialog.mount(parent, {
        title = opts.title,
        width = opts.width,
        height = opts.height,
        modal = opts.modal,
        onDismiss = function()
            if opts.onCancel ~= nil then opts.onCancel() end
        end,
        content = function(win)
            win:AddText(body)
        end,
        actions = {
            {
                label = opts.cancelLabel,
                variant = "neutral",
                onClick = function()
                    if opts.onCancel == nil then return true end
                    return shouldClose(opts.onCancel())
                end,
            },
            {
                label = opts.confirmLabel,
                variant = opts.confirmVariant,
                onClick = function()
                    if opts.onConfirm == nil then return true end
                    return shouldClose(opts.onConfirm())
                end,
            },
        },
    })
end

return Confirm
