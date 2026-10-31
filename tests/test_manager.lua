-- Alert Manager pure tree/scope/expand logic (ui/manager.lua). Mount/render is client-only
-- (ui.*) and not unit-testable here; row order, indent, chevron, active tab, double-click
-- open are assertable headless with a fake scope provider.
--
-- Client/UI globals ui/manager builds from Theme at load time - stubbed so the module loads.
_G.Vector4 = _G.Vector4 or { new = function(r, g, b, a) return { r, g, b, a } end }

local luaunit = require("luaunit")
local Manager = require("src/ui/manager")
local Confirm = require("src/ui/confirm")

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
-- double-click reports the right (scopeKey, id). Optional `extras` injects the #91 mutation
-- callbacks (onToggleEnabled / onRename / onDelete / onCreateAlert / onCreateGroup).
function TestManager:makeManager(scopes, extras)
    local opened = {}
    local opts = {
        scopes = function() return scopes end,
        onOpenAlert = function(scopeKey, id) opened[#opened + 1] = { scopeKey, id } end,
    }
    if extras ~= nil then
        for k, v in pairs(extras) do opts[k] = v end
    end
    local mgr = Manager.new(opts)
    return mgr, opened
end

function TestManager:tearDown()
    if self._dialogMgr ~= nil then
        self._dialogMgr:DismissDialogs()
        self._dialogMgr = nil
    end
    if self._savedHost ~= nil then
        ui = self._savedHost.ui
        prettyui = self._savedHost.prettyui
        self._savedHost = nil
    end
end

local function installDialogHost(test)
    test._savedHost = { ui = ui, prettyui = prettyui }
    local windows = {}
    ui = {
        Layer = { new = function()
            local layer = {}
            function layer:SetPos() end
            function layer:SetSize() end
            function layer:MoveToFront() end
            function layer:Destroy() end
            return layer
        end },
        Rectangle = { new = function()
            local rect = {}
            function rect:SetPos() end
            function rect:SetSize() end
            return rect
        end },
    }
    prettyui = {
        FancyButton = { getSize = function() return 80, 27 end },
        Window = { new = function(_parent, options)
            local win = {
                title = options.title,
                onClose = options.onClose,
                buttons = {},
                texts = {},
                fields = {},
                destroyed = false,
            }
            function win:AddText(text)
                local widget = { content = text }
                self.texts[#self.texts + 1] = widget
                return widget
            end
            function win:AddTextField(opts)
                local field = { text = opts.text or "", opts = opts }
                function field:GetText() return self.text end
                self.fields[#self.fields + 1] = field
                return field
            end
            function win:AddFancyButton(label, action, opts)
                local button = { label = label, action = action, opts = opts }
                self.buttons[#self.buttons + 1] = button
                return button
            end
            function win:Show() end
            function win:MoveToFront() end
            function win:Destroy() self.destroyed = true end
            windows[#windows + 1] = win
            return win
        end },
    }
    return windows
end

local function dialogButton(win, label)
    for _, button in ipairs(win.buttons) do
        if button.label == label then return button end
    end
    return nil
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
    mgr:ToggleExpand("global", 1)
    local rows = mgr:VisibleRows()
    -- Pre-order: group, its two children (depth 1), then the root-level alert.
    luaunit.assertEquals(#rows, 4)
    luaunit.assertEquals(rows[1].kind, "group")
    luaunit.assertEquals(rows[1].depth, 0)
    luaunit.assertEquals(rows[1].childCount, 2)
    luaunit.assertEquals(rows[1].expanded, true)
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
    mgr:ToggleExpand("global", 1)
    mgr:ToggleExpand("global", 2)
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
    mgr:ToggleExpand("global", 1)
    mgr:ToggleExpand("global", 3)
    luaunit.assertEquals(#mgr:VisibleRows(), 5)

    mgr:ToggleExpand("global", 1)
    local rows = mgr:VisibleRows()
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
    luaunit.assertEquals(mgr:IsExpanded("global", 1), false)
    luaunit.assertEquals(mgr:IsExpanded("player_alice", 1), false)
    mgr:ToggleExpand("global", 1)
    luaunit.assertEquals(mgr:IsExpanded("global", 1), true)
    luaunit.assertEquals(mgr:IsExpanded("player_alice", 1), false)
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
    luaunit.assertEquals(mgr:IsExpanded("global", 9), false)
    local row = mgr:VisibleRows()[1]
    mgr:_activateRow("global", row)
    luaunit.assertEquals(opened, {})
    luaunit.assertEquals(mgr:IsExpanded("global", 9), true)
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
    luaunit.assertEquals(label, "Boss timer")
end

function TestManager:testRowLabelGroupShowsChevronAndCount()
    local mgr = self:makeManager({})
    local open = mgr:RowLabel({ id = 1, name = "PvM", kind = "group", depth = 0, childCount = 3, expanded = true })
    luaunit.assertStrContains(open, "v")
    luaunit.assertStrContains(open, "PvM")
    luaunit.assertStrContains(open, "(3 items)")
    local closed = mgr:RowLabel({ id = 1, name = "PvM", kind = "group", depth = 0, childCount = 3, expanded = false })
    luaunit.assertStrContains(closed, ">")
end

function TestManager:testRowLabelIndentsByDepth()
    -- Nesting indent is layout (ROW_INDENT on the name button), not leading spaces in the label.
    local mgr = self:makeManager({})
    local shallow = mgr:RowLabel({ id = 1, name = "x", kind = "alert", depth = 0 })
    local deep = mgr:RowLabel({ id = 1, name = "x", kind = "alert", depth = 2 })
    luaunit.assertEquals(shallow, deep)
end

--- Row editing ops (#91): host callbacks + signature bump ---------------------------------
-- Manager mutations go through injected host callbacks (main.lua wires Store + Runtime). The
-- pure half only reports the op + bumps mutateVersion so the view rebuilds; the host mutates
-- the shared Bucket doc the scopes provider already returns.

function TestManager:testToggleEnabledReportsActiveScopeAndId()
    local calls = {}
    local doc = bucket({ alert(7, "a", true) })
    local mgr = self:makeManager(
        { { key = "global", label = "Global", doc = doc } },
        { onToggleEnabled = function(scopeKey, id) calls[#calls + 1] = { scopeKey, id } end }
    )
    local before = mgr:_signature()
    mgr:ToggleEnabled(7)
    luaunit.assertEquals(calls, { { "global", 7 } })
    luaunit.assertNotEquals(mgr:_signature(), before)
end

function TestManager:testRenameStripsClientTextTagsBeforeReporting()
    local calls = {}
    local doc = bucket({ alert(3, "old") })
    local mgr = self:makeManager(
        { { key = "global", label = "Global", doc = doc } },
        { onRename = function(scopeKey, id, name) calls[#calls + 1] = { scopeKey, id, name } end }
    )
    mgr:Rename(3, "<col=ff0000>new</col>")
    luaunit.assertEquals(calls, { { "global", 3, "new" } })
    mgr:Rename(3, "<col=ff0000>")
    luaunit.assertEquals(calls, { { "global", 3, "new" } })
end

function TestManager:testRenameReportsActiveScopeIdAndName()
    local calls = {}
    local doc = bucket({ alert(3, "old") })
    local mgr = self:makeManager(
        { { key = "global", label = "Global", doc = doc } },
        { onRename = function(scopeKey, id, name) calls[#calls + 1] = { scopeKey, id, name } end }
    )
    mgr:Rename(3, "new")
    luaunit.assertEquals(calls, { { "global", 3, "new" } })
end

function TestManager:testRenameLeavesTheSignatureWhenTheSaveFails()
    local doc = bucket({ alert(3, "old") })
    local mgr = self:makeManager(
        { { key = "global", label = "Global", doc = doc } },
        { onRename = function() return false end }
    )
    local before = mgr:_signature()
    luaunit.assertFalse(mgr:Rename(3, "new"))
    luaunit.assertEquals(mgr:_signature(), before)
end

function TestManager:testOpenRenameDoesNothingWithoutADialogParent()
    local calls = {}
    local mgr = self:makeManager(
        { { key = "global", label = "Global", doc = bucket({ alert(3, "old") }) } },
        { onRename = function() calls[#calls + 1] = true end }
    )
    mgr:_openRename(3)
    mgr:_openRename(99)
    luaunit.assertEquals(calls, {})
end

function TestManager:testOpenRenameUsesTheEditorDialog()
    local windows = installDialogHost(self)
    local parent = {}
    local calls = {}
    local doc = bucket({ alert(3, "Gatehouse"), group(9, "Pack", {}) })
    local mgr = self:makeManager(
        { { key = "global", label = "Global", doc = doc } },
        {
            windowParent = function() return parent end,
            onRename = function(scopeKey, id, name)
                calls[#calls + 1] = { scopeKey, id, name }
                return true
            end,
        }
    )
    self._dialogMgr = mgr

    mgr:_openRename(99)
    luaunit.assertEquals(windows, {})

    mgr:_openRename(3)
    local alertDialog = windows[1]
    luaunit.assertEquals(alertDialog.title, "Rename alert")
    luaunit.assertEquals(alertDialog.texts[1].content, "Alert name")
    luaunit.assertEquals(alertDialog.fields[1].text, "Gatehouse")
    luaunit.assertEquals(alertDialog.fields[1].opts.maxLength, 80)

    alertDialog.fields[1].text = "   "
    dialogButton(alertDialog, "Save").action()
    luaunit.assertEquals(calls, {})
    luaunit.assertEquals(alertDialog.texts[2].content, "Enter an alert name.")
    luaunit.assertFalse(alertDialog.destroyed)

    alertDialog.fields[1].text = "  <col=ff0000>Horn</col>  "
    dialogButton(alertDialog, "Save").action()
    luaunit.assertEquals(calls, { { "global", 3, "Horn" } })
    luaunit.assertTrue(alertDialog.destroyed)

    mgr:_openRename(9)
    local groupDialog = windows[2]
    luaunit.assertEquals(groupDialog.title, "Rename group")
    luaunit.assertEquals(groupDialog.texts[1].content, "Group name")
    luaunit.assertEquals(groupDialog.fields[1].text, "Pack")
    groupDialog.fields[1].text = ""
    dialogButton(groupDialog, "Save").action()
    luaunit.assertEquals(groupDialog.texts[2].content, "Enter a group name.")
    dialogButton(groupDialog, "Cancel").action()
    luaunit.assertTrue(groupDialog.destroyed)
    luaunit.assertEquals(#calls, 1)
end

function TestManager:testOpenRenameStaysOpenWhenTheSaveFails()
    local windows = installDialogHost(self)
    local parent = {}
    local mgr = self:makeManager(
        { { key = "global", label = "Global", doc = bucket({ alert(3, "Gatehouse") }) } },
        {
            windowParent = function() return parent end,
            onRename = function() return false end,
        }
    )
    self._dialogMgr = mgr
    mgr:_openRename(3)
    local dialog = windows[1]
    dialog.fields[1].text = "Horn"
    dialogButton(dialog, "Save").action()
    luaunit.assertEquals(dialog.texts[2].content, "Could not save the name. Try again.")
    luaunit.assertFalse(dialog.destroyed)
end

function TestManager:testDeleteReportsActiveScopeAndId()
    local calls = {}
    local doc = bucket({ alert(5, "a") })
    local mgr = self:makeManager(
        { { key = "global", label = "Global", doc = doc } },
        { onDelete = function(scopeKey, id) calls[#calls + 1] = { scopeKey, id } end }
    )
    mgr:Delete(5)
    luaunit.assertEquals(calls, { { "global", 5 } })
end

function TestManager:testCreateAlertReportsActiveScope()
    local calls = {}
    local mgr = self:makeManager(
        {
            { key = "global", label = "Global", doc = bucket({}) },
            { key = "player_alice", label = "Alice", doc = bucket({}) },
        },
        { onCreateAlert = function(scopeKey) calls[#calls + 1] = scopeKey end }
    )
    mgr:SetActiveScope("player_alice")
    mgr:CreateAlert()
    luaunit.assertEquals(calls, { "player_alice" })
end

function TestManager:testCreateGroupReportsActiveScope()
    local calls = {}
    local mgr = self:makeManager(
        { { key = "global", label = "Global", doc = bucket({}) } },
        { onCreateGroup = function(scopeKey) calls[#calls + 1] = scopeKey end }
    )
    mgr:CreateGroup()
    luaunit.assertEquals(calls, { "global" })
end

function TestManager:testMutationNoOpsWithoutActiveScope()
    local calls = {}
    local mgr = self:makeManager({}, {
        onToggleEnabled = function() calls[#calls + 1] = "toggle" end,
        onRename = function() calls[#calls + 1] = "rename" end,
        onDelete = function() calls[#calls + 1] = "delete" end,
        onCreateAlert = function() calls[#calls + 1] = "alert" end,
        onCreateGroup = function() calls[#calls + 1] = "group" end,
    })
    mgr:ToggleEnabled(1)
    mgr:Rename(1, "x")
    mgr:Delete(1)
    mgr:CreateAlert()
    mgr:CreateGroup()
    luaunit.assertEquals(calls, {})
end

function TestManager:testHostMutationReflectedInVisibleRows()
    -- Shared-doc seam: host mutates the Bucket the provider already returns; after the Manager
    -- bumps its signature the next VisibleRows read sees the change (no Manager-owned copy).
    local doc = bucket({ alert(1, "alpha", true) })
    local mgr = self:makeManager(
        { { key = "global", label = "Global", doc = doc } },
        {
            onToggleEnabled = function(_, id)
                doc.entries[1].enabled = not doc.entries[1].enabled
            end,
            onRename = function(_, id, name)
                doc.entries[1].name = name
            end,
            onDelete = function(_, id)
                doc.entries = {}
            end,
        }
    )
    mgr:ToggleEnabled(1)
    luaunit.assertEquals(mgr:VisibleRows()[1].enabled, false)
    mgr:Rename(1, "beta")
    luaunit.assertEquals(mgr:VisibleRows()[1].name, "beta")
    mgr:Delete(1)
    luaunit.assertEquals(mgr:VisibleRows(), {})
end

function TestManager:testRowMoveCapsAtRoot()
    local doc = bucket({ alert(1, "a"), alert(2, "b"), alert(3, "c") })
    local mgr = self:makeManager({ { key = "global", label = "Global", doc = doc } })
    local u1, d1, l1 = mgr:RowMoveCaps(1)
    local u2, d2, l2 = mgr:RowMoveCaps(2)
    local u3, d3, l3 = mgr:RowMoveCaps(3)
    luaunit.assertEquals({ u1, d1, l1 }, { false, true, false })
    luaunit.assertEquals({ u2, d2, l2 }, { true, true, false })
    luaunit.assertEquals({ u3, d3, l3 }, { true, false, false })
end

function TestManager:testRowMoveCapsNestedCanLift()
    local doc = bucket({
        group(10, "g", { alert(1, "child"), alert(2, "sib") }),
        alert(3, "root"),
    })
    local mgr = self:makeManager({ { key = "global", label = "Global", doc = doc } })
    local u1, d1, l1 = mgr:RowMoveCaps(1)
    local u2, d2, l2 = mgr:RowMoveCaps(2)
    local u10, d10, l10 = mgr:RowMoveCaps(10)
    luaunit.assertEquals({ u1, d1, l1 }, { false, true, true })
    luaunit.assertEquals({ u2, d2, l2 }, { true, false, true })
    luaunit.assertEquals({ u10, d10, l10 }, { false, true, false })
end

function TestManager:testReorderSiblingReportsDelta()
    local calls = {}
    local doc = bucket({ alert(1, "a"), alert(2, "b") })
    local mgr = self:makeManager(
        { { key = "global", label = "Global", doc = doc } },
        {
            onReorderSibling = function(scopeKey, id, delta)
                calls[#calls + 1] = { scopeKey, id, delta }
            end,
        }
    )
    mgr:ReorderSibling(2, -1)
    luaunit.assertEquals(calls, { { "global", 2, -1 } })
end

function TestManager:testLiftReportsActiveScopeAndId()
    local calls = {}
    local doc = bucket({ group(10, "g", { alert(1, "child") }) })
    local mgr = self:makeManager(
        { { key = "global", label = "Global", doc = doc } },
        { onLift = function(scopeKey, id) calls[#calls + 1] = { scopeKey, id } end }
    )
    mgr:Lift(1)
    luaunit.assertEquals(calls, { { "global", 1 } })
end

function TestManager:testLoadedGroupsStartCollapsed()
    local doc = bucket({
        group(1, "outer", { group(2, "inner", { alert(3, "leaf") }), alert(4, "sib") }),
        alert(5, "root"),
    })
    local mgr = self:makeManager({ { key = "global", label = "Global", doc = doc } })
    luaunit.assertEquals(mgr:IsExpanded("global", 1), false)
    luaunit.assertEquals(mgr:IsExpanded("global", 2), false)
    local rows = mgr:VisibleRows()
    luaunit.assertEquals(#rows, 2)
    luaunit.assertEquals(rows[1].id, 1)
    luaunit.assertEquals(rows[1].expanded, false)
    luaunit.assertEquals(rows[2].id, 5)

    mgr:ToggleExpand("global", 1)
    rows = mgr:VisibleRows()
    luaunit.assertEquals(#rows, 4)
    luaunit.assertEquals(rows[2].id, 2)
    luaunit.assertEquals(rows[2].expanded, false)
    luaunit.assertEquals(rows[3].id, 4)
end

function TestManager:testCreateGroupStartsExpanded()
    local doc = bucket({})
    local mgr = self:makeManager(
        { { key = "global", label = "Global", doc = doc } },
        {
            onCreateGroup = function()
                doc.entries[1] = group(42, "New Group", { alert(7, "a") })
                return 42
            end,
        }
    )
    luaunit.assertEquals(mgr:CreateGroup(), 42)
    luaunit.assertEquals(mgr:IsExpanded("global", 42), true)
    local rows = mgr:VisibleRows()
    luaunit.assertEquals(#rows, 2)
    luaunit.assertEquals(rows[1].expanded, true)
    luaunit.assertEquals(rows[2].id, 7)
end

function TestManager:testBulkNewGroupStartsExpanded()
    local doc = bucket({ alert(1, "a"), alert(2, "b") })
    local mgr = self:makeManager(
        { { key = "global", label = "Global", doc = doc } },
        {
            onBulkNewGroup = function()
                doc.entries = { group(99, "New Group", { alert(1, "a"), alert(2, "b") }) }
                return 99
            end,
        }
    )
    mgr:ToggleSelection(1, false)
    mgr:ToggleSelection(2, false)
    luaunit.assertEquals(mgr:BulkNewGroup(), 99)
    luaunit.assertEquals(mgr:IsExpanded("global", 99), true)
    luaunit.assertEquals(#mgr:VisibleRows(), 3)
    luaunit.assertEquals(mgr:VisibleRows()[1].expanded, true)
end

function TestManager:testCreateGroupReturnsMintedIdFromHost()
    local mgr = self:makeManager(
        { { key = "global", label = "Global", doc = bucket({}) } },
        { onCreateGroup = function() return 42 end }
    )
    luaunit.assertEquals(mgr:CreateGroup(), 42)
end

function TestManager:testBulkNewGroupClearsSelection()
    local doc = bucket({ alert(1, "a"), alert(2, "b") })
    local mgr = self:makeManager(
        { { key = "global", label = "Global", doc = doc } },
        { onBulkNewGroup = function() return 99 end }
    )
    mgr:ToggleSelection(1, false)
    mgr:ToggleSelection(2, false)
    luaunit.assertEquals(mgr:BulkNewGroup(), 99)
    luaunit.assertFalse(mgr:HasSelection())
    luaunit.assertNil(mgr.lastSelectId)
end

function TestManager:testConfirmDefaultsTitleAndConfirmLabel()
    local opts = Confirm.resolve({})
    luaunit.assertEquals(opts.title, "CONFIRM")
    luaunit.assertEquals(opts.confirmLabel, "CONFIRM")
    luaunit.assertTrue(opts.modal)
    luaunit.assertFalse(Confirm.resolve({ modal = false }).modal)
end

function TestManager:testDeleteConfirmBodyDisclosesDescendantCount()
    local doc = bucket({
        group(1, "g", { alert(2, "a"), group(3, "inner", { alert(4, "b") }) }),
        alert(5, "leaf"),
        group(6, "empty", {}),
    })
    local mgr = self:makeManager({ { key = "global", label = "Global", doc = doc } })
    luaunit.assertEquals(mgr:_descendantCount(1), 3) -- a + inner + b
    luaunit.assertEquals(
        mgr:_deleteConfirmBody(1),
        'Delete "g" and 3 items inside it? This cannot be undone.'
    )
    luaunit.assertEquals(mgr:_deleteConfirmBody(5), 'Delete "leaf"? This cannot be undone.')
    luaunit.assertEquals(mgr:_deleteConfirmBody(6), 'Delete "empty"? This cannot be undone.')
end

function TestManager:testBulkDeleteConfirmBodyDisclosesRideAlongCount()
    local doc = bucket({
        group(1, "g", { alert(2, "a"), group(3, "inner", { alert(4, "b") }) }),
        alert(5, "leaf"),
    })
    local mgr = self:makeManager({ { key = "global", label = "Global", doc = doc } })
    mgr:ToggleSelection(5, false)
    luaunit.assertEquals(mgr:_bulkDeleteConfirmBody(), "Delete 1 selected?")
    mgr:ClearSelection()
    mgr:ToggleSelection(1, false)
    mgr:ToggleSelection(5, false)
    luaunit.assertEquals(
        mgr:_bulkDeleteConfirmBody(),
        "Delete 2 selected? This also deletes 3 contained items."
    )
end

--- PrettyUI chrome helpers (pure; mount/render still client-only) -------------------------

function TestManager:testScopeTabsSignatureTracksKeysAndLabels()
    local scopes = {
        { key = "global", label = "Global", doc = bucket({}) },
        { key = "player_alice", label = "Alice", doc = bucket({}) },
    }
    local mgr = self:makeManager(scopes)
    luaunit.assertEquals(mgr:_scopeTabsSignature(), "global:Global|player_alice:Alice")
    scopes[2].label = "Alicia"
    luaunit.assertEquals(mgr:_scopeTabsSignature(), "global:Global|player_alice:Alicia")
    scopes[2] = nil
    luaunit.assertEquals(mgr:_scopeTabsSignature(), "global:Global")
end

function TestManager:testActiveScopeIndexFollowsSelection()
    local mgr = self:makeManager({
        { key = "global", label = "Global", doc = bucket({}) },
        { key = "player_alice", label = "Alice", doc = bucket({}) },
    })
    luaunit.assertEquals(mgr:_activeScopeIndex(), 1)
    mgr:SetActiveScope("player_alice")
    luaunit.assertEquals(mgr:_activeScopeIndex(), 2)
end

--- Multi-select (#93): antichain, shift-range, clear-on-collapse / scope-switch -------------
-- Selection is a group-as-unit antichain over VisibleRows() order. Pure seam: ToggleSelection /
-- NormalizeSelection / ClearSelection / SelectedIds / HasSelection; clear on scope switch and
-- on collapse of a group that contains a selected id.

local function selectedSet(mgr)
    local set = {}
    for _, id in ipairs(mgr:SelectedIds()) do set[id] = true end
    return set
end

function TestManager:testSelectionStartsEmpty()
    local mgr = self:makeManager({
        { key = "global", label = "Global", doc = bucket({ alert(1, "a") }) },
    })
    luaunit.assertFalse(mgr:HasSelection())
    luaunit.assertEquals(mgr:SelectedIds(), {})
end

function TestManager:testToggleSelectionAddsAndRemoves()
    local doc = bucket({ alert(1, "a"), alert(2, "b") })
    local mgr = self:makeManager({ { key = "global", label = "Global", doc = doc } })
    mgr:ToggleSelection(1, false)
    luaunit.assertTrue(mgr:HasSelection())
    luaunit.assertEquals(selectedSet(mgr), { [1] = true })
    mgr:ToggleSelection(1, false)
    luaunit.assertFalse(mgr:HasSelection())
    luaunit.assertEquals(mgr:SelectedIds(), {})
end

function TestManager:testToggleSelectionBumpsSelectVersionInSignature()
    local mgr = self:makeManager({
        { key = "global", label = "Global", doc = bucket({ alert(1, "a") }) },
    })
    local before = mgr:_signature()
    mgr:ToggleSelection(1, false)
    luaunit.assertNotEquals(mgr:_signature(), before)
end

function TestManager:testNormalizeSelectionDropsDescendantsOfSelectedGroup()
    -- Group-as-unit antichain: selecting a group represents its subtree; no descendant stays
    -- separately selected (no tri-state).
    local doc = bucket({
        group(1, "g", { alert(2, "a"), alert(3, "b") }),
        alert(4, "tail"),
    })
    local mgr = self:makeManager({ { key = "global", label = "Global", doc = doc } })
    mgr:ToggleSelection(2, false)
    mgr:ToggleSelection(3, false)
    mgr:ToggleSelection(1, false)
    luaunit.assertEquals(selectedSet(mgr), { [1] = true })
end

function TestManager:testNormalizeSelectionDropsChildWhenAncestorAlreadySelected()
    local doc = bucket({
        group(1, "g", { alert(2, "a") }),
    })
    local mgr = self:makeManager({ { key = "global", label = "Global", doc = doc } })
    mgr:ToggleSelection(1, false)
    mgr:ToggleSelection(2, false) -- child under selected group is dropped by antichain
    luaunit.assertEquals(selectedSet(mgr), { [1] = true })
end

function TestManager:testShiftClickSelectsVisibleRange()
    local doc = bucket({
        alert(1, "a"),
        alert(2, "b"),
        alert(3, "c"),
        alert(4, "d"),
    })
    local mgr = self:makeManager({ { key = "global", label = "Global", doc = doc } })
    mgr:ToggleSelection(1, false)
    mgr:ToggleSelection(3, true) -- Shift from last (1) → 3
    luaunit.assertEquals(selectedSet(mgr), { [1] = true, [2] = true, [3] = true })
end

function TestManager:testShiftClickRangeUsesVisibleOrderNotCollapsedSubtree()
    local doc = bucket({
        alert(1, "a"),
        group(2, "g", { alert(3, "hidden"), alert(4, "also") }),
        alert(5, "e"),
    })
    local mgr = self:makeManager({ { key = "global", label = "Global", doc = doc } })
    -- Loaded groups start collapsed, so the hidden children are outside the visible range.
    mgr:ToggleSelection(1, false)
    mgr:ToggleSelection(5, true)
    luaunit.assertEquals(selectedSet(mgr), { [1] = true, [2] = true, [5] = true })
    luaunit.assertNil(selectedSet(mgr)[3])
    luaunit.assertNil(selectedSet(mgr)[4])
end

function TestManager:testSetActiveScopeClearsSelection()
    local mgr = self:makeManager({
        { key = "global", label = "Global", doc = bucket({ alert(1, "a") }) },
        { key = "player_alice", label = "Alice", doc = bucket({ alert(9, "b") }) },
    })
    mgr:ToggleSelection(1, false)
    luaunit.assertTrue(mgr:HasSelection())
    mgr:SetActiveScope("player_alice")
    luaunit.assertFalse(mgr:HasSelection())
    luaunit.assertEquals(mgr:SelectedIds(), {})
end

function TestManager:testCollapseOfGroupContainingSelectionDropsInside()
    local doc = bucket({
        group(1, "g", { alert(2, "a"), alert(3, "b") }),
        alert(4, "tail"),
    })
    local mgr = self:makeManager({ { key = "global", label = "Global", doc = doc } })
    mgr:ToggleExpand("global", 1)
    mgr:ToggleSelection(2, false)
    mgr:ToggleSelection(4, false)
    mgr:ToggleExpand("global", 1)
    luaunit.assertEquals(selectedSet(mgr), { [4] = true })
end

function TestManager:testCollapseOfUnrelatedGroupPreservesSelection()
    local doc = bucket({
        group(1, "g", { alert(2, "a") }),
        alert(3, "tail"),
    })
    local mgr = self:makeManager({ { key = "global", label = "Global", doc = doc } })
    mgr:ToggleExpand("global", 1)
    mgr:ToggleSelection(3, false)
    mgr:ToggleExpand("global", 1)
    luaunit.assertEquals(selectedSet(mgr), { [3] = true })
end

function TestManager:testClearSelectionIsIdempotent()
    local mgr = self:makeManager({
        { key = "global", label = "Global", doc = bucket({ alert(1, "a") }) },
    })
    mgr:ToggleSelection(1, false)
    mgr:ClearSelection()
    mgr:ClearSelection()
    luaunit.assertFalse(mgr:HasSelection())
end

function TestManager:testSelectedIdsFollowVisibleTreeOrder()
    local doc = bucket({
        alert(3, "c"),
        alert(1, "a"),
        alert(2, "b"),
    })
    local mgr = self:makeManager({ { key = "global", label = "Global", doc = doc } })
    mgr:ToggleSelection(2, false)
    mgr:ToggleSelection(3, false)
    mgr:ToggleSelection(1, false)
    luaunit.assertEquals(mgr:SelectedIds(), { 3, 1, 2 })
end

-- F8/Close notifies OnShellHide instead of SetVisible(false); overlay-parented
-- PrettyUI tips must Hide or they stick after the window tucks.
function TestManager:testOnShellHideHidesRowAndToolbarTooltips()
    local mgr = self:makeManager({})
    local hides = {}
    mgr.rowSpriteButtons = {
        {
            tooltip = { Hide = function() hides[#hides + 1] = "row" end },
            hovered = true,
            pressed = true,
            _UpdateState = function() end,
        },
    }
    mgr.toolbarButtons = {
        { tooltip = { Hide = function() hides[#hides + 1] = "toolbar" end } },
    }
    mgr:OnShellHide()
    luaunit.assertEquals(hides, { "row", "toolbar" })
    luaunit.assertFalse(mgr.rowSpriteButtons[1].hovered)
end
