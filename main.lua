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
local ToastStack = require("toast")

local function RegisterToPluginMenu()
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
Event.OptionalDependencyChanged.Subscribe('opdepchanged', function(dep)
    log('op dep changed:', dep.pluginIdentifier, dep.enabled, LibPluginMenu, dep.pluginIdentifier == 'LibPluginMenu')
    if LibPluginMenu ~= nil then
        RegisterToPluginMenu()
    end
end)

-- log("LibPluginMenu is available: " .. tostring(LibPluginMenu ~= nil))

-- ExecuteConsoleCommand("pon LibPluginMenu")

-- log("LibPluginMenu is available: " .. tostring(LibPluginMenu ~= nil))

log(LibPluginMenu)
if LibPluginMenu ~= nil then
    RegisterToPluginMenu()
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

-- Toast action (#36): one shared, draggable toast stack riding on runtime.effects, keyed
-- off `runtime.toast` the same way `runtime.effects` already is, so nodes/actions/toast.lua
-- only needs the (registry, runtime) it's already handed. Anchor position persists under its
-- own persistentdb key, independent of the graph document store.lua owns.
local TOAST_ANCHOR_KEY = "watchdog_toast_anchor"
runtime.toast = ToastStack.new(runtime.effects, {
    Load = function()
        if PersistentDB == nil or LibNodeGraph == nil or LibNodeGraph.Json == nil then return nil end
        local text
        pcall(function() text = PersistentDB:GetString(TOAST_ANCHOR_KEY) end)
        if type(text) ~= "string" or text == "" then return nil end
        local ok, pos = pcall(function() return LibNodeGraph.Json.Default.decode(text) end)
        if ok then return pos end
        return nil
    end,
    Save = function(pos)
        if PersistentDB == nil or LibNodeGraph == nil or LibNodeGraph.Json == nil then return end
        local ok, text = pcall(function() return LibNodeGraph.Json.Default.encode(pos) end)
        if ok and text ~= nil then
            pcall(function() PersistentDB:SetString(TOAST_ANCHOR_KEY, text) end)
        end
    end,
})

local registry = LibNodeGraph.NewRegistry()
LibNodeGraphStd.Register(registry)
require("nodes/triggers/game_message").Register(registry, runtime)
require("nodes/triggers/player_chat").Register(registry, runtime)
require("nodes/triggers/logic").Register(registry, runtime)
require("nodes/triggers/location").Register(registry, runtime)
require("nodes/triggers/skill").Register(registry, runtime)
require("nodes/triggers/entity_spawn").Register(registry, runtime)
require("nodes/actions/log").Register(registry)
require("nodes/actions/sound").Register(registry)
require("nodes/actions/custom_sound").Register(registry)
require("nodes/actions/screen_flash").Register(registry, runtime)
require("nodes/actions/popup").Register(registry, runtime)
require("nodes/actions/infobox").Register(registry, runtime)
require("nodes/actions/screen_marker").Register(registry, runtime)
require("nodes/actions/object_marker").Register(registry, runtime)
require("nodes/actions/toast").Register(registry, runtime)
require("nodes/actions/alert_toggle").Register(registry, runtime)

-- The generalized `preload(node)` node-type hook (#33): AddAlert (below) already runs the
-- graph-restore preload pass through this; the Editor (ui/graph.lua) calls
-- runtime:PreloadNode after every Graph:SetControl for the control-commit pass.
runtime:SetRegistry(registry)

--- Graph: restore the saved one, or seed a demo on first run -----------------------------
-- Persistence backend lives in store.lua (multi-graph, keyed by name). We only ever show
-- one graph today — the current one — but the store already saves many by name so the
-- future "new graph / switch graph" UI is purely additive.

-- The demo graph, built only when there's nothing saved yet: a small, deliberately varied
-- graph so the Editor has real content — an event flow (Game Message -> Log, exec + data)
-- and a pure data chain (Add -> Multiply).
local function seedDemo()
    local graph = LibNodeGraph.NewGraph(registry)

    local chatNode = graph:AddNode("trigger.game_message",
        { contains = { needle = "Hello", mode = "substring" } })
    local logNode  = graph:AddNode("action.log")
    local addNode  = graph:AddNode("std.add", { a = 2, b = 3 })
    local mulNode  = graph:AddNode("std.multiply", { a = 4, b = 5 })

    -- Guard each connect so one bad edge can't stop the plugin from loading.
    local function tryConnect(fromN, fromP, toN, toP)
        local id, reason = graph:Connect(fromN, fromP, toN, toP)
        if id == nil and log ~= nil then
            log("Watchdog: demo connect failed — " .. tostring(reason))
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
        Store.UpsertCurrent(document, "default", graph, layout)
        Store.Save(document)
        restored = { { name = "default", graph = graph, layout = layout, enabled = true } }
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
local editor = Editor.new(graph, registry, currentAlert.layout, runtime)

-- Persistence hook for the alert enable/disable API: SetEnabled/Toggle write the flag straight
-- to the saved document and flush, so an alert toggled off (by the user or an Alert Toggle node,
-- #35) stays off across reloads. Independent of the editor autosave loop below.
runtime:SetPersistence({
    SetEnabled = function(name, enabled)
        Store.SetEnabled(document, name, enabled)
        Store.Save(document)
    end,
})

-- Restore the InfoBox Area's (#41) persisted anchor, if any was ever saved, then wire its own
-- EndDrag persistence hook the same seam shape as the alert enable/disable one above.
do
    local ax, ay = Store.GetInfoBoxAnchor(document)
    if ax ~= nil and ay ~= nil then
        runtime.infobox:SetAnchor(ax, ay)
    end
end
runtime.infobox:SetPersistence({
    SaveAnchor = function(x, y)
        Store.SetInfoBoxAnchor(document, x, y)
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
-- always-on overlay Canvas (see effects.lua); `infoboxMounted` tracks the InfoBox Area's (#41)
-- own click-capture layer; `screenMarkerMounted` tracks the Screen Marker capture overlay's
-- (#39) own click-capture layer — all four must keep working while the editor Window is
-- closed, so none can be gated on state.mounted. The Toast stack (#36) rides on the
-- effects Canvas, so it mounts/draws alongside `effectsMounted` rather than needing its own flag.
local state = { mounted = false, effectsMounted = false, infoboxMounted = false, screenMarkerMounted = false, infoboxWasDragging = false }

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
    Store.UpsertCurrent(document, currentName, editor.graph, editor:GetLayout())
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
    pcall(function() runtime.toast:Update(LOGIC_TICK_SECONDS) end)

    -- The InfoBox Area's click-capture layer tracks the strip's own Bounds (grows/shrinks as
    -- tiles are added/removed) and its drag needs to follow the cursor every tick same as any
    -- other polled interaction here — both independent of whether the capture just mounted.
    if state.infoboxMounted then
        pcall(function() runtime.infobox:Reposition() end)
        local dragging = runtime.infobox:IsDragging()
        if dragging then
            local mx, my = runtime:GetMousePos()
            if mx ~= nil then
                pcall(function() runtime.infobox:Drag(mx, my) end)
            end
        elseif state.infoboxWasDragging then
            -- The drag fronted the InfoBox capture over the editor's own Capture Layer so a
            -- fast cursor crossing into the editor couldn't steal the hover and drop the grab.
            -- Now that it's ended, restore the editor to the top so the idle strip-sized
            -- capture can't intercept clicks meant for the editor where they overlap.
            pcall(function() editor:RaiseToFront() end)
        end
        state.infoboxWasDragging = dragging
    end

    -- The Screen Marker capture overlay's (#39) click-capture layer needs no per-tick
    -- Reposition the way InfoBox's does — its size only ever changes on Arm/Cancel — but its
    -- drag does need to follow the cursor every tick, same as any other polled interaction.
    if state.screenMarkerMounted and runtime.screenMarkerCapture:IsDragging() then
        local mx, my = runtime:GetMousePos()
        if mx ~= nil then
            pcall(function() runtime.screenMarkerCapture:UpdateDrag(mx, my) end)
        end
    end

    if not state.effectsMounted or not state.infoboxMounted or not state.screenMarkerMounted
        or not state.mounted then
        local parent = getRootParent()
        if parent ~= nil then
            if not state.effectsMounted then
                pcall(function() runtime.effects:Mount(parent) end)
                -- Mount swallows its own errors (logs, leaves canvas nil), so success is
                -- read back off the registry rather than the pcall's `ok` — mirrors the
                -- editor:Mount retry-on-failure pattern just below.
                state.effectsMounted = runtime.effects:IsMounted()
                pcall(function() runtime.toast:Mount(parent) end)
            end
            if not state.infoboxMounted then
                pcall(function() runtime.infobox:Mount(parent) end)
                state.infoboxMounted = runtime.infobox:IsMounted()
            end
            if not state.screenMarkerMounted then
                pcall(function() runtime.screenMarkerCapture:Mount(parent) end)
                state.screenMarkerMounted = runtime.screenMarkerCapture:IsMounted()
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
        -- Wipe the retained overlay Canvas once, before the four passes below (they share it).
        -- See EffectRegistry:BeginFrame and #46.
        pcall(function() runtime.effects:BeginFrame() end)
        pcall(function() runtime.effects:Draw() end)
        -- The Toast stack (#36) rides the same overlay Canvas as `effects`, drawn as its
        -- own pass so one bad toast can't take the rest of the overlay down.
        pcall(function() runtime.toast:Draw(runtime.effects:GetCanvas()) end)
        -- The InfoBox Area (#41) shares the same overlay Canvas as `effects`, drawn as its own
        -- pass so a bad tile can't take the rest of the overlay down. Hover position reuses
        -- Update's own mouse poll rather than a second GetPosition call.
        pcall(function()
            local hx, hy = runtime:GetMousePos()
            runtime.infobox:Draw(runtime.effects.canvas, hx, hy)
        end)
        -- The Screen Marker capture overlay (#39) draws its own dim + in-progress selection
        -- box on the same overlay Canvas, as its own pass for the same reason.
        pcall(function() runtime.screenMarkerCapture:Draw(runtime.effects.canvas) end)
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
    pcall(function() runtime.toast:Unmount() end)
    pcall(function() runtime.infobox:Unmount() end)
    pcall(function() runtime.screenMarkerCapture:Unmount() end)
    pcall(function() editor:Unmount() end)
    state.mounted = false
    state.effectsMounted = false
    state.infoboxMounted = false
    state.screenMarkerMounted = false
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
