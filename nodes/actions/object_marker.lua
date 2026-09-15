local Theme = require("ui/theme")

-- A drawn/effect spec: the captured object plus the node's presentation controls. Shared by
-- DrawTile and BuildHandle so the draw and the handle can't disagree on what they render.
---@class Watchdog.ObjectMarker.Spec
---@field object Watchdog.ObjectMarker.Object|nil
---@field mode { tile: boolean|nil }|nil
---@field color { r: integer, g: integer, b: integer, a: integer|nil }|nil
---@field width number|nil
---@field showLabel boolean|nil
---@field sticky boolean|nil
---@field ttl number|nil

local ObjectMarker = {}

-- Defaults: a bright cyan outline (loud + unmissable on the world like Screen Marker's red),
-- a 5s TTL matching the Overlay idiom, and Tile the only enabled mode.
local DEFAULT_COLOR = { r = 0, g = 255, b = 255, a = 255 }
local DEFAULT_WIDTH = 2
local DEFAULT_TTL_SECONDS = 5.0
ObjectMarker.DEFAULT_TTL_SECONDS = DEFAULT_TTL_SECONDS

-- Tile on by default so a freshly-captured node visibly draws without touching the mode control.
local DEFAULT_MODE = { tile = true }
ObjectMarker.DEFAULT_MODE = DEFAULT_MODE

-- The 4 modes, in display order. `enabled = false` rows are the unavailable-node idiom: shown but
-- inert, with the `reason` blurb. Only Tile is feasible (no LocEntity/render geometry in the API).
ObjectMarker.MODES = {
    { key = "tile",     label = "Tile",     enabled = true },
    { key = "hull",     label = "Hull",     enabled = false, reason = "needs render API" },
    { key = "outline",  label = "Outline",  enabled = false, reason = "needs render API" },
    { key = "clickbox", label = "Clickbox", enabled = false, reason = "needs render API" },
}

-- Fine units per grid tile - a tile spans 512 fine units on each axis (see CoordFine docs / the
-- DevTools overlay corner offsets).
local TILE_FINE = 512

--- Pure tile-corner projection -------------------------------------------------------------

-- The four corners of the tile at `coord` ({ x, z, level } grid), in screen space, via the injected
-- `project(level, fineX, fineZ) -> { x, y } | nil`. Corners walk the tile CCW from its base fine
-- origin, adding {0,0},{512,0},{512,512},{0,512}. Returns nil if `coord` is nil OR any single
-- corner is unavailable (off-screen / world not loaded) - a partial outline is never drawn (AC:
-- nil / !IsAvailable -> nothing, no clamp).
---@param coord { x: integer, z: integer, level: integer|nil }|nil  # the marked tile (grid units)
---@param project fun(level: integer, fineX: number, fineZ: number): { x: number, y: number }|nil
---@return { x: number, y: number }[]|nil  # 4 screen-space corners, or nil if any is unavailable
function ObjectMarker.TileCorners(coord, project)
    if type(coord) ~= "table" or coord.x == nil or coord.z == nil then
        return nil
    end
    local level = coord.level or 0
    local baseX, baseZ = coord.x * TILE_FINE, coord.z * TILE_FINE
    local offsets = { { 0, 0 }, { TILE_FINE, 0 }, { TILE_FINE, TILE_FINE }, { 0, TILE_FINE } }
    local corners = {}
    for _, o in ipairs(offsets) do
        local p = project(level, baseX + o[1], baseZ + o[2])
        if p == nil or p.x == nil or p.y == nil then
            return nil
        end
        corners[#corners + 1] = { x = p.x, y = p.y }
    end
    return corners
end

-- The live projector: grid-fine -> CoordFine -> ScreenConvert.CoordFineToScreen, each step guarded
-- (client globals may be momentarily unavailable) so a failure surfaces as nil -> "draw nothing"
-- rather than an error. Mirrors DevTools overlay.lua's newCoordFine/fineToScreen.
local function defaultProject(level, fineX, fineZ)
    if CoordFine == nil or ScreenConvert == nil then
        return nil
    end
    local ok, screen = pcall(function()
        local fine = CoordFine.new(level, fineX, fineZ)
        return ScreenConvert.CoordFineToScreen(fine, 0)
    end)
    if ok and screen ~= nil and screen.x ~= nil and screen.y ~= nil then
        return { x = screen.x, y = screen.y }
    end
    return nil
end

--- Draw (re-projected every frame) ---------------------------------------------------------

local function vec4(color)
    local c = color or DEFAULT_COLOR
    local a = (c.a == nil) and 255 or c.a
    return Vector4.new((c.r or 0) / 255, (c.g or 0) / 255, (c.b or 0) / 255, a / 255)
end

-- Whether Tile mode is on. Default (nil mode) is on, so a fresh node draws; explicit `tile = false`
-- turns the only feasible representation off (nothing drawn).
local function tileOn(mode)
    return mode == nil or mode.tile ~= false
end

-- Draws the tile outline (and optional name label) for `spec` onto `canvas`, projecting through
-- `project` (defaults to the live CoordFine/ScreenConvert chain). A no-op when Tile mode is off,
-- the object has no coord, or the projection is unavailable. `project` is injectable for tests.
---@param spec Watchdog.ObjectMarker.Spec
function ObjectMarker.DrawTile(canvas, spec, project)
    project = project or defaultProject
    if canvas == nil or Vector4 == nil then
        return
    end
    local object = spec.object
    if type(object) ~= "table" or not tileOn(spec.mode) then
        return
    end
    local corners = ObjectMarker.TileCorners(object.coordGrid, project)
    if corners == nil then
        return
    end
    local width = spec.width or DEFAULT_WIDTH
    local color = vec4(spec.color)
    for i = 1, 4 do
        local a = corners[i]
        local b = corners[(i % 4) + 1]
        canvas:AddLine(a.x, a.y, b.x, b.y, width, color)
    end

    -- Name label above the topmost (min screen-y) corner, when enabled and named.
    if spec.showLabel and object.name ~= nil and object.name ~= "" and canvas.AddText ~= nil then
        local top = corners[1]
        for _, c in ipairs(corners) do
            if c.y < top.y then top = c end
        end
        local font = Theme.Font(12)
        pcall(function()
            canvas:AddText(top.x, top.y - 14, tostring(object.name), font, color)
        end)
    end
end

--- Effect handle (TTL + sticky) ------------------------------------------------------------

-- The uniform { kind, state, update(dt) -> alive, draw(canvas) } handle EffectRegistry holds.
-- `update` accumulates elapsed time; a non-sticky handle reports dead once past the TTL (default
-- 5s), a sticky one stays alive forever (only Dismiss removes it). `draw` re-projects and redraws
-- every frame - the tile is world-anchored, so its screen position changes as the camera moves.
---@param spec Watchdog.ObjectMarker.Spec|nil
function ObjectMarker.BuildHandle(spec, project)
    spec = spec or {}
    local sticky = spec.sticky and true or false
    local ttl = spec.ttl
    if type(ttl) ~= "number" then ttl = DEFAULT_TTL_SECONDS end
    local elapsed = 0
    return {
        kind = "object_marker",
        state = {},
        update = function(dt)
            elapsed = elapsed + (tonumber(dt) or 0)
            return sticky or elapsed < ttl
        end,
        draw = function(canvas)
            ObjectMarker.DrawTile(canvas, spec, project)
        end,
    }
end

--- Node registration -----------------------------------------------------------------------

---@param registry LibNodeGraph.Registry
---@param runtime Watchdog.Runtime
function ObjectMarker.Register(registry, runtime)
    -- Register the two Control Specs the config pins use (the capture button + the mode
    -- multi-select), reusing ADR-0004's Control Spec seam. Guarded so a headless/test require of
    -- this module (no ui layer wanted) still registers the node itself.
    pcall(function()
        local Controls = require("ui/controls")
        -- The "Select object" capture button: shows the captured object's name, or its placeholder
        -- when nothing's been captured yet.
        Controls.Register("object_marker.object", {
            widget = "capture",
            -- Discriminates this capture from Screen Marker's drag overlay: ui/graph.lua's
            -- capture-click dispatch arms the MiniMenu select mode for captureKind == "object".
            captureKind = "object",
            placeholder = "Select object",
            format = function(value)
                if type(value) ~= "table" then return "" end
                return value.name or ""
            end,
        })
        -- The 4-way mode multi-select: a composite band of one checkbox row per mode. The mode Pin
        -- Control (ui/controls/mode.lua) owns the band layout/display/toggle; the modes list is all
        -- the per-tag config it needs.
        Controls.Register("object_marker.mode", { widget = "mode", modes = ObjectMarker.MODES })
    end)

    registry:RegisterNodeType("action.object_marker", {
        category = "action",
        displayName = "Object Marker",
        description = "Marks a captured world object's tile on the overlay",
        pins = {
            { name = "show", kind = "exec", direction = "in", label = "Show" },
            { name = "dismiss", kind = "exec", direction = "in", label = "Dismiss" },
            { name = "object", kind = "data", direction = "in", dataType = "object_marker.object", default = nil },
            { name = "mode", kind = "data", direction = "in", dataType = "object_marker.mode", default = DEFAULT_MODE },
            { name = "color", kind = "data", direction = "in", dataType = "color", default = DEFAULT_COLOR },
            { name = "width", kind = "data", direction = "in", dataType = "number", default = DEFAULT_WIDTH },
            { name = "showLabel", kind = "data", direction = "in", dataType = "bool", default = true },
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

            -- Idempotent/Replace, keyed by this node's own persistent state table (Stack capped at
            -- 1) - re-Show evicts this node's still-live handle first; different nodes stack.
            dismiss()

            local object = ctx:In("object")
            if type(object) ~= "table" then
                return -- a never-captured object never fires (AC)
            end

            local hold = ctx:In("hold")
            if type(hold) ~= "number" then hold = DEFAULT_TTL_SECONDS end

            local handle = ObjectMarker.BuildHandle({
                object = object,
                mode = ctx:In("mode"),
                color = ctx:In("color"),
                width = ctx:In("width"),
                showLabel = ctx:In("showLabel"),
                sticky = ctx:In("sticky"),
                ttl = hold,
            })
            state.handle = handle
            runtime.effects:PushStack(state, handle, 1)
        end,
    })
end

return ObjectMarker
