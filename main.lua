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
local Manager = require("ui/manager")
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
            -- Hide/show the whole plugin UI at the current nav level (#80) — never navigates, so
            -- the button reopens whichever surface (Manager or Editor) you last had up.
            pcall(function() Watchdog.Toggle() end)
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

-- The injectable identity source (#89): the runtime's seam onto the client `Player` global,
-- mirroring how the event/`Mouse` sources are injected. `Resolve()` returns the current
-- character's display name only when actually logged in and in-world (`Player.IsAvailable()` ∧
-- `entity.isValid`, per research #74) — otherwise nil, which the runtime treats as "not readable
-- yet" and retries. This is the only client-coupled half of player scoping; everything else is
-- headless-tested through a fake identity source.
local playerIdentity = {
    Resolve = function()
        if Player == nil or not Player.IsAvailable() then return nil end
        local ok, entity = pcall(function() return Player.GetEntity() end)
        if not ok or entity == nil or not entity.isValid then return nil end
        return entity.displayName
    end,
}

local runtime = Runtime.new(nil, nil, playerIdentity)

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

-- The one resident character Scope, or nil when no character is loaded (#90). Holds the character
-- Bucket's live document + restored alerts so the Alert Manager can render that character's tree
-- and the nav owner can resolve a row-open to its live graph. Populated by the bucket loader below
-- (which the runtime calls on first login / a genuine switch) and read live through `getScopes` /
-- `resolveAlert`. Declared before the loader so the closure can capture it.
---@type { key: string, displayName: string, doc: Watchdog.Bucket, alerts: Watchdog.RestoredAlert[] }|nil
local charScope = nil

-- The character-Bucket loader (#89): given a normalized display name, read that character's
-- Bucket off disk and restore its saved alerts as live graphs. The runtime calls this on a
-- genuine character switch (and first login), then arms the returned alerts under the player
-- Bucket. `global` alerts are loaded separately below; this only ever touches `player_<name>`
-- keys, and never runs the global-only legacy migration (Store.LoadKey, not Store.Load).
--
-- It also stashes the loaded document + restored alerts into `charScope` (#90), so the Manager can
-- render this character's Entry tree and the nav owner can bind the Editor to a row's live graph —
-- the *same* live instance the runtime fires, so edits and firing stay in sync. `displayName` is
-- read back off the runtime (which holds the pretty name) once the load has set `_characterBucketKey`.
runtime:SetBucketLoader(function(normalized)
    local key = Store.PlayerKey(normalized)
    local playerDoc = Store.LoadKey(key)
    local restoredChar = {}
    local ok, r = pcall(function() return Store.RestoreAll(playerDoc, registry) end)
    if ok and r ~= nil then restoredChar = r end
    -- The runtime hasn't returned the pretty display name to the loader, so fall back to the
    -- normalized key for the tab label until GetActiveCharacter (read live in getScopes) supplies it.
    charScope = { key = key, displayName = normalized, doc = playerDoc, alerts = restoredChar }
    return restoredChar
end)

--- Graph: restore the saved alerts, or seed a demo on first run --------------------------
-- Persistence backend lives in store.lua: the `global` Bucket, an Entry tree keyed by minted
-- `id` (#86). Every alert leaf restores as a live alert; the editor opens the first one. The
-- multi-alert Manager UI (and per-character buckets) build on this additively.

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

-- `migrationFailed` is set only when the one-shot legacy hop (#87) was attempted and failed:
-- `global` was left unwritten and the legacy key kept for a retry next startup. It gates the demo
-- seed below — seeding would write `global`, permanently closing the retry window and disguising
-- the failure as a fresh install (#81 §7). One-shot: dies with the migration in the #10 follow-up.
local document, migrationFailed = Store.Load()

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
    if #restored == 0 and not migrationFailed then
        -- Fresh install (empty `global` bucket): seed the demo as a single root-level alert Entry.
        -- Suppressed when a legacy migration failed (#87): the Manager stays visibly empty and the
        -- next startup retries from the intact legacy key, instead of the seed papering over it.
        local graph, layout = seedDemo()
        local id = Store.MintId(document)
        Store.InsertEntry(document, Store.NewAlertEntry(id, "default", graph, layout, true))
        Store.Save(document)
        restored = { { id = id, name = "default", graph = graph, layout = layout, enabled = true } }
    end
end

-- Register each restored alert as a live alert the dispatcher fans out over. When the Manager opens
-- one, the Editor binds that same live instance (see navOpenAlert), so its triggers fire mid-edit
-- like the rest; the runtime checks `enabled` at fire time so a disabled alert stays live but silent.
for _, alert in ipairs(restored) do
    runtime:AddAlert(alert.id, alert.name, alert.graph, alert.enabled)
end

-- The Editor is constructed **unbound** (#80): the Manager is the root surface, so a reload lands
-- there with nothing bound, and the persisted `current` pointer is gone entirely — the bound-entry
-- id is now transient (`editor.boundId`, set only when a Manager row is opened). The Editor is
-- mounted once at startup regardless of how many alerts exist (mounting is the fragile part), and a
-- double-click binds it to a live graph. `restored` being empty (a failed legacy migration, #87) is
-- no longer a special dormant path — the surfaces mount either way, the Manager just shows an empty tree.
local editor = Editor.new(registry, runtime)

-- Persistence hook for the alert enable/disable API: SetEnabled/Toggle write the flag straight
-- to the saved document and flush, so an alert toggled off (by the user or an Alert Toggle node,
-- #35) stays off across reloads. Independent of the editor autosave loop below.
runtime:SetPersistence({
    SetEnabled = function(id, enabled)
        Store.SetEnabled(document, id, enabled)
        Store.Save(document)
    end,
})

-- Enabled-chain gate (#88): the runtime ANDs each alert's own `enabled` with whether every
-- ancestor group is enabled. Resolved live over the saved document, so a group toggle or a subtree
-- move re-evaluates on the next fire with nothing cached. A root-level alert has no ancestors and
-- always passes, so this is inert until Groups exist in the tree.
runtime:SetEnabledResolver(function(id)
    return Store.AncestorsEnabled(document, id)
end)

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

--- Alert Manager + Editor↔Manager navigation (#90) --------------------------------------
-- Two surfaces, mounted once, with the nav owner below keeping AT MOST ONE visible so the tree can
-- never be mutated mid-edit. The Manager is the root; the Editor is a depth-1 level opened by a
-- double-click and left via "← Alerts" / Esc. F8 and the menu button toggle *visibility* at the
-- current level — they never navigate (the level is preserved in memory).

-- id-keyed live-graph lookup: given a scope key + entry id, the live Graph + Layout the runtime
-- fires (so binding the Editor to it keeps edits and firing in sync) plus the Bucket doc/key the
-- debounced write-back must target. Global reads `restored` + `document`; the character scope reads
-- the resident `charScope`. nil for an unknown scope/id (a since-deleted or wrong-scope row).
---@param scopeKey string
---@param id integer
---@return { graph: LibNodeGraph.Graph, layout: Watchdog.Layout, doc: Watchdog.Bucket, key: string }|nil
local function resolveAlert(scopeKey, id)
    local list, doc
    if scopeKey == "global" then
        list, doc = restored, document
    elseif charScope ~= nil and charScope.key == scopeKey then
        list, doc = charScope.alerts, charScope.doc
    else
        return nil
    end
    for _, alert in ipairs(list) do
        if alert.id == id then
            return { graph = alert.graph, layout = alert.layout, doc = doc, key = scopeKey }
        end
    end
    return nil
end

-- The Manager's scope provider (#90): `Global` always, plus the resident character second when one
-- is logged in. The character tab's pretty display name comes from the runtime (which holds it),
-- while its tree comes from `charScope.doc`; the two are matched on the Bucket key so a stale
-- `charScope` from a just-departed character is skipped rather than mislabeled.
---@return Watchdog.ManagerScope[]
local function getScopes()
    local scopes = { { key = "global", label = "Global", doc = document } }
    local name, key = runtime:GetActiveCharacter()
    if key ~= nil and charScope ~= nil and charScope.key == key then
        scopes[#scopes + 1] = { key = key, label = name or charScope.displayName, doc = charScope.doc }
    end
    return scopes
end

-- The bound scope's doc + key while an alert is open (nil on the Manager). The debounced write-back
-- keys on this, so an alert opened from the character tab persists back to its own Bucket, not the
-- global one. `boundLastEncoded` diffs that specific doc so an idle editor doesn't re-write.
---@type { doc: Watchdog.Bucket, key: string }|nil
local boundScope = nil
local boundLastEncoded = nil
local persistNow -- forward ref: the debounced bound-entry write-back (assigned below)

-- The nav owner: `level` is which surface is the target (manager root ⇄ editor), `visible` whether
-- the plugin UI is shown at all. `applyNav` is the single place surface visibility is set, so the
-- "at most one visible" invariant holds by construction (the non-target surface is always hidden).
local nav = { level = "manager", visible = false }
local manager -- forward ref (constructed below); applyNav guards on it until then

local function applyNav()
    if manager == nil then return end
    if nav.level == "editor" then
        manager:SetVisible(false)
        editor:SetVisible(nav.visible)
    else
        editor:SetVisible(false)
        manager:SetVisible(nav.visible)
    end
end

-- F8 / menu: hide/show the current level, never navigate (the level stays put in memory).
local function navToggleVisibility()
    nav.visible = not nav.visible
    applyNav()
end

-- A Manager alert row was double-clicked: bind the Editor to that entry's live graph and navigate
-- down to it. Records the bound scope so the write-back targets the right Bucket. A row that no
-- longer resolves (deleted/wrong scope) is a silent no-op — the Manager stays put.
---@param scopeKey string
---@param entryId integer
local function navOpenAlert(scopeKey, entryId)
    local a = resolveAlert(scopeKey, entryId)
    if a == nil then return end
    editor:BindEntry(entryId, a.graph, a.layout)
    boundScope = { doc = a.doc, key = a.key }
    boundLastEncoded = Store.Encode(a.doc)
    nav.level = "editor"
    nav.visible = true
    applyNav()
end

-- Navigate up to the Manager: flush the bound entry to its Bucket, unbind the Editor, drop the
-- bound scope, and show the Manager (visibility carries over — going back doesn't hide the UI).
local function navBack()
    if persistNow ~= nil then pcall(persistNow) end -- flush before unbinding
    editor:Unbind()
    boundScope = nil
    boundLastEncoded = nil
    nav.level = "manager"
    applyNav()
end

editor.onBack = navBack

manager = Manager.new({ scopes = getScopes, onOpenAlert = navOpenAlert })

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
local state = { mounted = false, managerMounted = false, navApplied = false, effectsMounted = false, infoboxMounted = false, screenMarkerMounted = false, infoboxWasDragging = false }

-- Debounced autosave, but only while an alert is **bound and the Editor visible** — that's the only
-- time the graph can be edited, so during normal play (or while on the Manager) we stay off
-- persistentdb entirely instead of re-encoding every couple of seconds. Rather than thread a "dirty"
-- flag through every interaction we periodically re-encode and persist only when the encoding
-- actually changed — graphs are tiny, so this diff is cheap. ~2s cadence at the ~0.02s Logic tick.
-- On the visible -> hidden / unbind transition we flush once so edits made right before leaving
-- aren't lost. The write-back keys on the **bound scope** (`boundScope`), so an alert opened from
-- the character tab persists to its own Bucket, and on `editor.boundId` (never the name — #75).
local SAVE_INTERVAL_TICKS = 100
local saveState = { tick = 0, wasOpen = false }

persistNow = function()
    if editor.boundId == nil or boundScope == nil then return end -- on the Manager: nothing bound
    Store.UpdateAlertGraph(boundScope.doc, editor.boundId, editor.graph, editor:GetLayout())
    local encoded = Store.Encode(boundScope.doc)
    if encoded ~= nil and encoded ~= boundLastEncoded then
        if Store.SaveTo(boundScope.key, boundScope.doc) then
            boundLastEncoded = encoded
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
            -- The drag fronted the InfoBox capture over the active surface's own hit layer so a
            -- fast cursor crossing into it couldn't steal the hover and drop the grab. Now that it's
            -- ended, restore whichever surface is up to the top (each no-ops while hidden, so the
            -- "at most one visible" invariant means only the active one actually re-fronts).
            pcall(function() editor:RaiseToFront() end)
            pcall(function() manager:RaiseToFront() end)
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
        or not state.mounted or not state.managerMounted then
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
            -- The Alert Manager (#90): the second surface, mounted once beside the Editor. Read
            -- success back off IsMounted like the others.
            if not state.managerMounted then
                pcall(function() manager:Mount(parent) end)
                state.managerMounted = manager:IsMounted()
            end
        end
    end

    -- Apply the nav state on the first frame BOTH surfaces are up (whichever mounted first), so the
    -- "at most one visible" invariant is established from the start rather than on the first F8.
    if state.mounted and state.managerMounted and not state.navApplied then
        state.navApplied = true
        applyNav()
    end

    -- The Manager polls every tick like the Editor (double-click timing + scope-change rebuild).
    if state.managerMounted then
        pcall(function() manager:Update() end)
    end

    if not state.mounted then
        return
    end
    pcall(function() editor:update() end)

    -- Persist only during an editing session (an alert bound AND the Editor visible); flush once on
    -- the transition out of it (navigate-back also flushes explicitly before unbinding).
    local isOpen = editor:IsVisible() and editor.boundId ~= nil
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
    pcall(function() manager:Unmount() end)
    state.mounted = false
    state.managerMounted = false
    state.effectsMounted = false
    state.infoboxMounted = false
    state.screenMarkerMounted = false
end

-- Hide/show the whole plugin UI at the current nav level (#80) — the F8 keybind and the menu
-- button both call this. Never navigates: the level (Manager root vs a bound Editor) is preserved.
function api.Toggle()
    navToggleVisibility()
end

api.editor = editor
api.manager = manager
api.document = document  -- the persisted `global` Bucket, exposed for inspection

Event.Logic.Subscribe(Events.Logic, onLogic)
Event.Draw.Subscribe(Events.Draw, onDraw)

-- Hide/show the plugin UI on TOGGLE_KEY (level-preserving); Esc runs the Editor's Esc cascade
-- (popup/marker-capture cancel, else navigate up to the Manager — #80). KeyDown payload has
-- gameKey/isRepeat (core/events docs); ignore auto-repeat so a held key doesn't flicker the panel.
Event.KeyDown.Subscribe(Events.KeyDown, function(keyEvent)
    if keyEvent == nil or keyEvent.isRepeat then return end
    if keyEvent.gameKey == GameKey.ESCAPE then
        -- Esc only means anything on the Editor surface: it dismisses a popup / cancels a marker
        -- capture, or — as the last rung — navigates up. On the Manager (root) there is nowhere to
        -- go up to, so Esc is inert there (the Manager selection-clear rung is #82, not this ticket).
        if nav.level == "editor" and editor:IsVisible() then
            pcall(function() editor:onEscape() end)
        end
        return
    end
    local target = GameKey[TOGGLE_KEY]
    if target ~= nil and keyEvent.gameKey == target then
        navToggleVisibility()
    end
end)

Watchdog = api
print("Watchdog editor loaded")

return Watchdog
