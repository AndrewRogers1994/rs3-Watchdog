-- action.screen_flash (#37) — a long-running repeating full-screen pulse for an unmissable,
-- AFK-safe alert: a dismiss-only EffectRegistry effect (effects.lua) drawn on the always-on
-- overlay Canvas. Two hardcoded 25-tick segments (rise, then fall — no timing params) repeat
-- forever until dismissed; each segment is independently shaped `instant` (step straight to
-- the segment's target and hold) or `fade` (linear ramp across it) by the `inShape`/`outShape`
-- Controls -- instant+instant is a ~1Hz square blink, the RuneLite-parity default feel.
--
-- Dismissed by the `dismiss` exec pin, or automatically once the runtime-owned
-- `keyboardActivityTick`/`mouseActivityTick` (see runtime.lua) move past the tick recorded at
-- Show, per the `dismissOn` Control (none/mouse/keyboard/both; none = exec-only AFK case).
-- Concurrency is Replace (re-Show restarts): a Stack capped at 1 per node, keyed by the node's
-- own persistent `ctx.state` table, evicts the node's own still-live handle before pushing the
-- new one. No exec-out.
--
-- ASSUMPTION (Build-verify against LibNodeGraph, unavailable in this sandbox — see CLAUDE.md):
-- this is the first Watchdog node with two independent exec-in pins. `run(ctx)` is assumed to
-- be invoked once per firing with `ctx.pin` naming which exec-in pin fired, mirroring
-- `ctx:Fire(name)` for exec-outs. If the engine instead dispatches per-pin handlers some other
-- way, only the `ctx.pin` branch below needs adjusting -- the shaping/dismiss-on math is pure
-- and already unit-tested (tests/test_screen_flash.lua) independent of this wiring.

local Controls = require("ui/controls")

local ScreenFlash = {}

local SEGMENT_TICKS = 25
local CYCLE_TICKS = SEGMENT_TICKS * 2

-- No existing enum tag fits (ADR-0004: "if a genuinely pin-specific enum is ever needed,
-- register a distinct tag for it"). Both are pin-specific to this node.
Controls.Register("shape", {
    widget = "enum",
    choices = {
        { value = "instant", label = "Instant" },
        { value = "fade",    label = "Fade" },
    },
})

Controls.Register("dismissOn", {
    widget = "enum",
    choices = {
        { value = "none",     label = "None" },
        { value = "mouse",    label = "Mouse" },
        { value = "keyboard", label = "Keyboard" },
        { value = "both",     label = "Both" },
    },
})

-- Full opaque red: a loud, unmissable default so a never-configured node still visibly fires.
local DEFAULT_COLOR = { r = 255, g = 0, b = 0, a = 255 }

-- Alpha (0..`peak`) at `tick` (0-based within one CYCLE_TICKS-long rise/fall cycle).
-- `instant` steps straight to the segment's target value and holds it for the whole segment;
-- `fade` ramps linearly across it, reaching the target exactly on the segment's last tick.
function ScreenFlash.AlphaAt(tick, peak, inShape, outShape)
    local cycleTick = tick % CYCLE_TICKS
    if cycleTick < SEGMENT_TICKS then
        if inShape == "fade" then
            return peak * ((cycleTick + 1) / SEGMENT_TICKS)
        end
        return peak
    end
    local fallTick = cycleTick - SEGMENT_TICKS
    if outShape == "fade" then
        return peak * (1 - (fallTick + 1) / SEGMENT_TICKS)
    end
    return 0
end

-- Whether activity since `baseline` (the tick counts recorded at Show) should auto-dismiss the
-- effect, per the `dismissOn` Control. `runtimeTicks` is `{ mouse = ..., keyboard = ... }`.
function ScreenFlash.ShouldAutoDismiss(dismissOn, baseline, runtimeTicks)
    if dismissOn == "none" or dismissOn == nil then return false end
    local moved = runtimeTicks.mouse ~= baseline.mouse
    local pressed = runtimeTicks.keyboard ~= baseline.keyboard
    if dismissOn == "mouse" then return moved end
    if dismissOn == "keyboard" then return pressed end
    return moved or pressed -- "both"
end

-- Builds the uniform effect handle (effects.lua) for one Show. `color` supplies peak alpha
-- (color.a) and RGB; `baseline` is the activity-tick snapshot taken at Show time.
local function makeHandle(color, inShape, outShape, dismissOn, baseline, runtime)
    local tick = 0
    local alpha = 0
    local peak = (color ~= nil and color.a) or 255
    return {
        kind = "screen_flash",
        state = {},
        update = function(_dt)
            if ScreenFlash.ShouldAutoDismiss(dismissOn, baseline,
                { mouse = runtime.mouseActivityTick, keyboard = runtime.keyboardActivityTick }) then
                return false
            end
            alpha = ScreenFlash.AlphaAt(tick, peak, inShape, outShape)
            tick = tick + 1
            return true
        end,
        draw = function(canvas)
            if alpha <= 0 then return end
            local w, h = 1920, 1080
            pcall(function()
                if canvas.width and canvas.width > 0 then w = canvas.width end
                if canvas.height and canvas.height > 0 then h = canvas.height end
            end)
            local r = ((color ~= nil and color.r) or 0) / 255
            local g = ((color ~= nil and color.g) or 0) / 255
            local b = ((color ~= nil and color.b) or 0) / 255
            canvas:AddRectangle(0, 0, w, h, Vector4.new(r, g, b, alpha / 255))
        end,
    }
end

function ScreenFlash.Register(registry, runtime)
    registry:RegisterNodeType("action.screen_flash", {
        category = "action",
        displayName = "Screen Flash",
        pins = {
            { name = "show", kind = "exec", direction = "in", label = "Show" },
            { name = "dismiss", kind = "exec", direction = "in", label = "Dismiss" },
            { name = "color", kind = "data", direction = "in", dataType = "color", default = DEFAULT_COLOR },
            { name = "inShape", kind = "data", direction = "in", dataType = "shape",
              default = "instant", label = "In Shape" },
            { name = "outShape", kind = "data", direction = "in", dataType = "shape",
              default = "instant", label = "Out Shape" },
            { name = "dismissOn", kind = "data", direction = "in", dataType = "dismissOn",
              default = "both", label = "Dismiss On" },
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

            if ctx.pin == "dismiss" then
                dismiss()
                return
            end

            -- Replace: re-Show restarts, so any of this node's own still-live handle goes
            -- first (Stack capped at 1, keyed by this node's own persistent state table).
            dismiss()

            local color = ctx:In("color") or DEFAULT_COLOR
            local inShape = ctx:In("inShape") or "instant"
            local outShape = ctx:In("outShape") or "instant"
            local dismissOn = ctx:In("dismissOn") or "both"
            local baseline = { mouse = runtime.mouseActivityTick, keyboard = runtime.keyboardActivityTick }

            local handle = makeHandle(color, inShape, outShape, dismissOn, baseline, runtime)
            state.handle = handle
            runtime.effects:PushStack(state, handle, 1)
        end,
    })
end

return ScreenFlash
