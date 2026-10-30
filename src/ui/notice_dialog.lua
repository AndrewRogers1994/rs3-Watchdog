-- What's new and Getting started. X and Close both record the ids in the dialog.

local Dialog = require("src/ui/dialog")
local EditorTips = require("src/ui/editor_tips")
local ReleaseNoteBody = require("src/ui/release_note_body")

local NoticeDialog = {}

local STRIPES = { 0x24211EFF, 0x2E2825FF }
local FOOTER_CLEARANCE = 24
-- Wide enough for a release screenshot. Borders are 8, flow padding is 14,
-- and the collapse body is indented 20, so a 640 dialog leaves 576 for the
-- picture when the section width is not resolved yet.
local WHATS_NEW_WIDTH = 640
local WHATS_NEW_HEIGHT = 580
local IMAGE_FALLBACK_WIDTH = 576

---@param parent any
---@param opts { title: string, width: integer, height: integer, rowBackgroundColours: integer[]|nil, content: fun(win: any) }
---@param onSeen fun()
---@return any|nil
local function mount(parent, opts, onSeen)
    return Dialog.mount(parent, {
        title = opts.title,
        width = opts.width,
        height = opts.height,
        rowBackgroundColours = opts.rowBackgroundColours,
        content = opts.content,
        onDismiss = onSeen,
        actions = {
            {
                label = "Close",
                onClick = function()
                    onSeen()
                    return true
                end,
            },
        },
    })
end

---@return any
local function pluginImages()
    if Plugin == nil or Plugin.resources == nil then return nil end
    return Plugin.resources.images
end

---@param win any
---@param entries Watchdog.ReleaseNoteView[]
local function fillWhatsNew(win, entries)
    local images = pluginImages()
    for i, entry in ipairs(entries) do
        local block = win:AddCollapseButton(entry.version, { expanded = i == 1 })
        local available = ReleaseNoteBody.availableWidth(block, IMAGE_FALLBACK_WIDTH)
        local plan = ReleaseNoteBody.plan(entry.paragraphs, images, available)
        for _, item in ipairs(plan) do
            if item.kind == "text" then
                block:AddText(item.text)
            elseif item.kind == "title" then
                ReleaseNoteBody.mountTitle(block, item.text)
            else
                ReleaseNoteBody.mountImage(block, item.resource, item.width, item.height)
            end
        end
    end
    win:AddText({ text = "", height = FOOTER_CLEARANCE, rowBackground = false })
    win:RefreshRowBackgrounds()
end

---@param parent any
---@param entries Watchdog.ReleaseNoteView[]
---@param onSeen fun()
---@return any|nil
function NoticeDialog.mountWhatsNew(parent, entries, onSeen)
    return mount(parent, {
        title = "What's new",
        width = WHATS_NEW_WIDTH,
        height = WHATS_NEW_HEIGHT,
        rowBackgroundColours = STRIPES,
        content = function(win)
            fillWhatsNew(win, entries)
        end,
    }, onSeen)
end

---@param parent any
---@param onSeen fun()
---@return any|nil
function NoticeDialog.mountGettingStarted(parent, onSeen)
    return mount(parent, {
        title = "Getting started",
        width = 480,
        height = 280,
        content = function(win)
            EditorTips.fill(win)
        end,
    }, onSeen)
end

return NoticeDialog
