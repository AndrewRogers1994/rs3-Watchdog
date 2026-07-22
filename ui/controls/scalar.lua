-- scalar.lua — the scalar Pin Control factory (ADR-0005): the inline `number`/`string` Control that
-- edits one whole value through a single field Widget. The Control value IS the field value (no
-- read-modify-write); the only difference between number and string is the codec + filter, so one
-- factory builds both. The number codec's empty-box guard (Parse -> nil) is what lets a cleared
-- number field leave the stored value alone, while an empty text field commits verbatim.

local Inline = require("ui/controls/inline")

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

    local M = Inline.apply({})

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

    -- Draw: the codec IS the field Widget, so drawing delegates to it (number/text draw the same
    -- plain box). The Node hands an already-projected screen rect + draw context, never `view`.
    ---@param canvas any
    ---@param rect { x: number, y: number, w: number, h: number }
    ---@param ctrl table
    ---@param dctx DrawContext
    function M.Draw(canvas, rect, ctrl, dctx)
        codec.Draw(canvas, rect, ctrl, dctx)
    end

    return M
end

return Scalar
