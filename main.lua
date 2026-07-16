-- Watchdog — a node-graph editor plugin.
--
-- Orchestrator: builds a live LibNodeGraph Graph over the standard + Watchdog node sets,
-- mounts the Editor UI onto the client's root component, and wires the per-frame draw /
-- per-tick update loops. Follows the idempotent load/reload pattern (CLAUDE.md): tear down
-- any prior instance up top, publish this instance as the global `watchdog` at the end.

if Watchdog ~= nil and Watchdog.Stop ~= nil then
    pcall(function() Watchdog.Stop() end)
end

local Editor = require("ui/graph")
local Store  = require("store")
local Runtime = require("runtime")

if LibPluginMenu ~= nil then
    LibPluginMenu.Unregister("watchdog")
    LibPluginMenu.Register({
        id = "watchdog",
        name = "Watchdog",
        icon = "W",
        -- icon = id.Sprite.AIF_COINS_ICON,
        onClick = function()
            pcall(function() Watchdog.editor:Toggle() end)
        end
    })
end

-- Names used to Subscribe/Unsubscribe each editor-lifecycle event we hook directly (mount
-- loop, draw loop, the F8 toggle). Every *game* event (chat, stat changes, ...) is owned by
-- runtime.lua's dispatcher instead — see the registry/runtime setup below. Events are
-- sandboxed per-plugin by the client, so these don't need a plugin-specific prefix — just
-- enough to be unique within this file and reused between Subscribe and Unsubscribe.
local Events = {
    Logic = "logic",
    Draw = "draw",
    KeyDown = "key",
}

-- Key that toggles the editor Window. Any GameKey member name (see core/keyboard docs:
-- GameKey.F8, GameKey.P, GameKey.SPACE, ...). Change this one string to rebind.
local TOGGLE_KEY = "F8"

-- Approximate seconds per Event.Logic tick (~0.02s, see CLAUDE.md). Logic doesn't hand back
-- a measured dt, so runtime.effects' handles (TTL/animation) advance against this fixed
-- per-tick delta, the same tick-counting convention SAVE_INTERVAL_TICKS below already uses.
local LOGIC_TICK_SECONDS = 0.02

if Plugin.HasPermission(PluginPermissions.httpAccess) then
    log("Watchdog: plugin has HTTP access")
else
    log("Watchdog: plugin does NOT have HTTP access")
end

--- Runtime dispatcher + registry + node types --------------------------------------------
-- `runtime` owns every game-event Subscribe/Unsubscribe (see runtime.lua); a trigger node
-- declares its own binding inside its own Register(registry, runtime) call below via
-- runtime:BindTrigger(...), so adding a new trigger never means editing dispatch code here.
-- Its live graph is set once we know which graph we're editing (further down).

local runtime = Runtime.new()

local registry = LibNodeGraph.NewRegistry()
LibNodeGraphStd.Register(registry)
require("nodes/triggers/chat").Register(registry, runtime)
require("nodes/actions/log").Register(registry)
require("nodes/actions/sound").Register(registry)
require("nodes/actions/popup").Register(registry, runtime)

--- Graph: restore the saved one, or seed a demo on first run -----------------------------
-- Persistence backend lives in store.lua (multi-graph, keyed by name). We only ever show
-- one graph today — the current one — but the store already saves many by name so the
-- future "new graph / switch graph" UI is purely additive.

-- The demo graph, built only when there's nothing saved yet: a small, deliberately varied
-- graph so the Editor has real content — an event flow (Chat Trigger -> Log, exec + data)
-- and a pure data chain (Add -> Multiply).
local function seedDemo()
    local graph = LibNodeGraph.NewGraph(registry)

    local chatNode = graph:AddNode("trigger.chat", { contains = "Hello" })
    local logNode  = graph:AddNode("action.log")
    local addNode  = graph:AddNode("std.add", { a = 2, b = 3 })
    local mulNode  = graph:AddNode("std.multiply", { a = 4, b = 5 })

    -- Guard each connect so one bad edge can't stop the plugin from loading.
    local function tryConnect(fromN, fromP, toN, toP)
        local ok, err = pcall(function() graph:Connect(fromN, fromP, toN, toP) end)
        if not ok and log ~= nil then
            log("Watchdog: demo connect failed — " .. tostring(err))
        end
    end

    tryConnect(chatNode, "out", logNode, "in")
    tryConnect(chatNode, "message", logNode, "message")
    tryConnect(addNode, "result", mulNode, "a")

    local layout = {
        [chatNode] = { x = 80,  y = 90 },
        [logNode]  = { x = 460, y = 110 },
        [addNode]  = { x = 80,  y = 360 },
        [mulNode]  = { x = 460, y = 380 },
    }

    return graph, layout
end

local document = Store.Load()

-- Instantiate *every* saved graph as a live alert (#27): triggers in all enabled alerts fire,
-- not just the one the editor is viewing. `Store.RestoreAll` returns one live Graph per saved
-- entry with its persisted `enabled` flag; each is registered with the runtime dispatcher below.
-- If there's nothing saved (or the whole set is unrestorable), seed the demo as the sole alert.
local restored = {}
do
    local ok, all = pcall(function() return Store.RestoreAll(document, registry) end)
    if ok and all ~= nil then
        restored = all
    elseif log ~= nil then
        log("Watchdog: RestoreAll failed, seeding demo — " .. tostring(all))
    end
    if #restored == 0 then
        local graph, layout = seedDemo()
        Store.UpsertCurrent(document, "default", graph, layout, nil)
        Store.Save(document)
        restored = { { name = "default", graph = graph, layout = layout, view = nil, enabled = true } }
    end
end

-- Register each restored graph as a live alert the dispatcher fans out over. The editor edits
-- one of these same live instances (the current one), so its triggers fire mid-edit like the
-- rest; the runtime checks `enabled` at fire time so a disabled alert stays live but silent.
for _, alert in ipairs(restored) do
    runtime:AddAlert(alert.name, alert.graph, alert.enabled)
end

-- The name of the graph we're editing; every save writes back under this name. Prefer the saved
-- `current` pointer, falling back to the first restored alert.
local currentName = document.current or restored[1].name

-- The editor shows the *current* alert — the very same live Graph instance the runtime holds for
-- it, so edits and trigger firing stay in sync. Fall back to the first alert if `current` is
-- stale (points at a name that didn't restore).
local currentAlert
for _, alert in ipairs(restored) do
    if alert.name == currentName then currentAlert = alert; break end
end
if currentAlert == nil then
    currentAlert = restored[1]
    currentName = currentAlert.name
end

local graph = currentAlert.graph
local editor = Editor.new(graph, registry, currentAlert.layout, currentAlert.view)

-- Persistence hook for the alert enable/disable API: SetEnabled/Toggle write the flag straight
-- to the saved document and flush, so an alert toggled off (by the user or an Alert Toggle node,
-- #35) stays off across reloads. Independent of the editor autosave loop below.
runtime:SetPersistence({
    SetEnabled = function(name, enabled)
        Store.SetEnabled(document, name, enabled)
        Store.Save(document)
    end,
})

--- Client root parent (interface may not be loaded yet; retried on the Logic loop) ------

local function getRootParent()
    local candidates = { "TOPLEVEL_V2__GAME_AREA" }
    for _, key in ipairs(candidates) do
        local componentID = id.Component[key]
        if componentID ~= nil then
            -- Returns nil (not an error) if the interface isn't loaded yet.
            local component = ui.Interfaces:GetComponent(componentID)
            if component ~= nil then
                return component
            end
        end
    end
    return nil
end

--- Event loops --------------------------------------------------------------------------

-- `mounted` tracks the editor Window; `effectsMounted` tracks the EffectRegistry's own
-- always-on overlay Canvas (see effects.lua) — separate flags because the overlay must keep
-- drawing while the editor Window is closed, so its mount/draw can't be gated on state.mounted.
local state = { mounted = false, effectsMounted = false }

-- Debounced autosave, but only while the editor Window is open — that's the only time the
-- graph can be edited, so during normal play we stay off persistentdb entirely instead of
-- re-encoding every couple of seconds. (The saved document is pure graph structure +
-- controls + Layout/View; runtime node state is never serialized, so a closed editor has
-- nothing new to save anyway.) While open, rather than thread a "dirty" flag through every
-- interaction we periodically re-encode and persist only when the encoding actually changed
-- -- graphs are tiny, so this diff is cheap. ~2s cadence at the ~0.02s Logic tick. On the
-- open -> closed transition we flush once so edits made right before closing aren't lost.
local SAVE_INTERVAL_TICKS = 100
local saveState = { tick = 0, wasOpen = false, lastEncoded = Store.Encode(document) }

local function persistNow()
    Store.UpsertCurrent(document, currentName, editor.graph, editor:GetLayout(), editor:GetView())
    local encoded = Store.Encode(document)
    if encoded ~= nil and encoded ~= saveState.lastEncoded then
        if Store.Save(document) then
            saveState.lastEncoded = encoded
        end
    end
end

local function onLogic()
    -- Advances the effect registry (and polls mouse activity) every tick, independent of
    -- whether the editor Window has mounted yet.
    pcall(function() runtime:Update(LOGIC_TICK_SECONDS) end)

    if not state.effectsMounted or not state.mounted then
        local parent = getRootParent()
        if parent ~= nil then
            if not state.effectsMounted then
                pcall(function() runtime.effects:Mount(parent) end)
                -- Mount swallows its own errors (logs, leaves canvas nil), so success is
                -- read back off the registry rather than the pcall's `ok` — mirrors the
                -- editor:Mount retry-on-failure pattern just below.
                state.effectsMounted = runtime.effects:IsMounted()
            end
            if not state.mounted then
                local ok, err = pcall(function() editor:Mount(parent) end)
                if ok then
                    state.mounted = true
                elseif log ~= nil then
                    log("Watchdog: mount failed — " .. tostring(err))
                end
            end
        end
    end

    if not state.mounted then
        return
    end
    pcall(function() editor:update() end)

    -- Persist only during an editing session (Window open); flush once when it closes.
    local isOpen = editor:IsVisible()
    if isOpen then
        saveState.tick = saveState.tick + 1
        if saveState.tick >= SAVE_INTERVAL_TICKS then
            saveState.tick = 0
            pcall(persistNow)
        end
    elseif saveState.wasOpen then
        saveState.tick = 0
        pcall(persistNow)
    end
    saveState.wasOpen = isOpen
end

local function onDraw()
    if state.mounted then
        pcall(function() editor:draw() end)
    end
    -- Draws even when the editor Window is closed — the overlay Canvas is always-on.
    if state.effectsMounted then
        pcall(function() runtime.effects:Draw() end)
    end
end

--- Public API + lifecycle ---------------------------------------------------------------

local api = {}

function api.Stop()
    -- Flush the latest edits before tearing down, so a reload (which calls the previous
    -- instance's Stop first) doesn't lose work done since the last autosave tick.
    pcall(persistNow)
    pcall(function() Event.Logic.Unsubscribe(Events.Logic) end)
    pcall(function() Event.Draw.Unsubscribe(Events.Draw) end)
    pcall(function() Event.KeyDown.Unsubscribe(Events.KeyDown) end)
    pcall(function() runtime:Stop() end)
    pcall(function() runtime.effects:Unmount() end)
    pcall(function() editor:Unmount() end)
    state.mounted = false
    state.effectsMounted = false
end

api.editor = editor
api.graph = graph
api.document = document  -- the persisted multi-graph document, exposed for inspection

Event.Logic.Subscribe(Events.Logic, onLogic)
Event.Draw.Subscribe(Events.Draw, onDraw)

-- Hide/show the editor Window on TOGGLE_KEY. KeyDown payload has gameKey/isRepeat
-- (core/events docs); ignore auto-repeat so a held key doesn't flicker the panel.
Event.KeyDown.Subscribe(Events.KeyDown, function(keyEvent)
    if keyEvent == nil or keyEvent.isRepeat then return end
    -- Esc dismisses the color popup (#30) rather than toggling the editor Window.
    if keyEvent.gameKey == GameKey.ESCAPE then
        pcall(function() editor:onEscape() end)
        return
    end
    local target = GameKey[TOGGLE_KEY]
    if target ~= nil and keyEvent.gameKey == target then
        pcall(function() editor:Toggle() end)
    end
end)

Watchdog = api
print("Watchdog editor loaded")

return Watchdog
