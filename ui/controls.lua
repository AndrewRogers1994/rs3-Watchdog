-- controls.lua — the Control Spec map: Type Tag -> how the Editor renders and edits an
-- unconnected data-input Pin's Control value (ADR-0004). Presentation only: LibNodeGraph
-- stays tag-agnostic, so which widget a tag uses and what an enum's members are live here,
-- parallel to Theme.TypeColor. A domain enum is one Controls.Register(tag, spec) call.
--
-- A spec is:
--   { widget = "number" | "text" | "enum" | "composite",
--     choices = { { value = <control value>, label = <string> }, ... },  -- enum only
--     format  = function(value) -> string,   -- optional display override
--     parse   = function(raw, current) -> value,  -- optional text->value override
--     extraH  = function(pin) -> number,   -- composite only: extra row height it reserves
--     Layout  = function(band) -> { { kind, axis?, x, y, w, h }, ... } }  -- composite only
--
-- A "composite" widget (e.g. coordgrid) renders as a full-width band below the pin's own row
-- instead of the single value-column box scalars get (see Node.BuildGeometry's extraH-driven
-- cumulative row layout). Its Layout function receives the reserved band rect (graph-space,
-- relative to the node origin: {x, y, w, h}) and returns however many sub-rects it needs, each
-- tagged with a `kind` the Editor's click dispatcher branches on.

local Theme = require("ui/theme")
local Color = require("ui/color")

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

-- Read-modify-write for one axis of a composite table Control (e.g. coordgrid's {x,z,level}).
-- Same empty-box guard as Parse: an empty/unparsable raw string leaves the WHOLE table
-- untouched (returns `current` unchanged, `changed = false`) so a mid-edit empty field can't
-- clobber sibling axes. `quantity` is the widget's own pre-parsed number (e.g. InputField's
-- contentQuantity, which honors suffixes like 1K/1M) and is preferred over re-parsing `raw`.
function Controls.CommitAxis(current, axis, raw, quantity)
    if type(raw) == "string" and raw:match("^%s*$") then return current, false end
    local value = quantity
    if value == nil then value = tonumber(raw) end
    if value == nil then return current, false end
    local t = {}
    if type(current) == "table" then
        for k, v in pairs(current) do t[k] = v end
    end
    t[axis] = value
    return t, true
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

-- coordgrid (#25): a {x, z, level} table Control, edited as 3 inline int fields + a
-- "Set to current position" button, all sharing the pin's Control value. The band always
-- reserves COORDGRID_BAND_H (Node.BuildGeometry's extraH); it's drawn/hit-tested only above
-- CONTROL_MIN_ZOOM, same gate as every other Control box.
Controls.Register("coordgrid", {
    widget = "composite",
    extraH = function(_pin) return Theme.COORDGRID_BAND_H end,
    -- `band` is the reserved rect (graph-space, relative to the node origin): {x, y, w, h}.
    Layout = function(band)
        local fieldY = band.y + Theme.COORDGRID_TOP_GAP
        local buttonY = fieldY + Theme.COORDGRID_FIELD_H + Theme.COORDGRID_MID_GAP
        local gap = Theme.COORDGRID_FIELD_GAP
        local fieldW = (band.w - gap * 2) / 3
        local rects = {}
        for i, axis in ipairs({ "x", "z", "level" }) do
            rects[#rects + 1] = {
                kind = "field", axis = axis,
                x = band.x + (i - 1) * (fieldW + gap), y = fieldY,
                w = fieldW, h = Theme.COORDGRID_FIELD_H,
            }
        end
        rects[#rects + 1] = {
            kind = "action",
            x = band.x, y = buttonY, w = band.w, h = Theme.COORDGRID_BUTTON_H,
        }
        return rects
    end,
})

-- color (#30): a {r, g, b, a} table Control (0..255 each), edited via a Canvas-drawn popup
-- (ui/color_popup.lua) opened from a checker-backed swatch chip, not the composite band --
-- kind == "swatch" is a single value-column box like a scalar Control, just drawn as a color
-- fill instead of text (see Node.BuildGeometry/Draw's swatch branch). format/parse round-trip
-- the popup's one textual field, its hex8 box, to/from the stored table; the popup's own
-- sliders read/write the table directly and never go through these.
Controls.Register("color", {
    widget = "swatch",
    format = function(value) return Color.FormatHex8(value) end,
    parse  = function(raw, current) return Color.ParseHex8(raw, current) end,
})

return Controls
