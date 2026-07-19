-- location.lua — the Location trigger (`trigger.location`, #34): fires when the player
-- enters (and, if the `Leave` pin is wired, leaves) a radius around a target tile. It's the
-- first node built on the poll model (#28): rather than an event fan-out, it rides a
-- `{ kind = "poll", event = "Logic" }` binding whose `transform` samples the player position
-- once per tick and whose `filter` is the per-node in-range predicate, with the dispatcher's
-- edge gate turning the predicate's false->true / true->false transitions into `Enter` / `Leave`
-- exec fires (see runtime.lua's `_firePollBindingInGraph`).
--
-- Pipeline split (why the work lives where it does):
--   * transform (once/tick, shared) — reads `Player.GetEntity().coordGrid`. `!IsAvailable()`
--     (logged out) returns nil, which the dispatcher treats as "freeze": the tick is skipped and
--     every node's edge state is left untouched, so a logout produces no spurious `Leave` and a
--     relog in the same spot produces no phantom `Enter`.
--   * filter (per node) — the Chebyshev in-range test with an exact `level` match, plus the
--     nil-target guard (a node with no `target` set never fires). Reads the node's own `target`
--     and `radius` controls via the handle the dispatcher passes.
--   * run (edge only) — the dispatcher calls this solely on a detected edge, handing it
--     `{ edge, sample }`; it surfaces `coord`/`distance` on the data outs and fires the resolved
--     edge pin. It never re-derives which edge occurred — the dispatcher owns that.
--
-- Distance is Chebyshev (`max(|Δx|, |Δz|)`, i.e. king-moves / a square ring), matching how a
-- "within N tiles" radius reads on the tile grid, and the `level` (plane) must match exactly —
-- two tiles on different floors are never "near" regardless of x/z.
--
-- Registered from main.lua with one `require("nodes/triggers/location").Register(registry, runtime)`
-- line: both the node type and its Logic poll binding are declared here, so no dispatcher or
-- main.lua edits are needed beyond that require (the #24 self-contained-trigger architecture).

local Location = {}

-- The payload `transform` samples once per tick and hands to `filter`; the dispatcher then wraps
-- it as the poll fire payload's `sample`. A distinct one-field class (rather than the bare
-- CoordGrid) so downstream shaping reads `sample.coord` explicitly.
---@class Watchdog.Payload.Location
---@field coord CoordGrid  # the player's tile this tick ({ x, z, level })

-- Chebyshev (chessboard) distance between two { x, z } tiles: the number of king-moves between
-- them, so a radius R covers the (2R+1)x(2R+1) square centered on the target. `level` is compared
-- separately (exact match) and deliberately not folded in here.
local function chebyshev(a, b)
    return math.max(math.abs(a.x - b.x), math.abs(a.z - b.z))
end

-- Normalizes a `radius` control to a usable number: non-numbers collapse to 0 and negatives are
-- floored at 0, so a stray/blank value behaves as "the target tile only" rather than erroring or
-- (with a negative) never matching. No upper clamp — a huge radius is a legitimate "anywhere on
-- this plane" trigger.
local function normalizeRadius(radius)
    if type(radius) ~= "number" or radius < 0 then
        return 0
    end
    return radius
end

-- A fully-specified target tile, or nil. A coordgrid control defaults to nil (never set) and can
-- be mid-edit partial, so a target only counts once all three axes are present; anything else is
-- "no target" and the predicate returns false (the node never fires).
local function validTarget(target)
    if type(target) ~= "table" then
        return nil
    end
    if target.x == nil or target.z == nil or target.level == nil then
        return nil
    end
    return target
end

---@param registry LibNodeGraph.Registry
function Location.Register(registry, runtime)
    registry:RegisterNodeType("trigger.location", {
        category = "trigger",
        displayName = "Location",
        description = "Entering/leaving a radius around a tile",
        pins = {
            -- The target tile ({ x, z, level }). Default nil: a fresh node has no target and never
            -- fires until one is set (e.g. the coordgrid control's "set to current position").
            { name = "target", kind = "data", direction = "in", dataType = "coordgrid", default = nil },
            -- Tiles of slack around the target, Chebyshev. 0 => the target tile exactly.
            { name = "radius", kind = "data", direction = "in", dataType = "number", default = 0 },
            { name = "Enter", kind = "exec", direction = "out" },
            { name = "Leave", kind = "exec", direction = "out" },
            -- The player's current tile at the moment of the edge, and its Chebyshev distance from
            -- the target — for downstream display / conditional logic.
            { name = "coord", kind = "data", direction = "out", dataType = "coordgrid" },
            { name = "distance", kind = "data", direction = "out", dataType = "number" },
        },
        run = function(ctx)
            local coord = ctx.payload.sample.coord
            ctx:Out("coord", coord)
            local target = validTarget(ctx:In("target"))
            if target ~= nil then
                ctx:Out("distance", chebyshev(coord, target))
            end
            ctx:Fire(ctx.payload.edge)
        end,
    })

    runtime:BindTrigger("trigger.location", {
        {
            kind = "poll",
            event = "Logic",
            -- Sample the live player tile once per tick. Logged out => nil => the dispatcher
            -- freezes edge state for the tick (no Leave on logout, no Enter on relog-in-place).
            transform = function()
                if not Player.IsAvailable() then
                    return nil
                end
                local c = Player.GetEntity().coordGrid
                return { coord = { x = c.x, z = c.z, level = c.level } }
            end,
            -- Per-node in-range predicate: exact plane match AND within the Chebyshev radius.
            -- A nil/partial target (no tile set) never matches, so the node stays silent.
            filter = function(payload, node)
                local target = validTarget(node.GetControl("target"))
                if target == nil then
                    return false
                end
                local coord = payload.coord
                if coord.level ~= target.level then
                    return false
                end
                return chebyshev(coord, target) <= normalizeRadius(node.GetControl("radius"))
            end,
        },
    })
end

return Location
