-- infobox.lua — the `action.infobox` node (#41): one tile in the shared InfoBox Area
-- (ui/infobox.lua) on the always-on overlay Canvas (#29). Reached via `runtime.infobox`
-- (owned by runtime.lua), mirroring how action.popup reaches `runtime.effects` — the node
-- itself never touches the Canvas or the area's layout math, only the ordered Set/Remove API.
--
-- Two exec-in pins, no exec-out (#3's "second exec pin" dismiss idiom, same family as the
-- persistent Overlay/Screen Marker/Object Marker siblings): `update` lazy-creates the tile on
-- first pulse then pulls `value`/`color`/`icon`/`title` and rewrites it in place; `dismiss`
-- removes it. The shared area keys a tile by the node's own id (InfoBox.lua's `owner`), so
-- dismissal needs no stashed runtime handle the way a stacked effect would — Remove(ctx.nodeId)
-- is idempotent regardless of how many times `update` fired first.
--
-- Which exec-in pin fired is read off `ctx.exec` (falling back to "update" when absent, so a
-- single-exec-in-shaped ctx still lazy-creates/refreshes the tile), and the node's own id off
-- `ctx.nodeId` — both provided by LibNodeGraph's run ctx (see LibNodeGraph/graph.lua).

local InfoBox = require("ui/infobox")

local Node = {}

-- A hand-picked subset of the #20 research's icon table (ids are High-confidence *icons*),
-- reusing the enum Control the same way action.popup's `icon`/`theme` dropdowns do. "None"
-- (value nil) draws no icon — a text-only tile.
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
    -- Registers the curated icon dropdown's Control Spec (ADR-0004's enum widget), the same
    -- seam action.popup uses for its own icon/theme dropdowns. Guarded so a headless require
    -- of this module (no ui layer wanted, e.g. a future standalone node test) still registers
    -- the node type itself.
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
            -- Unconnected -> the #19 RGBA picker swatch control; unset/nil = default white,
            -- the tile still draws (a deliberate divergence from the coordgrid/color "nil
            -- never fires" rule — color here is cosmetic, not a required target).
            { name = "color", kind = "data", direction = "in", dataType = "color", default = nil },
            -- Config controls (not meant to be wired): icon dropdown, title tooltip text,
            -- dismissWhenEmpty toggle. Data-input pins are this engine's only per-node config
            -- store (ADR-0004), same as action.popup's title/icon/theme/hold.
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

            -- "update" (also the fallback when the firing pin can't be told apart — e.g. a
            -- single-exec-in-shaped ctx with ctx.exec nil): pull value/color/icon/title and
            -- rewrite the tile.
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
