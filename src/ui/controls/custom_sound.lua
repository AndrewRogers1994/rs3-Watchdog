local Inline = require("src/ui/controls/inline")
local Dropdown = require("src/ui/widgets/dropdown")
local Packs = require("src/packs")
local PackRows = require("src/pack_rows")
local Controls = require("src/ui/controls")
local ControlKinds = require("src/ui/control_kinds")

-- Custom Sound's resource pin. Layout, closed text, and the open list live
-- here. The node registers the type and calls install.

local CustomSound = {}

--- Plugin audio file names, including a file named None. The row builder
--- drops that name and sorts the rest. Order past this list is the Pack registry.
---@return string[]
local function watchdogFileNames()
    local names = {}
    if Plugin ~= nil and Plugin.resources ~= nil and Plugin.resources.audio ~= nil then
        pcall(function()
            for name, _ in pairs(Plugin.resources.audio) do
                names[#names + 1] = name
            end
        end)
    end
    return names
end

--- None, then each Watchdog audio file name, then each pack audio file.
--- Called when the list is shown, not when the control is registered.
---@return Watchdog.AudioChoiceRow[]
function CustomSound.Choices()
    return PackRows.OpenAudioChoices(Packs.live() or Packs.new(), watchdogFileNames(), nil):Rows()
end

---@param box { x: number, y: number, w: number, h: number }
---@return table[]
function CustomSound.Layout(box)
    return { { kind = "field", x = box.x, y = box.y, w = box.w, h = box.h } }
end

---@param ctrl table
---@return string
function CustomSound.Display(ctrl)
    return PackRows.AudioClosedLabel(Packs.live() or Packs.new(), ctrl.value)
end

--- The open list is the row set captured here. The native combo sorts those
--- labels alphabetically; selection is by label text. The combo's own text
--- box narrows the rows; this does not define a match.
---@param host ControlHost
---@param ctrl table
function CustomSound.Press(host, ctrl)
    local list = PackRows.OpenAudioChoices(Packs.live() or Packs.new(), watchdogFileNames(), ctrl.value)
    local rows = list:Rows()
    local labels = {}
    for i, row in ipairs(rows) do
        labels[i] = row.label
    end
    host:MountDropdown(ctrl, {
        labels = labels,
        initial = list:HighlightedLabel(),
    }, function(label)
        local value, found = list:Commit(label)
        if found then host:Commit(value) end
    end)
end

---@param canvas any
---@param rect { x: number, y: number, w: number, h: number }
---@param ctrl table
---@param dctx DrawContext
function CustomSound.Draw(canvas, rect, ctrl, dctx)
    Dropdown:Draw(canvas, rect, ctrl, dctx)
end

--- Registers the pin control. Choices stay a function so the Variable dialog
--- reads the registry that is live when it opens, not the empty one at load.
---@return nil
function CustomSound.install()
    Controls.RegisterPinControl("customSoundResource", CustomSound)
    ControlKinds.Record("customSoundResource", "enum", CustomSound.Choices)
end

Inline.apply(CustomSound)

return CustomSound
