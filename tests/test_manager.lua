-- Exercises the Alert Manager's pure tree/scope/expand logic (ui/manager.lua) — the half that
-- turns a Watchdog.Bucket tree into a flat visible-row list, tracks per-scope collapse state, and
-- resolves the active scope against the injected provider. The mount/render half is client-only
-- (ui.*) and not unit-testable here, exactly like the Editor's Canvas mount; but every decision the
-- renderer reads — row order, indent depth, chevron/child-count, active tab, double-click open — is
-- driven from this pure layer, so it is all assertable headless with a fake scope provider.
--
-- Client/UI globals ui/manager builds constants from at load time (via its Theme require) — stubbed
-- minimally so the module loads under a standalone interpreter.
_G.Vector4 = _G.Vector4 or { new = function(r, g, b, a) return { r, g, b, a } end }

local luaunit = require("luaunit")
local Manager = require("ui/manager")

-- Bucket/Entry builders mirroring store.lua's shapes (the Manager only reads them).
local function alert(id, name, enabled)
    return { id = id, kind = "alert", name = name, enabled = enabled ~= false }
end
local function group(id, name, children, enabled)
    return { id = id, kind = "group", name = name, enabled = enabled ~= false, children = children or {} }
end
local function bucket(entries)
    return { version = 2, entries = entries }
end

TestManager = {}

-- A Manager over a fixed scope list, with the alert-open callback recorded so a test can prove a
-- double-click reports the right (scopeKey, id).
function TestManager:makeManager(scopes)
    local opened = {}
    local mgr = Manager.new({
        scopes = function() return scopes end,
        onOpenAlert = function(scopeKey, id) opened[#opened + 1] = { scopeKey, id } end,
    })
    return mgr, opened
end

--- Scope resolution -----------------------------------------------------------------------

function TestManager:testActiveScopeDefaultsToFirst()
    local mgr = self:makeManager({
        { key = "global", label = "Global", doc = bucket({}) },
        { key = "player_alice", label = "Alice", doc = bucket({}) },
    })
    luaunit.assertEquals(mgr:ActiveScopeKey(), "global")
end

function TestManager:testSetActiveScopeSelectsIt()
    local mgr = self:makeManager({
        { key = "global", label = "Global", doc = bucket({}) },
        { key = "player_alice", label = "Alice", doc = bucket({}) },
    })
    mgr:SetActiveScope("player_alice")
    luaunit.assertEquals(mgr:ActiveScopeKey(), "player_alice")
end

function TestManager:testActiveScopeFallsBackWhenSelectionDeparts()
    -- Selected the character tab, then the character logged out (provider now returns Global only):
    -- the active scope falls back to the first scope rather than pointing at a dead key.
    local scopes = {
        { key = "global", label = "Global", doc = bucket({}) },
        { key = "player_alice", label = "Alice", doc = bucket({}) },
    }
    local mgr = self:makeManager(scopes)
    mgr:SetActiveScope("player_alice")
    scopes[2] = nil -- Alice logs out
    luaunit.assertEquals(mgr:ActiveScopeKey(), "global")
end

function TestManager:testNoScopesYieldsNoRows()
    local mgr = self:makeManager({})
    luaunit.assertNil(mgr:ActiveScope())
    luaunit.assertEquals(mgr:VisibleRows(), {})
end

--- Flattening: order, depth, kinds --------------------------------------------------------

function TestManager:testFlatRootAlertsInOrder()
    local mgr = self:makeManager({
        { key = "global", label = "Global", doc = bucket({ alert(1, "one"), alert(2, "two") }) },
    })
    local rows = mgr:VisibleRows()
    luaunit.assertEquals(#rows, 2)
    luaunit.assertEquals(rows[1].id, 1)
    luaunit.assertEquals(rows[1].kind, "alert")
    luaunit.assertEquals(rows[1].depth, 0)
    luaunit.assertEquals(rows[2].id, 2)
end

function TestManager:testGroupChildrenNestWithDepthAndCount()
    local doc = bucket({
        group(1, "g", { alert(2, "a"), alert(3, "b") }),
        alert(4, "root-alert"),
    })
    local mgr = self:makeManager({ { key = "global", label = "Global", doc = doc } })
    local rows = mgr:VisibleRows()
    -- Pre-order: group, its two children (depth 1), then the root-level alert.
    luaunit.assertEquals(#rows, 4)
    luaunit.assertEquals(rows[1].kind, "group")
    luaunit.assertEquals(rows[1].depth, 0)
    luaunit.assertEquals(rows[1].childCount, 2)
    luaunit.assertEquals(rows[1].expanded, true)     -- groups default expanded
    luaunit.assertEquals(rows[2].id, 2)
    luaunit.assertEquals(rows[2].depth, 1)
    luaunit.assertEquals(rows[3].id, 3)
    luaunit.assertEquals(rows[3].depth, 1)
    luaunit.assertEquals(rows[4].id, 4)
    luaunit.assertEquals(rows[4].depth, 0)
end

function TestManager:testNestedGroupsDeepenDepth()
    local doc = bucket({
        group(1, "outer", { group(2, "inner", { alert(3, "leaf") }) }),
    })
    local mgr = self:makeManager({ { key = "global", label = "Global", doc = doc } })
    local rows = mgr:VisibleRows()
    luaunit.assertEquals(#rows, 3)
    luaunit.assertEquals(rows[1].depth, 0)
    luaunit.assertEquals(rows[2].depth, 1)
    luaunit.assertEquals(rows[3].depth, 2)
    luaunit.assertEquals(rows[3].id, 3)
end

--- Expand / collapse ----------------------------------------------------------------------

function TestManager:testCollapseHidesSubtree()
    local doc = bucket({
        group(1, "g", { alert(2, "a"), group(3, "h", { alert(4, "b") }) }),
        alert(5, "tail"),
    })
    local mgr = self:makeManager({ { key = "global", label = "Global", doc = doc } })
    luaunit.assertEquals(#mgr:VisibleRows(), 5) -- all expanded by default

    mgr:ToggleExpand("global", 1) -- collapse the outer group
    local rows = mgr:VisibleRows()
    -- Only the collapsed group row and the tail alert remain; the whole subtree is gone.
    luaunit.assertEquals(#rows, 2)
    luaunit.assertEquals(rows[1].id, 1)
    luaunit.assertEquals(rows[1].expanded, false)
    luaunit.assertEquals(rows[2].id, 5)
end

function TestManager:testToggleIsPerScope()
    -- Collapsing group id 1 in Global must not collapse a same-id group in the character scope.
    local g = bucket({ group(1, "g", { alert(2, "a") }) })
    local p = bucket({ group(1, "p", { alert(2, "b") }) })
    local scopes = {
        { key = "global", label = "Global", doc = g },
        { key = "player_alice", label = "Alice", doc = p },
    }
    local mgr = self:makeManager(scopes)
    mgr:ToggleExpand("global", 1)
    luaunit.assertEquals(mgr:IsExpanded("global", 1), false)
    luaunit.assertEquals(mgr:IsExpanded("player_alice", 1), true)
end

function TestManager:testToggleBumpsSignature()
    local doc = bucket({ group(1, "g", { alert(2, "a") }) })
    local mgr = self:makeManager({ { key = "global", label = "Global", doc = doc } })
    local before = mgr:_signature()
    mgr:ToggleExpand("global", 1)
    luaunit.assertNotEquals(mgr:_signature(), before)
end

--- Row activation (double-click open / group toggle) --------------------------------------

function TestManager:testActivateAlertRowReportsOpen()
    local doc = bucket({ alert(7, "a") })
    local mgr, opened = self:makeManager({ { key = "global", label = "Global", doc = doc } })
    local row = mgr:VisibleRows()[1]
    mgr:_activateRow("global", row)
    luaunit.assertEquals(opened, { { "global", 7 } })
end

function TestManager:testActivateGroupRowTogglesInsteadOfOpening()
    local doc = bucket({ group(9, "g", { alert(1, "a") }) })
    local mgr, opened = self:makeManager({ { key = "global", label = "Global", doc = doc } })
    local row = mgr:VisibleRows()[1]
    mgr:_activateRow("global", row)
    luaunit.assertEquals(opened, {})                 -- a group never opens the editor
    luaunit.assertEquals(mgr:IsExpanded("global", 9), false)
end

function TestManager:testActivateReportsCharacterScopeKey()
    local doc = bucket({ alert(3, "a") })
    local mgr, opened = self:makeManager({
        { key = "global", label = "Global", doc = bucket({}) },
        { key = "player_alice", label = "Alice", doc = doc },
    })
    mgr:SetActiveScope("player_alice")
    local row = mgr:VisibleRows()[1]
    mgr:_activateRow("player_alice", row)
    luaunit.assertEquals(opened, { { "player_alice", 3 } })
end

--- Row label rendering --------------------------------------------------------------------

function TestManager:testRowLabelAlert()
    local mgr = self:makeManager({})
    local label = mgr:RowLabel({ id = 1, name = "Boss timer", kind = "alert", depth = 0 })
    luaunit.assertStrContains(label, "Boss timer")
    luaunit.assertStrContains(label, "•")
end

function TestManager:testRowLabelGroupShowsChevronAndCount()
    local mgr = self:makeManager({})
    local open = mgr:RowLabel({ id = 1, name = "PvM", kind = "group", depth = 0, childCount = 3, expanded = true })
    luaunit.assertStrContains(open, "▾")
    luaunit.assertStrContains(open, "PvM")
    luaunit.assertStrContains(open, "(3)")
    local closed = mgr:RowLabel({ id = 1, name = "PvM", kind = "group", depth = 0, childCount = 3, expanded = false })
    luaunit.assertStrContains(closed, "▸")
end

function TestManager:testRowLabelIndentsByDepth()
    local mgr = self:makeManager({})
    local shallow = mgr:RowLabel({ id = 1, name = "x", kind = "alert", depth = 0 })
    local deep = mgr:RowLabel({ id = 1, name = "x", kind = "alert", depth = 2 })
    luaunit.assertTrue(#deep > #shallow) -- deeper rows carry more leading indent
end

--- Window drag: header hit-test (the one pure part of the client-only drag path) -----------

-- _inHeader gates whether a press on the capture layer starts a window drag. Pure rect test in
-- absolute coords, so assertable headless even though the rest of the drag path is client-only.
function TestManager:testInHeaderHitTest()
    local mgr = self:makeManager({})
    mgr.window = { x = 100, y = 200, w = 300, h = 400 }
    local headerBottom = 200 + require("ui/theme").WINDOW_HEADER_H
    luaunit.assertTrue(mgr:_inHeader(150, 205))                 -- inside the header band
    luaunit.assertTrue(mgr:_inHeader(100, 200))                 -- top-left corner (inclusive)
    luaunit.assertFalse(mgr:_inHeader(150, headerBottom + 5))   -- below the header (body) -> no drag
    luaunit.assertFalse(mgr:_inHeader(50, 205))                 -- left of the window -> no drag
    luaunit.assertFalse(mgr:_inHeader(450, 205))               -- right of the window -> no drag
end
