-- ui/multiplexer.lua stack + titles via a fake window (no prettyui / ui.*).

local luaunit = require("luaunit")
local Multiplexer = require("src/ui/multiplexer")

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
---@return Watchdog.MuxSurface|{ visible: boolean, showCalls: integer, hideCalls: integer, popped: integer }
local function fakeSurface(id, title)
    return {
        id = id,
        title = title or id,
        visible = false,
        showCalls = 0,
        hideCalls = 0,
        popped = 0,
        SetVisible = function(self, v)
            self.visible = not not v
            if v then
                self.showCalls = self.showCalls + 1
            else
                self.hideCalls = self.hideCalls + 1
            end
        end,
        OnPop = function(self)
            self.popped = self.popped + 1
        end,
    }
end

---@return Watchdog.Multiplexer, Watchdog.MuxWindow
local function newMux()
    local win = fakeWindow()
    return Multiplexer.new(win), win
end

--- Stack Push / Pop -----------------------------------------------------------------------

TestMuxStack = {}

function TestMuxStack:setUp()
    self.mux, self.win = newMux()
end

function TestMuxStack:testPushIncreasesDepthAndSetsTop()
    local a = fakeSurface("manager", "Alerts")
    self.mux:Push(a)
    luaunit.assertEquals(self.mux:Depth(), 1)
    luaunit.assertEquals(self.mux:Top(), a)
    luaunit.assertTrue(self.mux:IsTop("manager"))
    luaunit.assertFalse(self.mux:IsTop("editor"))
end

function TestMuxStack:testPushHidesPreviousShowsNewWhenShown()
    local a = fakeSurface("manager")
    local b = fakeSurface("editor")
    self.mux:Push(a)
    self.mux:SetShown(true)
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

function TestMuxStack:testPopRestoresPreviousWhenShown()
    local a = fakeSurface("manager")
    local b = fakeSurface("editor")
    self.mux:Push(a)
    self.mux:SetShown(true)
    self.mux:Push(b)
    luaunit.assertTrue(self.mux:Pop())
    luaunit.assertEquals(self.mux:Depth(), 1)
    luaunit.assertTrue(a.visible)
    luaunit.assertFalse(b.visible)
    luaunit.assertTrue(self.mux:IsTop("manager"))
end

function TestMuxStack:testPopDropsOnlyTheRemovedSurface()
    local a = fakeSurface("root", "Save as preset")
    local b = fakeSurface("node", "Save as preset - Choose a node")
    self.mux:SetShown(true)
    self.mux:Push(a)
    self.mux:Push(b)
    luaunit.assertTrue(self.mux:Pop())
    luaunit.assertEquals(b.popped, 1)
    luaunit.assertEquals(a.popped, 0)
    luaunit.assertTrue(a.visible)
    luaunit.assertFalse(b.visible)
end

function TestMuxStack:testPopAtRootDoesNotDropIt()
    local a = fakeSurface("manager")
    self.mux:Push(a)
    self.mux:SetShown(true)
    luaunit.assertFalse(self.mux:Pop())
    luaunit.assertEquals(self.mux:Depth(), 1)
    luaunit.assertEquals(a.popped, 0)
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
    self.mux:SetShown(true)
    self.mux:Push(a)
    self.mux:Push(b)
    self.mux:Push(c)
    luaunit.assertFalse(a.visible)
    luaunit.assertFalse(b.visible)
    luaunit.assertTrue(c.visible)
end

function TestMuxStack:testPopToStopsAtIdAndDropsTheStepsAbove()
    local a = fakeSurface("manager")
    local b = fakeSurface("editor")
    local c = fakeSurface("dialog")
    self.mux:Push(a)
    self.mux:Push(b)
    self.mux:Push(c)
    luaunit.assertTrue(self.mux:PopTo("manager"))
    luaunit.assertEquals(self.mux:Depth(), 1)
    luaunit.assertTrue(self.mux:IsTop("manager"))
    luaunit.assertEquals(c.popped, 1)
    luaunit.assertEquals(b.popped, 1)
    luaunit.assertEquals(a.popped, 0)
end

function TestMuxStack:testPopToMissingLeavesRoot()
    local a = fakeSurface("manager")
    local b = fakeSurface("editor")
    self.mux:Push(a)
    self.mux:Push(b)
    luaunit.assertFalse(self.mux:PopTo("nope"))
    luaunit.assertEquals(self.mux:Depth(), 1)
    luaunit.assertTrue(self.mux:IsTop("manager"))
    luaunit.assertEquals(b.popped, 1)
    luaunit.assertEquals(a.popped, 0)
end

function TestMuxStack:testPushAndPopLeaveTheGivenWindowMounted()
    local a = fakeSurface("root", "Save as preset")
    local b = fakeSurface("node", "Save as preset - Choose a node")
    self.mux:SetShown(true)
    self.mux:Push(a)
    self.mux:Push(b)
    self.mux:Pop()
    luaunit.assertEquals(self.win.showCount, 0)
    luaunit.assertEquals(self.win.closeCount, 0)
    luaunit.assertEquals(self.win.destroyCount, 0)
    luaunit.assertEquals(self.win.title, "Save as preset")
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
