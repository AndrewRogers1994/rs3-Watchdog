-- controls.lua — the Control Spec map: Type Tag -> how the Editor renders and edits an
-- unconnected data-input Pin's Control value (ADR-0004). Presentation only: LibNodeGraph
-- stays tag-agnostic, so which widget a tag uses and what an enum's members are live here,
-- parallel to Theme.TypeColor. A domain enum is one Controls.Register(tag, spec) call.
--
-- A spec is:
--   { widget = "number" | "text" | "enum",
--     choices = { { value = <control value>, label = <string> }, ... },  -- enum only
--     format  = function(value) -> string,   -- optional display override
--     parse   = function(raw, current) -> value }  -- optional text->value override

local Controls = {}

local specs = {}

-- Registers/overrides the Control Spec for a Type Tag. Returns the spec.
function Controls.Register(tag, spec)
    assert(type(tag) == "string" and tag ~= "", "control spec tag must be a non-empty string")
    assert(type(spec) == "table" and spec.widget ~= nil, "control spec needs a widget")
    specs[tag] = spec
    return spec
end

-- The spec for a Type Tag, or nil (tags with no spec — coord, any — get no Control editor).
function Controls.For(tag)
    if tag == nil then return nil end
    return specs[tag]
end

-- The display string for a control value under a spec (nil-safe). Enums show their label.
function Controls.Format(spec, value)
    if spec == nil then return "" end
    if spec.format then
        local ok, s = pcall(spec.format, value)
        if ok and s ~= nil then return tostring(s) end
    end
    if spec.widget == "enum" then
        for _, c in ipairs(spec.choices or {}) do
            if c.value == value then return c.label end
        end
    end
    if value == nil then return "" end
    return tostring(value)
end

-- 1-based index of the choice whose value equals `value`, or nil. Used to pre-select the
-- ComboField entry that matches the current control value.
function Controls.ChoiceIndex(spec, value)
    if spec == nil or spec.choices == nil then return nil end
    for i, c in ipairs(spec.choices) do
        if c.value == value then return i end
    end
    return nil
end

-- Parses a raw InputField string into the stored control value. On an unparsable number the
-- current value is kept rather than nuked to nil/0, so a mid-edit empty box doesn't clobber.
function Controls.Parse(spec, raw, current)
    if spec == nil then return raw end
    if spec.parse then
        local ok, v = pcall(spec.parse, raw, current)
        if ok then return v end
    end
    if spec.widget == "number" then
        local n = tonumber(raw)
        if n ~= nil then return n end
        return current
    end
    return raw
end

-- Built-in specs (ADR-0004 decision 3). number/string map to fields; bool is the
-- demonstrator enum (true/false), so all three widget kinds exercise off existing pins with
-- no node-definition changes. coord/any are intentionally absent (composite/unknown).
Controls.Register("number", { widget = "number" })
Controls.Register("string", { widget = "text" })
-- NOTE: ui.ComboField assigns each Add()'d entry an id by ALPHABETICAL rank of its label, not
-- by declaration order here or the id passed to Add (see ADR-0004's ComboField caveat). The
-- Editor never relies on that id — it matches choices by label text instead — so `choices`
-- below can be declared in whatever order reads best; it need not be alphabetical.
Controls.Register("bool", {
    widget = "enum",
    choices = {
        { value = true,  label = "true"  },
        { value = false, label = "false" },
    },
})

return Controls
