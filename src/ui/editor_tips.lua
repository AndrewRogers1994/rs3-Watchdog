-- First visit to the editor. The info button still opens the Tutorial.
-- The client draws a newline as a missing-glyph box, so each paragraph is its own AddText.

local EditorTips = {}

EditorTips.paragraphs = {
    "An alert is a trigger wired to an action.",
    "Double-click empty space, or click +, to add a node.",
    "The alert runs only while it is enabled in the alert list.",
    "The info button opens the full Tutorial.",
}

-- Close is anchored over the bottom of the scrolling page.
local FOOTER_CLEARANCE = 24

---@param win any
function EditorTips.fill(win)
    for _, paragraph in ipairs(EditorTips.paragraphs) do
        win:AddText(paragraph)
    end
    win:AddText({ text = "", height = FOOTER_CLEARANCE, rowBackground = false })
    win:RefreshRowBackgrounds()
end

return EditorTips
