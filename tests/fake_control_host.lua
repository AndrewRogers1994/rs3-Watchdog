-- Shared fake host for Pin Control tests (ADR-0005). A Pin Control reaches the Editor only through
-- the host SEAM — read/commit the Pin's stored Control value, mount a transient field or dropdown —
-- and this is the test-side adapter of that seam: the Editor-side analogue of driving a node
-- against a real Graph. It records every Commit and captures the mounted field/dropdown callback so
-- a test can "type" or "pick" and then assert the value COMMITTED, exercising a Pin Control through
-- its real interface without ever reaching past it into its Widgets. Commit mirrors the real host
-- (Graph:SetControl updates the store) so a subsequent read-modify-write reads back what it wrote.

local FakeHost = {}
FakeHost.__index = FakeHost

---@param stored any  -- the initial stored Control value (may be nil)
function FakeHost.new(stored)
    return setmetatable(
        { stored = stored, committed = nil, commits = {}, commitCount = 0, mounted = nil },
        FakeHost)
end

-- The raw stored Control value (no default fallback), as the real host's GetControl returns.
function FakeHost:GetControl()
    return self.stored
end

-- Records a commit. `commitCount` is tracked separately from the `commits` array because a
-- committed value may legitimately be nil (an enum's "None"), and nil can't be appended to a Lua
-- array — so a test asserting "a commit happened" checks commitCount, not #commits.
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

-- Drive a content change through the mounted field, as the real host does on ONCONTENTCHANGED:
-- hand the Pin Control the raw text and the field's parsed quantity.
function FakeHost:Type(raw, quantity)
    assert(self.mounted ~= nil and self.mounted.kind == "field", "no field mounted")
    self.mounted.onChange(raw, quantity)
end

-- Drive a selection through the mounted dropdown, as the real host does on ONSELECTIONCHANGED:
-- hand the Pin Control the picked label (the one field ComboField reports reliably — ADR-0004).
function FakeHost:Pick(label)
    assert(self.mounted ~= nil and self.mounted.kind == "dropdown", "no dropdown mounted")
    self.mounted.onSelect(label)
end

return FakeHost
