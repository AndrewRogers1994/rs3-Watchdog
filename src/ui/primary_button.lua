-- Fit PrettyUI's gold button to its content instead of its wide default endcaps.
local PrimaryButton = {}

function PrimaryButton.fit(button, text)
    local textWidth = math.ceil(config.Font.CINZEL_13PT_BOLD:GetStringWidth(text, false))
    local width = textWidth + 24
    button.root:SetSize(width, 28)
    button.left:SetSize(25, 28)
    button.middle.isTiling = false
    button.middle:SetSize(-50, 28, 1.0)
    button.right:SetSize(25, 28)
    button.label:SetPos(12, 0)
    button.label:SetSize(textWidth, 28)
    return width
end

return PrimaryButton
