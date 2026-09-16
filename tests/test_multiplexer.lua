-- ui/multiplexer.lua stack + visibility via a fake window (no prettyui / ui.*).

local luaunit = require("luaunit")
local Multiplexer = require("ui/multiplexer")

--- Fakes ----------------------------------------------------------------------------------

---@return Watchdog.MuxWindow
local function fakeWindow()
    local w = {
        content = { kind = "content" },
        title = "",
        shown = false,
        closeCount = 0,
        showCount = 0,
        destroyCount = 0,
        raiseCount = 0,
        onClose = nil,
    }
    function w:Show()
        self.shown = true
        self.showCount = self.showCount + 1
    end
    function w:Close()
        self.closeCount = self.closeCount + 1
        if self.onClose then self.onClose(self) end
        self.shown = false
    end
    function w:SetTitle(title)
        self.title = title or ""
    end
    function w:Destroy()
        self.destroyCount = self.destroyCount + 1
    end
    function w:MoveToFront()
        self.raiseCount = self.raiseCount + 1
    end
    return w
end

---@param id string
---@param title? string|fun():string
---@return Watchdog.MuxSurface|{ visible: boolean, showCalls: integer, hideCalls: integer }
local function fakeSurface(id, title)
    return {
        id = id,
        title = title or id,
        visible = false,
        showCalls = 0,
        hideCalls = 0,
        SetVisible = function(self, v)
            self.visible = not not v
            if v then
                self.showCalls = self.showCalls + 1
            else
                self.hideCalls = self.hideCalls + 1
            end
        end,
    }
end

---@param onHide (fun())|nil
---@return Watchdog.Multiplexer, Watchdog.MuxWindow
local function newMux(onHide)
    local win = fakeWindow()
    local mux = Multiplexer.new({
        window = win,
        overlay = { kind = "overlay" },
        onHide = onHide,
    })
    return mux, win
end

--- Stack Push / Pop -----------------------------------------------------------------------

TestMuxStack = {}

function TestMuxStack:setUp()
    self.mux = newMux()
end

function TestMuxStack:testPushIncreasesDepthAndSetsTop()
    local a = fakeSurface("manager", "Alerts")
    self.mux:Push(a)
    luaunit.assertEquals(self.mux:Depth(), 1)
    luaunit.assertEquals(self.mux:Top(), a)
    luaunit.assertTrue(self.mux:IsTop("manager"))
    luaunit.assertFalse(self.mux:IsTop("editor"))
end

function TestMuxStack:testPushHidesPreviousShowsNewWhenVisible()
    local a = fakeSurface("manager")
    local b = fakeSurface("editor")
    self.mux:Push(a)
    self.mux:SetVisible(true)
    luaunit.assertTrue(a.visible)

    self.mux:Push(b)
    luaunit.assertEquals(self.mux:Depth(), 2)
    luaunit.assertFalse(a.visible)
    luaunit.assertTrue(b.visible)
    luaunit.assertTrue(self.mux:IsTop("editor"))
end

function TestMuxStack:testPushWhileHiddenLeavesSurfacesHidden()
    local a = fakeSurface("manager")
    local b = fakeSurface("editor")
    self.mux:Push(a)
    self.mux:Push(b)
    luaunit.assertFalse(a.visible)
    luaunit.assertFalse(b.visible)
    luaunit.assertEquals(self.mux:Depth(), 2)
end

function TestMuxStack:testPopRestoresPreviousWhenVisible()
    local a = fakeSurface("manager")
    local b = fakeSurface("editor")
    self.mux:Push(a)
    self.mux:SetVisible(true)
    self.mux:Push(b)
    luaunit.assertTrue(self.mux:Pop())
    luaunit.assertEquals(self.mux:Depth(), 1)
    luaunit.assertTrue(a.visible)
    luaunit.assertFalse(b.visible)
    luaunit.assertTrue(self.mux:IsTop("manager"))
end

function TestMuxStack:testPopAtRootIsNoop()
    local a = fakeSurface("manager")
    self.mux:Push(a)
    self.mux:SetVisible(true)
    luaunit.assertFalse(self.mux:Pop())
    luaunit.assertEquals(self.mux:Depth(), 1)
    luaunit.assertTrue(a.visible)
    luaunit.assertTrue(self.mux:IsTop("manager"))
end

function TestMuxStack:testPopOnEmptyIsNoop()
    luaunit.assertFalse(self.mux:Pop())
    luaunit.assertEquals(self.mux:Depth(), 0)
end

function TestMuxStack:testOnlyTopVisibleAfterSeveralPushes()
    local a = fakeSurface("a")
    local b = fakeSurface("b")
    local c = fakeSurface("c")
    self.mux:SetVisible(true)
    self.mux:Push(a)
    self.mux:Push(b)
    self.mux:Push(c)
    luaunit.assertFalse(a.visible)
    luaunit.assertFalse(b.visible)
    luaunit.assertTrue(c.visible)
end

function TestMuxStack:testPopToStopsAtId()
    local a = fakeSurface("manager")
    local b = fakeSurface("editor")
    local c = fakeSurface("dialog")
    self.mux:Push(a)
    self.mux:Push(b)
    self.mux:Push(c)
    luaunit.assertTrue(self.mux:PopTo("manager"))
    luaunit.assertEquals(self.mux:Depth(), 1)
    luaunit.assertTrue(self.mux:IsTop("manager"))
end

function TestMuxStack:testPopToMissingLeavesRoot()
    local a = fakeSurface("manager")
    local b = fakeSurface("editor")
    self.mux:Push(a)
    self.mux:Push(b)
    luaunit.assertFalse(self.mux:PopTo("nope"))
    luaunit.assertEquals(self.mux:Depth(), 1)
    luaunit.assertTrue(self.mux:IsTop("manager"))
end

--- SetVisible / stack preservation --------------------------------------------------------

TestMuxVisibility = {}

function TestMuxVisibility:setUp()
    self.hideCount = 0
    self.mux, self.win = newMux(function()
        self.hideCount = self.hideCount + 1
    end)
end

function TestMuxVisibility:testSetVisibleDoesNotClearStack()
    local a = fakeSurface("manager")
    local b = fakeSurface("editor")
    self.mux:Push(a)
    self.mux:Push(b)
    self.mux:SetVisible(true)
    luaunit.assertEquals(self.mux:Depth(), 2)

    self.mux:SetVisible(false)
    luaunit.assertEquals(self.mux:Depth(), 2)
    luaunit.assertTrue(self.mux:IsTop("editor"))
    luaunit.assertFalse(self.mux:IsVisible())
end

function TestMuxVisibility:testShowRestoresOnlyCurrentTop()
    local a = fakeSurface("manager")
    local b = fakeSurface("editor")
    self.mux:Push(a)
    self.mux:Push(b)
    self.mux:SetVisible(true)
    luaunit.assertFalse(a.visible)
    luaunit.assertTrue(b.visible)

    self.mux:SetVisible(false)
    self.mux:SetVisible(true)
    luaunit.assertFalse(a.visible)
    luaunit.assertTrue(b.visible)
end

function TestMuxVisibility:testToggleAndIsVisible()
    luaunit.assertFalse(self.mux:IsVisible())
    self.mux:Toggle()
    luaunit.assertTrue(self.mux:IsVisible())
    luaunit.assertTrue(self.win.shown)
    self.mux:Toggle()
    luaunit.assertFalse(self.mux:IsVisible())
    luaunit.assertFalse(self.win.shown)
end

function TestMuxVisibility:testOnHideFiresOncePerHide()
    self.mux:SetVisible(true)
    self.mux:SetVisible(false)
    luaunit.assertEquals(self.hideCount, 1)
    self.mux:SetVisible(false) -- already hidden
    luaunit.assertEquals(self.hideCount, 1)
end

function TestMuxVisibility:testCloseViaWindowDoesNotRecurse()
    self.mux:SetVisible(true)
    -- Simulate the close button: Window:Close → onClose → SetVisible(false).
    self.win:Close()
    luaunit.assertFalse(self.mux:IsVisible())
    luaunit.assertEquals(self.hideCount, 1)
    -- Close ran once from the button; SetVisible must not have called Close again.
    luaunit.assertEquals(self.win.closeCount, 1)
end

function TestMuxVisibility:testSetVisibleFalseCallsCloseOnce()
    self.mux:SetVisible(true)
    self.mux:SetVisible(false)
    -- One Close from SetVisible; onClose early-outs because already hidden.
    luaunit.assertEquals(self.win.closeCount, 1)
    luaunit.assertEquals(self.hideCount, 1)
end

function TestMuxVisibility:testContentAndOverlayAccessors()
    luaunit.assertEquals(self.mux:Content().kind, "content")
    luaunit.assertEquals(self.mux:Overlay().kind, "overlay")
    luaunit.assertEquals(self.mux:Window(), self.win)
end

function TestMuxVisibility:testHideAlsoHidesOverlaySibling()
    -- Overlay is a sibling of the window root; shell hide must tuck it away so Editor
    -- capture mounted there cannot intercept game input while F8/close has the UI down.
    local overlay = self.mux:Overlay()
    self.mux:SetVisible(true)
    luaunit.assertFalse(overlay.hidden == true)
    self.mux:SetVisible(false)
    luaunit.assertTrue(overlay.hidden == true)
    self.mux:SetVisible(true)
    luaunit.assertFalse(overlay.hidden == true)
end

function TestMuxVisibility:testHideCallsTopOnShellHideWithoutSurfaceHide()
    -- Shell hide must notify the top surface (palette/gesture cleanup) without flipping
    -- surface SetVisible - pan/zoom and bound editor state survive F8.
    local shellHides = 0
    local a = fakeSurface("manager")
    local b = fakeSurface("editor")
    b.OnShellHide = function()
        shellHides = shellHides + 1
    end
    self.mux:Push(a)
    self.mux:Push(b)
    self.mux:SetVisible(true)
    local hideCallsBefore = b.hideCalls
    self.mux:SetVisible(false)
    luaunit.assertEquals(shellHides, 1)
    luaunit.assertEquals(b.hideCalls, hideCallsBefore)
    luaunit.assertEquals(self.mux:Depth(), 2)
    luaunit.assertTrue(self.mux:IsTop("editor"))
end

function TestMuxVisibility:testHideHidesWindowTooltipContext()
    local hideCount = 0
    self.win.tooltipContext = {
        tooltips = {
            { Hide = function() hideCount = hideCount + 1 end },
        },
        children = {
            {
                tooltips = {
                    { Hide = function() hideCount = hideCount + 1 end },
                },
                children = {},
            },
        },
    }
    self.mux:Push(fakeSurface("manager"))
    self.mux:SetVisible(true)
    self.mux:SetVisible(false)
    luaunit.assertEquals(hideCount, 2)
end

function TestMuxVisibility:testRaiseToFront()
    self.mux:RaiseToFront()
    luaunit.assertEquals(self.win.raiseCount, 1)
end

function TestMuxVisibility:testShowRaisesWindowToFront()
    -- SetVisible(true) must RaiseToFront after Show so the overlay sibling ends above the
    -- PrettyUI window (capture/palette); without it, Window:Show leaves chrome on top.
    self.mux:SetVisible(true)
    luaunit.assertEquals(self.win.raiseCount, 1)
end

--- Titles ---------------------------------------------------------------------------------

TestMuxTitle = {}

function TestMuxTitle:setUp()
    self.mux, self.win = newMux()
end

function TestMuxTitle:testStringTitleAppliedOnPush()
    self.mux:Push(fakeSurface("manager", "Watchdog - Alerts"))
    luaunit.assertEquals(self.win.title, "Watchdog - Alerts")
end

function TestMuxTitle:testFunctionTitleResolvedOnPush()
    local name = "Boss"
    self.mux:Push(fakeSurface("editor", function()
        return "Editing: " .. name
    end))
    luaunit.assertEquals(self.win.title, "Editing: Boss")
end

function TestMuxTitle:testTitleUpdatesOnPop()
    self.mux:Push(fakeSurface("manager", "Alerts"))
    self.mux:Push(fakeSurface("editor", "Editor"))
    luaunit.assertEquals(self.win.title, "Editor")
    self.mux:Pop()
    luaunit.assertEquals(self.win.title, "Alerts")
end

function TestMuxTitle:testFunctionTitleReappliedOnShow()
    local n = 0
    self.mux:Push(fakeSurface("editor", function()
        n = n + 1
        return "t" .. n
    end))
    luaunit.assertEquals(self.win.title, "t1")
    self.mux:SetVisible(true)
    luaunit.assertEquals(self.win.title, "t2")
end

--- Placement ------------------------------------------------------------------------------

TestMuxPlacement = {}

function TestMuxPlacement:testCenterAnchorsStoredOnNew()
    local mux = Multiplexer.new({
        x = -450,
        y = -280,
        xAnchor = 0.5,
        yAnchor = 0.5,
        width = 900,
        height = 560,
        window = fakeWindow(),
        overlay = {},
    })
    luaunit.assertEquals(mux._winOpts.x, -450)
    luaunit.assertEquals(mux._winOpts.y, -280)
    luaunit.assertEquals(mux._winOpts.xAnchor, 0.5)
    luaunit.assertEquals(mux._winOpts.yAnchor, 0.5)
end
