local InfoBox = require("ui/infobox")

local Node = {}

Node.ICONS = {
    { value = nil,   label = "None" },
    { value = 17127, label = "Checkmark" },      -- id.Sprite.RS3_ICON_CHECK_MARK_24PX_0
    { value = 12764, label = "Star" },           -- id.Sprite.ICON_STAR_FILL
    { value = 431,   label = "Coins" },          -- id.Sprite.COINS
    { value = 937,   label = "Exclamation" },    -- id.Sprite.EXCLAMATION_MARK
    { value = 15064, label = "Collection Log" }, -- id.Sprite.RS3_ICON_BOSS_COLLECTION_LOG_0
    { value = 6953,  label = "Quest" },          -- id.Sprite.ICON_RIBBON_QUESTS_INACTIVE
    { value = 24773, label = "Hitpoints" },      -- id.Sprite.RS3_ICON_SKILL_HITPOINTS_24PX
    { value = 24776, label = "Prayer" },         -- id.Sprite.RS3_ICON_SKILL_PRAYER_24PX
}

function Node.IconChoices()
    return Node.ICONS
end

---@param registry LibNodeGraph.Registry
---@param runtime Watchdog.Runtime
function Node.Register(registry, runtime)
    pcall(function()
        local Controls = require("ui/controls")
        Controls.Register("infobox.icon", { widget = "enum", choices = Node.IconChoices() })
    end)

    registry:RegisterNodeType("action.infobox", {
        category = "action",
        displayName = "InfoBox",
        pins = {
            { name = "update", kind = "exec", direction = "in" },
            { name = "dismiss", kind = "exec", direction = "in" },
            { name = "value", kind = "data", direction = "in", dataType = "any" },
            { name = "color", kind = "data", direction = "in", dataType = "color", default = nil },
            { name = "icon", kind = "data", direction = "in", dataType = "infobox.icon", default = nil },
            { name = "title", kind = "data", direction = "in", dataType = "string", default = "" },
            { name = "dismissWhenEmpty", kind = "data", direction = "in", dataType = "bool", default = false },
        },
        run = function(ctx)
            local area = runtime ~= nil and runtime.infobox or nil
            if area == nil then
                return
            end
            local owner = ctx.nodeId

            if ctx.exec == "dismiss" then
                area:Remove(owner)
                return
            end

            local value = ctx:In("value")
            if ctx:In("dismissWhenEmpty") and InfoBox.IsEmpty(value) then
                area:Remove(owner)
                return
            end
            area:Set(owner, {
                text = InfoBox.ResolveText(value),
                color = ctx:In("color"),
                icon = ctx:In("icon"),
                title = ctx:In("title"),
            })
        end,
    })
end

return Node
