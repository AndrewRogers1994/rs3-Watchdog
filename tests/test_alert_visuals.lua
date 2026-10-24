-- Disabling or deleting an alert drops the overlay visuals its nodes spawned (TODO 16).
-- Seams are the public Runtime methods. Visuals are observed through InfoBox, Toast, and
-- EffectRegistry, the same objects the nodes draw into.

local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local Runtime = require("src/runtime")
local Effects = require("src/effects")
local InfoBox = require("src/ui/infobox")
local Toast = require("src/toast")
local newFakeEventSource = require("fake_event_source")

TestAlertVisuals = {}

function TestAlertVisuals:setUp()
    self.registry = Registry.new()
    self.registry:RegisterNodeType("fixture.visual", {
        category = "action",
        pins = {},
        run = function() end,
    })
    local effects = Effects.new()
    local infobox = InfoBox.new()
    local toast = Toast.new(effects)
    self.runtime = Runtime.new(newFakeEventSource().source)
    self.runtime.effects = effects
    self.runtime.infobox = infobox
    self.runtime.toast = toast
end

-- One node whose state table owns an infobox tile, a toast, a stacked effect handle,
-- and a queued popup stamped with that same state. Mirrors what the action nodes key on.
local function spawnVisualAlert(runtime, registry, id, name, enabled)
    local graph = Graph.new(registry)
    local nodeId = graph:AddNode("fixture.visual")
    local state = graph:GetState(nodeId)
    local spawned = {
        graph = graph,
        nodeId = nodeId,
        state = state,
        popupDismissed = false,
        popupUpdates = 0,
    }

    runtime.infobox:Set(state, { text = "9", title = name })
    runtime.toast:Show(state, { text = name })

    local handle = {
        kind = "marker",
        state = {},
        update = function() return true end,
        draw = function() end,
    }
    state.handle = handle
    runtime.effects:PushStack(state, handle, 1)
    spawned.handle = handle

    local popup = {
        kind = "popup",
        source = state,
        state = {},
        update = function()
            spawned.popupUpdates = spawned.popupUpdates + 1
            return true
        end,
        draw = function() end,
        onDone = function() spawned.popupDismissed = true end,
    }
    runtime.effects:PushQueue("action.popup", popup)
    spawned.popup = popup

    runtime:AddAlert(id, name, graph, enabled ~= false)
    return spawned
end

function TestAlertVisuals:testDisablingByIdClearsThatAlertsVisualsOnly()
    local disabled = spawnVisualAlert(self.runtime, self.registry, 1, "Low health")
    local kept = spawnVisualAlert(self.runtime, self.registry, 2, "Food")

    luaunit.assertTrue(self.runtime:SetAlertEnabled(1, false))

    luaunit.assertFalse(self.runtime.infobox:Has(disabled.state))
    luaunit.assertTrue(self.runtime.infobox:Has(kept.state))

    luaunit.assertEquals(self.runtime.toast:LiveCount(), 1)
    self.runtime.toast:Dismiss(kept.state)
    luaunit.assertEquals(self.runtime.toast:LiveCount(), 0)

    luaunit.assertEquals(self.runtime.effects:StackCount(disabled.state), 0)
    luaunit.assertNil(disabled.state.handle)
    luaunit.assertEquals(self.runtime.effects:StackCount(kept.state), 1)

    luaunit.assertTrue(disabled.popupDismissed)
    luaunit.assertFalse(kept.popupDismissed)
    self.runtime.effects:Update(0)
    luaunit.assertEquals(kept.popupUpdates, 1)
    luaunit.assertEquals(disabled.popupUpdates, 0)
end

function TestAlertVisuals:testEnablingByIdLeavesVisualsUp()
    local alert = spawnVisualAlert(self.runtime, self.registry, 1, "Low health")

    luaunit.assertTrue(self.runtime:SetAlertEnabled(1, true))

    luaunit.assertTrue(self.runtime.infobox:Has(alert.state))
    luaunit.assertEquals(self.runtime.toast:LiveCount(), 1)
    luaunit.assertEquals(self.runtime.effects:StackCount(alert.state), 1)
    luaunit.assertFalse(alert.popupDismissed)
end

function TestAlertVisuals:testReenableDoesNotRestoreClearedVisuals()
    local alert = spawnVisualAlert(self.runtime, self.registry, 1, "Low health")
    local kept = spawnVisualAlert(self.runtime, self.registry, 2, "Food")

    luaunit.assertTrue(self.runtime:SetAlertEnabled(1, false))
    luaunit.assertTrue(self.runtime:SetAlertEnabled(1, true))

    luaunit.assertFalse(self.runtime.infobox:Has(alert.state))
    luaunit.assertTrue(self.runtime.infobox:Has(kept.state))
    luaunit.assertEquals(self.runtime.toast:LiveCount(), 1)
    luaunit.assertEquals(self.runtime.effects:StackCount(alert.state), 0)
    luaunit.assertTrue(alert.popupDismissed)
    luaunit.assertFalse(kept.popupDismissed)
end

function TestAlertVisuals:testDisablingByNameClearsEveryMatch()
    local first = spawnVisualAlert(self.runtime, self.registry, 1, "Low health")
    local second = spawnVisualAlert(self.runtime, self.registry, 2, "Low health")
    local other = spawnVisualAlert(self.runtime, self.registry, 3, "Food")

    luaunit.assertTrue(self.runtime:SetEnabled("Low health", false))

    luaunit.assertFalse(self.runtime.infobox:Has(first.state))
    luaunit.assertFalse(self.runtime.infobox:Has(second.state))
    luaunit.assertTrue(self.runtime.infobox:Has(other.state))
    luaunit.assertEquals(self.runtime.toast:LiveCount(), 1)
    luaunit.assertTrue(first.popupDismissed)
    luaunit.assertTrue(second.popupDismissed)
    luaunit.assertFalse(other.popupDismissed)
end

function TestAlertVisuals:testToggleOntoFalseClearsAndOntoTrueDoesNot()
    local turningOff = spawnVisualAlert(self.runtime, self.registry, 1, "Low health")
    local turningOn = spawnVisualAlert(self.runtime, self.registry, 2, "Food", false)

    luaunit.assertEquals(self.runtime:Toggle("Low health"), 1)
    luaunit.assertEquals(self.runtime:Toggle("Food"), 1)

    luaunit.assertFalse(self.runtime.infobox:Has(turningOff.state))
    luaunit.assertTrue(self.runtime.infobox:Has(turningOn.state))
    luaunit.assertTrue(turningOff.popupDismissed)
    luaunit.assertFalse(turningOn.popupDismissed)
    luaunit.assertEquals(self.runtime.toast:LiveCount(), 1)
end

function TestAlertVisuals:testReleaseAlertVisualsClearsAndLeavesTheAlertLive()
    local released = spawnVisualAlert(self.runtime, self.registry, 1, "Low health")
    local kept = spawnVisualAlert(self.runtime, self.registry, 2, "Food")

    luaunit.assertTrue(self.runtime:ReleaseAlertVisuals(1))

    luaunit.assertFalse(self.runtime.infobox:Has(released.state))
    luaunit.assertTrue(self.runtime.infobox:Has(kept.state))
    luaunit.assertTrue(released.popupDismissed)
    luaunit.assertFalse(kept.popupDismissed)
    luaunit.assertEquals(#self.runtime.alerts, 2)
    luaunit.assertTrue(self.runtime.alerts[1].enabled)
    luaunit.assertFalse(self.runtime:ReleaseAlertVisuals(999))
end

function TestAlertVisuals:testRemoveAlertKeepsSpawnedVisuals()
    local moved = spawnVisualAlert(self.runtime, self.registry, 1, "Low health")

    luaunit.assertTrue(self.runtime:RemoveAlert(1))

    luaunit.assertTrue(self.runtime.infobox:Has(moved.state))
    luaunit.assertEquals(self.runtime.toast:LiveCount(), 1)
    luaunit.assertEquals(self.runtime.effects:StackCount(moved.state), 1)
    luaunit.assertFalse(moved.popupDismissed)
    luaunit.assertEquals(#self.runtime.alerts, 0)
end
