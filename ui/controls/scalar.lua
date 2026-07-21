-- scalar.lua — the scalar Pin Control factory (ADR-0005): the per-Type-Tag module for a Control
-- that edits a single, whole value through one field Widget — the `number` and `string` Type Tags.
-- Unlike coordgrid's composite band, a scalar renders INLINE in the value column to the right of
-- the pin label (Inline = true, so the Node lays it out as a single value-column box rather than a
-- reserved band), and its binding is a straight pass-through: the whole Control value IS the field
-- value, no read-modify-write. The only thing that varies between `number` and `string` is the
-- value CODEC and the field filter, so one factory builds both:
--   number -> the numeric codec (NumberField) + a NUMERIC filter; an empty box is guarded
--             (Parse returns nil), so opening then clearing a field leaves the stored value alone.
--   string -> the text codec (TextField) + a NONE filter; an empty box is a real value (clearing
--             the field), committed verbatim (TextField.Parse never returns nil).
-- The guard difference lives entirely in the codec — this module just commits whatever non-nil
-- value the codec yields, so the two tags share one press/commit path.
--
-- A Pin Control reaches the Editor only through the passed `host` (mount a field, commit); its
-- test adapter is the fake host in tests/test_scalar_control.lua, driving press->commit headless.

---@class ScalarPinControl
local Scalar = {}

-- Builds a scalar Pin Control module bound to a codec + filter. Returns a plain module table
-- (dot-functions, like coordgrid) so the Node/Editor call it the same way every Pin Control is
-- called — the codec/filter are captured in the closures, not stored on an instance.
---@param opts { codec: table, filter: string }
---@return table
function Scalar.new(opts)
    local codec = opts.codec
    local filter = opts.filter or "NONE"

    local M = {}
    -- Inline: the Node reserves no band, laying this out as one value-column box (see node.lua's
    -- Inline branch). ReservedHeight is still answered (0) so the shared row-height math is uniform.
    M.Inline = true

    ---@return number
    function M.ReservedHeight(_pin) return 0 end

    -- One sub-rect: the value-column box the Node computed, tagged "field". A scalar has exactly
    -- one Widget, so there is no internal layout to do — it fills the box it was handed.
    ---@param box { x: number, y: number, w: number, h: number }
    ---@return table[]
    function M.Layout(box)
        return { { kind = "field", x = box.x, y = box.y, w = box.w, h = box.h } }
    end

    -- The text the box shows: the codec's rendering of the whole stored value (default-resolved
    -- in ctrl.value). Empty when unset (both codecs Format nil to "").
    ---@param ctrl table
    ---@return string
    function M.Display(ctrl)
        return codec.Format(ctrl.value)
    end

    -- Click: mount a transient field seeded from the current value, committing on every content
    -- change. The codec decides whether a given edit commits at all — a nil result (number's
    -- empty-box guard) is not committed, a non-nil result (any text, any parsed number) is.
    ---@param host ControlHost
    ---@param ctrl table
    function M.Press(host, ctrl)
        host:MountField(ctrl, {
            filter = filter, maxLen = 128, initial = codec.Format(ctrl.value),
        }, function(raw, quantity)
            local value = codec.Parse(raw, quantity)
            if value ~= nil then host:Commit(value) end
        end)
    end

    return M
end

return Scalar
