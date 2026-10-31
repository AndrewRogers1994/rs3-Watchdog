-- The shell owns the window. These assertions used to run against the multiplexer.

local luaunit = require("luaunit")
local Shell = require("src/ui/shell")

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
---@return Watchdog.Shell, Watchdog.MuxWindow
local function newShell(onHide)
    local win = fakeWindow()
    local shell = Shell.new({
        window = win,
        overlay = { kind = "overlay" },
        onHide = onHide,
    })
    return shell, win
end

TestShellVisibility = {}

function TestShellVisibility:setUp()
    self.hideCount = 0
    self.shell, self.win = newShell(function()
        self.hideCount = self.hideCount + 1
    end)
end

function TestShellVisibility:testSetVisibleDoesNotClearStack()
    local a = fakeSurface("manager")
    local b = fakeSurface("editor")
    self.shell:Push(a)
    self.shell:Push(b)
    self.shell:SetVisible(true)
    luaunit.assertEquals(self.shell:Depth(), 2)

    self.shell:SetVisible(false)
    luaunit.assertEquals(self.shell:Depth(), 2)
    luaunit.assertTrue(self.shell:IsTop("editor"))
    luaunit.assertFalse(self.shell:IsVisible())
end

function TestShellVisibility:testShowRestoresOnlyCurrentTop()
    local a = fakeSurface("manager")
    local b = fakeSurface("editor")
    self.shell:Push(a)
    self.shell:Push(b)
    self.shell:SetVisible(true)
    luaunit.assertFalse(a.visible)
    luaunit.assertTrue(b.visible)

    self.shell:SetVisible(false)
    self.shell:SetVisible(true)
    luaunit.assertFalse(a.visible)
    luaunit.assertTrue(b.visible)
end

function TestShellVisibility:testToggleAndIsVisible()
    luaunit.assertFalse(self.shell:IsVisible())
    self.shell:Toggle()
    luaunit.assertTrue(self.shell:IsVisible())
    luaunit.assertTrue(self.win.shown)
    self.shell:Toggle()
    luaunit.assertFalse(self.shell:IsVisible())
    luaunit.assertFalse(self.win.shown)
end

function TestShellVisibility:testOnHideFiresOncePerHide()
    self.shell:SetVisible(true)
    self.shell:SetVisible(false)
    luaunit.assertEquals(self.hideCount, 1)
    self.shell:SetVisible(false)
    luaunit.assertEquals(self.hideCount, 1)
end

function TestShellVisibility:testCloseViaWindowDoesNotRecurse()
    self.shell:SetVisible(true)
    self.win:Close()
    luaunit.assertFalse(self.shell:IsVisible())
    luaunit.assertEquals(self.hideCount, 1)
    luaunit.assertEquals(self.win.closeCount, 1)
end

function TestShellVisibility:testSetVisibleFalseCallsCloseOnce()
    self.shell:SetVisible(true)
    self.shell:SetVisible(false)
    luaunit.assertEquals(self.win.closeCount, 1)
    luaunit.assertEquals(self.hideCount, 1)
end

function TestShellVisibility:testContentAndOverlayAccessors()
    luaunit.assertEquals(self.shell:Content().kind, "content")
    luaunit.assertEquals(self.shell:Overlay().kind, "overlay")
    luaunit.assertEquals(self.shell:Window(), self.win)
    luaunit.assertEquals(self.shell.mux:Window(), self.win)
end

function TestShellVisibility:testHideAlsoHidesOverlaySibling()
    local overlay = self.shell:Overlay()
    self.shell:SetVisible(true)
    luaunit.assertFalse(overlay.hidden == true)
    self.shell:SetVisible(false)
    luaunit.assertTrue(overlay.hidden == true)
    self.shell:SetVisible(true)
    luaunit.assertFalse(overlay.hidden == true)
end

function TestShellVisibility:testHideCallsTopOnShellHideWithoutSurfaceHide()
    local shellHides = 0
    local a = fakeSurface("manager")
    local b = fakeSurface("editor")
    b.OnShellHide = function()
        shellHides = shellHides + 1
    end
    self.shell:Push(a)
    self.shell:Push(b)
    self.shell:SetVisible(true)
    local hideCallsBefore = b.hideCalls
    self.shell:SetVisible(false)
    luaunit.assertEquals(shellHides, 1)
    luaunit.assertEquals(b.hideCalls, hideCallsBefore)
    luaunit.assertEquals(self.shell:Depth(), 2)
    luaunit.assertTrue(self.shell:IsTop("editor"))
end

function TestShellVisibility:testHideHidesWindowTooltipContext()
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
    self.shell:Push(fakeSurface("manager"))
    self.shell:SetVisible(true)
    self.shell:SetVisible(false)
    luaunit.assertEquals(hideCount, 2)
end

function TestShellVisibility:testRaiseToFront()
    self.shell:RaiseToFront()
    luaunit.assertEquals(self.win.raiseCount, 1)
end

function TestShellVisibility:testShowRaisesWindowToFront()
    self.shell:SetVisible(true)
    luaunit.assertEquals(self.win.raiseCount, 1)
end

function TestShellVisibility:testHideForCaptureTucksAVisibleShell()
    self.shell:SetVisible(true)
    self.shell:HideForCapture()
    luaunit.assertFalse(self.shell:IsVisible())
    luaunit.assertTrue(self.shell:IsHiddenForCapture())
end

function TestShellVisibility:testHideForCaptureIsNoopWhenAlreadyHidden()
    self.shell:HideForCapture()
    luaunit.assertFalse(self.shell:IsVisible())
    luaunit.assertFalse(self.shell:IsHiddenForCapture())
    self.shell:RestoreFromCapture()
    luaunit.assertFalse(self.shell:IsVisible())
end

function TestShellVisibility:testRestoreFromCaptureShowsOnlyIfWeHid()
    self.shell:SetVisible(true)
    self.shell:HideForCapture()
    self.shell:RestoreFromCapture()
    luaunit.assertTrue(self.shell:IsVisible())
    luaunit.assertFalse(self.shell:IsHiddenForCapture())
end

function TestShellVisibility:testRestoreFromCaptureIsIdempotent()
    self.shell:SetVisible(true)
    self.shell:HideForCapture()
    self.shell:RestoreFromCapture()
    self.shell:RestoreFromCapture()
    luaunit.assertTrue(self.shell:IsVisible())
end

function TestShellVisibility:testFunctionTitleReappliedOnShow()
    local n = 0
    self.shell:Push(fakeSurface("editor", function()
        n = n + 1
        return "t" .. n
    end))
    luaunit.assertEquals(self.win.title, "t1")
    self.shell:SetVisible(true)
    luaunit.assertEquals(self.win.title, "t2")
end

function TestShellVisibility:testInjectedWindowIsNotDestroyedWithTheShell()
    self.shell:Destroy()
    luaunit.assertEquals(self.win.destroyCount, 0)
end

TestShellPlacement = {}

function TestShellPlacement:testCenterAnchorsStoredOnNew()
    local shell = Shell.new({
        x = -450,
        y = -280,
        xAnchor = 0.5,
        yAnchor = 0.5,
        width = 900,
        height = 560,
        window = fakeWindow(),
        overlay = {},
    })
    luaunit.assertEquals(shell._winOpts.x, -450)
    luaunit.assertEquals(shell._winOpts.y, -280)
    luaunit.assertEquals(shell._winOpts.xAnchor, 0.5)
    luaunit.assertEquals(shell._winOpts.yAnchor, 0.5)
end
