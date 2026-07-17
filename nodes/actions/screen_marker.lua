-- action.screen_marker (#39) — a dismiss-only static screen-space border box on the always-on
-- overlay Canvas (effects.lua, #29): a self-drawn EffectRegistry effect whose `update` reports
-- alive forever (there's no TTL/animation -- Dismiss is the only way out), keyed by the node's
-- own persistent ctx.state table, the same "Stack capped at 1" idempotent-replace idiom as
-- action.screen_flash (re-Show restarts; different nodes stack).
--
-- The rect itself is draw-only, never a typed field: the sole Control on the `rect` pin is the
-- "Draw on screen" capture button (ui/screen_marker_capture.lua, kind == "capture" in
-- ui/node.lua / ui/graph.lua) which writes one {x, y, w, h} param (pixels, no clamp) when the
-- author drags a rectangle on screen; reposition = re-draw, not an edit -- it does not use the
-- composite-control framework (#18) the way coordgrid does. A nil rect (never drawn, or the
-- Control is unset) never fires -- Show is a silent no-op.
--
-- BUILD-VERIFY: the capture overlay's screen-space mouse coordinates (ui/screen_marker_capture.lua)
-- are exercised only through their own pure Rect()/drag-state-machine unit tests here; the real
-- ui.Button ONCLICK/ONRELEASE mount and the AddOutline draw against real client coordinates need
-- in-client confirmation, same disclaimer as #41 InfoBox's own click-capture layer.

local Controls = require("ui/controls")

local ScreenMarker = {}

-- capture (#39): a single value-column box (not composite) showing a "x,y wxh" summary of the
-- captured rect, or "" (falls back to the box's placeholder text) when nothing's been drawn
-- yet -- the "Draw on screen" button itself lives in ui/node.lua's capture-kind box building.
Controls.Register("screen_marker.rect", {
    widget = "capture",
    format = function(value)
        if value == nil then return "" end
        return string.format("%d,%d %dx%d", value.x or 0, value.y or 0, value.w or 0, value.h or 0)
    end,
})

-- Full opaque red: a loud, unmissable default so a never-configured node still visibly draws.
local DEFAULT_COLOR = { r = 255, g = 0, b = 0, a = 255 }
local DEFAULT_THICKNESS = 2

-- Builds the uniform effect handle (effects.lua). `update` never expires on its own -- this is
-- a persistent marker, not an auto-expiring effect -- only Dismiss removes it. `draw` is a
-- single Canvas AddOutline at the captured rect.
function ScreenMarker.BuildHandle(rect, thickness, color)
    local col = color or DEFAULT_COLOR
    local a = (col.a == nil) and 255 or col.a
    return {
        kind = "screen_marker",
        state = {},
        update = function(_dt) return true end,
        draw = function(canvas)
            canvas:AddOutline(rect.x, rect.y, rect.w, rect.h, thickness or DEFAULT_THICKNESS,
                Vector4.new((col.r or 0) / 255, (col.g or 0) / 255, (col.b or 0) / 255, a / 255))
        end,
    }
end

---@param registry LibNodeGraph.Registry
function ScreenMarker.Register(registry, runtime)
    registry:RegisterNodeType("action.screen_marker", {
        category = "action",
        displayName = "Screen Marker",
        pins = {
            { name = "show", kind = "exec", direction = "in", label = "Show" },
            { name = "dismiss", kind = "exec", direction = "in", label = "Dismiss" },
            { name = "rect", kind = "data", direction = "in", dataType = "screen_marker.rect", default = nil },
            { name = "thickness", kind = "data", direction = "in", dataType = "number", default = DEFAULT_THICKNESS },
            { name = "color", kind = "data", direction = "in", dataType = "color", default = DEFAULT_COLOR },
        },
        run = function(ctx)
            ctx.state = ctx.state or {}
            local state = ctx.state

            local function dismiss()
                if state.handle ~= nil then
                    runtime.effects:Dismiss(state.handle)
                    state.handle = nil
                end
            end

            if ctx.exec == "dismiss" then
                dismiss()
                return
            end

            -- Idempotent/Replace: same-node re-fire evicts this node's own still-live handle
            -- first (Stack capped at 1, keyed by this node's own persistent state table);
            -- different nodes each have their own ctx.state, so they stack independently.
            dismiss()

            local rect = ctx:In("rect")
            if rect == nil then
                return -- a never-drawn rect never fires (AC)
            end

            local thickness = ctx:In("thickness") or DEFAULT_THICKNESS
            local color = ctx:In("color") or DEFAULT_COLOR

            local handle = ScreenMarker.BuildHandle(rect, thickness, color)
            state.handle = handle
            runtime.effects:PushStack(state, handle, 1)
        end,
    })
end

return ScreenMarker
