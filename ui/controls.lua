-- controls.lua — the Type-Tag → Pin Control registry (ADR-0005). For an unconnected data-input
-- Pin whose Type Tag is registered here, this maps the tag to the Pin Control MODULE that owns how
-- that Control is laid out, displayed, clicked, and bound to the engine (ui/controls/*.lua). It is
-- purely the registry: LibNodeGraph stays tag-agnostic, so which Control a tag uses lives here,
-- parallel to Theme.TypeColor. A Pin whose tag has no Pin Control gets no Control (ADR-0004).
--
-- Two ways a tag is registered:
--   * Controls.Register(tag, descriptor) — the convenience path for the auto-wired Widget kinds
--     (number/text/enum/swatch/capture/mode). The descriptor names the widget kind and its per-tag
--     config (an enum's `choices`, a capture's `captureKind`/`placeholder`/`format`, a mode's
--     `modes`); Register builds the matching Pin Control from it. A new enum/color/capture/mode tag
--     is one Register call with no Pin Control code of its own.
--   * Controls.RegisterPinControl(tag, module) — the explicit path for the composite bands
--     (coordgrid, matcher) whose module can't be inferred from a widget kind alone.
--
-- This file used to also hold a parallel "Control Spec" table read at a distance by the Editor; the
-- ADR-0005 sweep migrated every Control onto a Pin Control and #61 deleted that passive path — the
-- Editor now delegates every data Control to its module through the host seam, with no kind switches.

local ScalarControl  = require("ui/controls/scalar")
local EnumControl    = require("ui/controls/enum")
local SwatchControl  = require("ui/controls/swatch")
local CaptureControl = require("ui/controls/capture")
local ModeControl    = require("ui/controls/mode")
local NumberField    = require("ui/widgets/number_field")
local TextField      = require("ui/widgets/text_field")

local Controls = {}

local pinControls = {}

-- Registers the Pin Control module for a Type Tag. The module supplies ReservedHeight/Layout
-- (geometry the Node delegates to), Display (value projection), and Press (click behavior, driven
-- through the passed host). Returns the module.
function Controls.RegisterPinControl(tag, module)
    assert(type(tag) == "string" and tag ~= "", "pin control tag must be a non-empty string")
    assert(type(module) == "table", "pin control must be a module table")
    pinControls[tag] = module
    return module
end

-- The Pin Control module for a Type Tag, or nil (an unregistered tag gets no Control).
function Controls.PinControlFor(tag)
    if tag == nil then return nil end
    return pinControls[tag]
end

-- Registers an auto-wired Pin Control for a Type Tag from a descriptor `{ widget = ..., ... }`.
-- The descriptor's widget kind selects the Pin Control and its per-tag config threads straight in
-- (an enum's choices, a capture's screen/object kind + placeholder + summary format, a mode's list).
-- Returns the descriptor. The composite bands (coordgrid/matcher) register their modules directly
-- with RegisterPinControl instead — "composite" alone doesn't say which module.
function Controls.Register(tag, descriptor)
    assert(type(tag) == "string" and tag ~= "", "control tag must be a non-empty string")
    assert(type(descriptor) == "table" and descriptor.widget ~= nil, "control descriptor needs a widget")
    if descriptor.widget == "number" then
        Controls.RegisterPinControl(tag, ScalarControl.new({ codec = NumberField, filter = "NUMERIC" }))
    elseif descriptor.widget == "text" then
        Controls.RegisterPinControl(tag, ScalarControl.new({ codec = TextField, filter = "NONE" }))
    elseif descriptor.widget == "enum" then
        Controls.RegisterPinControl(tag, EnumControl.new(descriptor.choices or {}))
    elseif descriptor.widget == "swatch" then
        -- Every color pin edits the same way (the Color Popup), so the swatch takes no per-tag
        -- config; capture and mode do (their kind/placeholder/format, their modes list), threaded
        -- straight from the descriptor that declared them.
        Controls.RegisterPinControl(tag, SwatchControl.new())
    elseif descriptor.widget == "capture" then
        Controls.RegisterPinControl(tag, CaptureControl.new({
            captureKind = descriptor.captureKind, placeholder = descriptor.placeholder,
            format = descriptor.format,
        }))
    elseif descriptor.widget == "mode" then
        Controls.RegisterPinControl(tag, ModeControl.new(descriptor.modes or {}))
    end
    return descriptor
end

-- Built-in registrations. number/string map to scalar fields; bool is the demonstrator enum
-- (true/false), so all three primitive Widget kinds exercise off existing pins with no node-
-- definition changes. coord/any are intentionally absent (composite/unknown), so their pins get
-- no Control. NOTE: ui.ComboField assigns each Add()'d entry an id by ALPHABETICAL rank of its
-- label, not by declaration order here (ADR-0004's ComboField caveat) — but the Editor matches
-- choices by label text, never id, so `choices` may be declared in whatever order reads best.
Controls.Register("number", { widget = "number" })
Controls.Register("string", { widget = "text" })
Controls.Register("bool", {
    widget = "enum",
    choices = {
        { value = true,  label = "true"  },
        { value = false, label = "false" },
    },
})

-- coordgrid (#25) and matcher (#56) are composite BANDS — their Pin Control modules own the band
-- layout, display, click, and per-axis/table binding. Registered explicitly (a "composite" widget
-- kind doesn't say which module) via RegisterPinControl.
Controls.RegisterPinControl("coordgrid", require("ui/controls/coordgrid"))
Controls.RegisterPinControl("matcher", require("ui/controls/matcher"))

-- color (#30): a {r, g, b, a} table Control edited via the Canvas-drawn Color Popup, opened from a
-- checker-backed swatch chip. The swatch Pin Control owns the chip and hands the popup its own hex
-- codec, so the tag needs no per-tag config.
Controls.Register("color", { widget = "swatch" })

-- toastIcon (#36): a curated sprite-id dropdown for the Toast action's `icon` config, plus a "None"
-- option (value = nil). Ids are the High-confidence entries from docs/research/popup-frame-
-- sprites.md's notification-icon set; `id.Sprite` is absent under the bare interpreter, so ids are
-- the literal numeric constants (recorded in that research doc), not `id.Sprite.*` lookups.
Controls.Register("toastIcon", {
    widget = "enum",
    choices = {
        { value = nil,   label = "None" },
        { value = 17127, label = "Tick / checkmark" },
        { value = 21747, label = "Green checkmark" },
        { value = 12764, label = "Star (filled)" },
        { value = 431,   label = "Coins" },
        { value = 937,   label = "Exclamation / alert" },
        { value = 6953,  label = "Quest (ribbon)" },
        { value = 15064, label = "Collection log" },
    },
})

return Controls
