-- What's new and Getting started. X and Close both record the ids in the dialog.

local Dialog = require("src/ui/dialog")
local EditorTips = require("src/ui/editor_tips")

local NoticeDialog = {}

local STRIPES = { 0x24211EFF, 0x2E2825FF }
local FOOTER_CLEARANCE = 24

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

---@param win any
---@param entries Watchdog.ReleaseNoteView[]
local function fillWhatsNew(win, entries)
    for i, entry in ipairs(entries) do
        local block = win:AddCollapseButton(entry.version, { expanded = i == 1 })
        for _, paragraph in ipairs(entry.paragraphs) do
            block:AddText(paragraph)
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
        width = 480,
        height = 420,
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
