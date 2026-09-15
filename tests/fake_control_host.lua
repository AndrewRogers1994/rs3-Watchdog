-- Shared fake host for Pin Control tests (ADR-0005). A Pin Control reaches the Editor only through
-- the host SEAM; tests drive that interface and assert the COMMITTED value, never Widgets.
-- Commit mirrors Graph:SetControl so a later read-modify-write sees what it wrote.
--
-- Host-routed controls (#60) don't commit: the swatch opens the Color Popup, capture arms an overlay.
-- The fake records `openedPopup` / `armed` so a press through the seam is assertable without a live Editor.

local FakeHost = {}
FakeHost.__index = FakeHost

---@param stored any  -- the initial stored Control value (may be nil)
function FakeHost.new(stored)
    return setmetatable(
        { stored = stored, committed = nil, commits = {}, commitCount = 0, mounted = nil,
          openedPopup = nil, armed = nil },
        FakeHost)
end

function FakeHost:GetControl()
    return self.stored
end

-- `commitCount` is tracked separately from `commits` because a committed value may be nil
-- (an enum's "None"), and nil can't be appended to a Lua array - tests check commitCount, not #commits.
function FakeHost:Commit(value)
    self.committed = value
    self.commitCount = self.commitCount + 1
    self.commits[self.commitCount] = value
    self.stored = value
end

function FakeHost:MountField(ctrl, opts, onChange)
    self.mounted = { ctrl = ctrl, opts = opts, onChange = onChange, kind = "field" }
end

function FakeHost:MountDropdown(ctrl, opts, onSelect)
    self.mounted = { ctrl = ctrl, opts = opts, onSelect = onSelect, kind = "dropdown" }
end

function FakeHost:OpenColorPopup(codec)
    self.openedPopup = { codec = codec }
end

function FakeHost:ArmCapture(kind)
    self.armed = { kind = kind }
end

function FakeHost:Type(raw, quantity)
    assert(self.mounted ~= nil and self.mounted.kind == "field", "no field mounted")
    self.mounted.onChange(raw, quantity)
end

-- ComboField's id is unreliable; the host hands the Pin Control the picked label (ADR-0004).
function FakeHost:Pick(label)
    assert(self.mounted ~= nil and self.mounted.kind == "dropdown", "no dropdown mounted")
    self.mounted.onSelect(label)
end

return FakeHost
