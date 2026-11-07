-- First visit to the editor. The info button still opens the Tutorial.
-- Keep each text paragraph in its own AddText; newlines draw as missing-glyph boxes.

local EditorTips = {}

EditorTips.paragraphs = {
    { title = "How Alerts work" },
    "A trigger watches the game. An action does something you can see or hear. Connect them to make an alert.",
    { title = "Build your first Alert" },
    "Double-click empty space, or click +, to add a trigger and an action. Connect their white triangle pins, from the trigger's right side to the action's left side.",
    { title = "Try it out" },
    "Click the green play button beside the action's input to preview it. Keep your alert enabled in the alert list so it can respond while you play.",
    "Need help? The info button in the top right opens the Tutorial.",
}

-- Close is anchored over the bottom of the scrolling page.
local FOOTER_CLEARANCE = 24

---@param win any
function EditorTips.fill(win)
    for _, paragraph in ipairs(EditorTips.paragraphs) do
        if type(paragraph) == "string" then
            win:AddText(paragraph)
        else
            win:AddTitle(paragraph.title)
        end
    end
    win:AddText({ text = "", height = FOOTER_CLEARANCE, rowBackground = false })
    win:RefreshRowBackgrounds()
end

return EditorTips
