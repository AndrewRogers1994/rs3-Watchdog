local Controls = require("ui/controls")

local ScreenMarker = {}

local DEFAULT_TTL_SECONDS = 5.0
ScreenMarker.DEFAULT_TTL_SECONDS = DEFAULT_TTL_SECONDS

Controls.Register("screen_marker.rect", {
    widget = "capture",
    format = function(value)
        if value == nil then return "" end
        return string.format("%d,%d %dx%d", value.x or 0, value.y or 0, value.w or 0, value.h or 0)
    end,
})

local DEFAULT_COLOR = { r = 255, g = 0, b = 0, a = 255 }
local DEFAULT_THICKNESS = 2

---@param rect { x: number, y: number, w: number, h: number }
---@param thickness number|nil
---@param color { r: integer, g: integer, b: integer, a: integer|nil }|nil
---@param opts { sticky: boolean|nil, ttl: number|nil }|nil
function ScreenMarker.BuildHandle(rect, thickness, color, opts)
    opts = opts or {}
    local sticky = opts.sticky and true or false
    local ttl = opts.ttl
    if type(ttl) ~= "number" then ttl = DEFAULT_TTL_SECONDS end
    local elapsed = 0
    local col = color or DEFAULT_COLOR
    local a = (col.a == nil) and 255 or col.a
    return {
        kind = "screen_marker",
        state = {},
        update = function(dt)
            elapsed = elapsed + (tonumber(dt) or 0)
            return sticky or elapsed < ttl
        end,
        draw = function(canvas)
            canvas:AddOutline(rect.x, rect.y, rect.w, rect.h, thickness or DEFAULT_THICKNESS,
                Vector4.new((col.r or 0) / 255, (col.g or 0) / 255, (col.b or 0) / 255, a / 255))
        end,
    }
end

---@param registry LibNodeGraph.Registry
---@param runtime Watchdog.Runtime
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
            { name = "sticky", kind = "data", direction = "in", dataType = "bool", default = false },
            { name = "hold", kind = "data", direction = "in", dataType = "number",
              default = DEFAULT_TTL_SECONDS },
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
            local hold = ctx:In("hold")
            if type(hold) ~= "number" then hold = DEFAULT_TTL_SECONDS end

            local handle = ScreenMarker.BuildHandle(rect, thickness, color, {
                sticky = ctx:In("sticky"),
                ttl = hold,
            })
            state.handle = handle
            runtime.effects:PushStack(state, handle, 1)
        end,
    })
end

return ScreenMarker
