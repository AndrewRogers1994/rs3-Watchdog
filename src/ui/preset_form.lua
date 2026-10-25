-- The form scrolls inside a SimpleView. Dialog itself is unchanged; the window's own
-- scrollbar is turned off so Cancel and Save stay on screen.

local PresetForm = {}

local DIALOG_WIDTH = 460
PresetForm.DIALOG_WIDTH = DIALOG_WIDTH
local MIN_DIALOG_H = 220
-- PrettyUI window content starts under the 32px title and above the 8px border.
local CHROME_H = 40
-- Footer buttons sit on the window, 35px up from the bottom (Dialog.ACTION_Y).
local FOOTER_H = 48

---@param parent any
---@param estimate number
---@return number
function PresetForm.dialogHeight(parent, estimate)
    local maxH = 640
    local parentH = parent and parent.height
    if type(parentH) == "number" and parentH > 80 then
        maxH = math.max(MIN_DIALOG_H, parentH - 80)
    end
    local height = estimate
    if type(height) ~= "number" or height < MIN_DIALOG_H then height = MIN_DIALOG_H end
    if height > maxH then height = maxH end
    return height
end

-- The window stays a fixed size so the footer does not scroll away. The form
-- lives in a SimpleView that scrolls only when the marks or variables overflow.
---@param win any
---@param height number
---@return any|nil
function PresetForm.scrollBody(win, height)
    if win ~= nil and win.SetScrollable ~= nil then
        win:SetScrollable(false)
    end
    if prettyui == nil or prettyui.SimpleView == nil or win == nil or win.content == nil then
        if log ~= nil then log("Watchdog: prettyui.SimpleView unavailable, preset dialog body aborted") end
        return nil
    end
    local width = DIALOG_WIDTH - 16
    local contentW = win.content.width
    if type(contentW) == "number" and contentW > 0 then width = contentW end
    local bodyH = math.max(80, height - CHROME_H - FOOTER_H)
    local view
    local ok, err = pcall(function()
        view = prettyui.SimpleView.new(win.content, {
            x = 0,
            y = 0,
            width = width,
            height = bodyH,
        })
    end)
    if not ok or view == nil then
        if log ~= nil then
            log("Watchdog: preset dialog scroll body failed - " .. tostring(err))
        end
        return nil
    end
    return view
end

return PresetForm
