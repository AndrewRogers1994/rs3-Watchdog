-- node.lua — Node Body geometry, drawing, and pin/body hit-testing.
--
-- Geometry is computed once per frame (BuildGeometry, pure Graph-space) and shared by
-- Draw and the hit helpers, so what you see and what you click can never disagree.
-- All stored geometry is Graph-space; the View converts to Screen-space at draw/hit time.

local Theme    = require("ui/theme")
local Controls = require("ui/controls")
local Box      = require("ui/widgets/box")
local Dropdown = require("ui/widgets/dropdown")

local Node = {}

-- Splits a node's pins into left (inputs) / right (outputs) columns and assigns each a
-- Graph-space center relative to the node origin. Returns a geometry table consumed by
-- Draw, PinAt and HitBody. `pins` is the list from graph:GetPins(nodeId). `opts.connected`
-- is a set { [pinName] = true } of input pins that already have an incoming Connection —
-- those get a wire, not a Control box (ADR-0004). `opts.modeLabel` (when set) reserves a Mode
-- strip under the header — instance metadata, not a Pin.

-- The Pin Control module for a data-input pin eligible for a Control box: unconnected, kind
-- "data", and its Type Tag is registered (ADR-0005). Returns nil for anything else (exec pins,
-- connected inputs, tags with no Pin Control — which then get no Control, ADR-0004).
---@param pin table
---@param connected table<string, boolean>
---@return table|nil
local function pinControlFor(pin, connected)
    if pin.kind ~= "data" or connected[pin.name] then return nil end
    return Controls.PinControlFor(pin.dataType)
end

-- Stable ComboField / filter order for a type's modes (engine `modes` is a keyed table).
---@param nodeType table|nil
---@return { key: string, label: string }[]
function Node.SortedModes(nodeType)
    if nodeType == nil or nodeType.modes == nil then return {} end
    local list = {}
    for key, def in pairs(nodeType.modes) do
        list[#list + 1] = { key = key, label = def.label or key }
    end
    table.sort(list, function(a, b)
        if a.label == b.label then return a.key < b.key end
        return a.label < b.label
    end)
    return list
end

function Node.BuildGeometry(pins, x, y, width, opts)
    width = width or Theme.NODE_WIDTH
    local connected = (opts and opts.connected) or {}
    -- A placeholder node (#53) renders its reconstructed stubs as pins, but offers none of the
    -- interactive geometry: no Control boxes (raw controls are opaque without their codecs) and
    -- no per-exec-in test buttons (FireInput would assert on a pin the engine can't resolve).
    local placeholder = (opts and opts.placeholder) or false

    local inputs, outputs = {}, {}
    for _, pin in ipairs(pins) do
        if pin.direction == "in" then
            inputs[#inputs + 1] = pin
        else
            outputs[#outputs + 1] = pin
        end
    end

    local rows = math.max(#inputs, #outputs)

    -- Mode strip (ADR-0011) sits under the header when this instance's type has modes.
    -- Not a pin: `opts.modeLabel` is the current mode's display label, or nil.
    local modeLabel = (not placeholder) and opts and opts.modeLabel or nil
    local modeStripH = (modeLabel ~= nil) and Theme.MODE_STRIP_H or 0

    -- Row tops, cumulative (#25): row i normally advances by a fixed PIN_ROW_HEIGHT, but a
    -- composite Control on that row's input pin (e.g. coordgrid) reserves extra band height
    -- below it via spec.extraH(pin), pushing every later row down. Scalar/no-control rows
    -- have extraH 0, so this collapses to the old fixed-stride math. Both pin columns (inputs
    -- AND outputs) share this same rowTop table so a row's input and output glyph stay
    -- vertically aligned even when only the input side grew.
    local rowTop = {}
    do
        local cy = Theme.HEADER_HEIGHT + modeStripH + Theme.BODY_PAD_TOP
        for i = 1, rows do
            rowTop[i] = cy
            local extraH = 0
            local pin = inputs[i]
            if pin ~= nil and not placeholder then
                -- A Pin Control (ADR-0005) reports the extra band height its Control reserves below
                -- the pin row (0 for an inline scalar/enum). Same cumulative row push either way.
                local pc = pinControlFor(pin, connected)
                if pc ~= nil then
                    extraH = pc.ReservedHeight(pin) or 0
                end
            end
            cy = cy + Theme.PIN_ROW_HEIGHT + extraH
        end
        rowTop[rows + 1] = cy
    end
    local height = rowTop[rows + 1] + Theme.BODY_PAD_BOTTOM

    local geom = { x = x, y = y, w = width, h = height,
        pins = {}, byName = {}, controls = {}, testButtons = {}, placeholder = placeholder }

    -- Delete button center, in the header, Graph-space relative to the node origin. Shared
    -- by Draw and HitClose so the glyph and its hit-target can't disagree.
    geom.close = { cx = width - Theme.CLOSE_MARGIN, cy = Theme.HEADER_HEIGHT * 0.5 }
    if modeLabel ~= nil then
        geom.modeStrip = {
            x = Theme.PIN_MARGIN_X,
            y = Theme.HEADER_HEIGHT + Theme.MODE_STRIP_PAD,
            w = width - Theme.PIN_MARGIN_X * 2,
            h = Theme.CONTROL_H,
            label = modeLabel,
        }
    end

    local function place(list, cx)
        for i, pin in ipairs(list) do
            local cy = rowTop[i] + Theme.PIN_ROW_HEIGHT * 0.5
            local entry = {
                name = pin.name,
                kind = pin.kind,
                direction = pin.direction,
                dataType = pin.dataType,
                label = pin.label or pin.name,
                cx = cx,   -- glyph center, Graph-space, relative to node origin
                cy = cy,
            }
            geom.pins[#geom.pins + 1] = entry
            geom.byName[pin.name] = entry
        end
    end

    place(inputs, Theme.PIN_MARGIN_X)
    place(outputs, width - Theme.PIN_MARGIN_X)

    -- Test button: one small square per exec-in pin, sitting between the pin glyph and its
    -- label. Clicking it fires that exec input directly (ui/graph.lua), so a node's run can be
    -- exercised without wiring a Trigger. The pin's label is pushed right past the button via
    -- `labelInset`, consumed by Node.Draw.
    for _, pin in ipairs(placeholder and {} or inputs) do
        if pin.kind == "exec" then
            local entry = geom.byName[pin.name]
            if entry ~= nil then
                local bw = Theme.TEST_BTN_W
                local bx = Theme.PIN_MARGIN_X + Theme.PIN_GLYPH * 0.5 + Theme.PIN_LABEL_GAP
                geom.testButtons[#geom.testButtons + 1] = {
                    pinName = pin.name,
                    x = bx, y = entry.cy - Theme.CONTROL_H * 0.5,
                    w = bw, h = Theme.CONTROL_H,
                }
                entry.labelInset = bw + Theme.PIN_LABEL_GAP
            end
        end
    end

    -- Control boxes: one group per unconnected data-input Pin whose Type Tag has a Pin Control
    -- (ADR-0005). The Node reserves the band height the module reports and asks it to lay out its
    -- Widgets' sub-rects, tagging each geom.controls entry with the module so the Editor routes
    -- display/click back to it. Two layout shapes, chosen by the Pin Control: an INLINE control
    -- (scalar, enum, swatch, capture) fills the single value-column box to the right of the label;
    -- a BAND control (coordgrid, matcher, mode) lays its Widgets out in the full-width band reserved
    -- beneath the row (rowTop[i+1] - extraH .. rowTop[i+1]).
    local labelStart = Theme.PIN_MARGIN_X + Theme.PIN_GLYPH * 0.5 + Theme.PIN_LABEL_GAP
    for i, pin in ipairs(placeholder and {} or inputs) do
        local pinControl = pinControlFor(pin, connected)
        if pinControl ~= nil then
            local rects
            if pinControl.Inline then
                -- Start the box past the label instead of at a fixed reserve, so it can't cover long
                -- labels like "contains"/"soundId". Measured with real font metrics (Theme.TextWidth)
                -- at the zoom-1 label size — geometry is Graph-space at zoom 1 — falling back to a
                -- per-char estimate when unavailable.
                local label = pin.label or pin.name or ""
                local labelW = Theme.TextWidth(12, label) or (#label * Theme.CONTROL_LABEL_CHAR_W)
                local left = labelStart + labelW + Theme.CONTROL_LABEL_GAP
                local rightInset = (outputs[i] ~= nil) and Theme.CONTROL_OUT_RESERVE or Theme.CONTROL_PAD_X
                local right = width - Theme.PIN_MARGIN_X - rightInset
                if right < left + Theme.CONTROL_MIN_W then right = left + Theme.CONTROL_MIN_W end
                local cy = rowTop[i] + Theme.PIN_ROW_HEIGHT * 0.5
                rects = pinControl.Layout({
                    x = left, y = cy - Theme.CONTROL_H * 0.5, w = right - left, h = Theme.CONTROL_H,
                }) or {}
            else
                local extraH = pinControl.ReservedHeight(pin) or 0
                local band = {
                    x = Theme.PIN_MARGIN_X, y = rowTop[i + 1] - extraH,
                    w = width - Theme.PIN_MARGIN_X * 2, h = extraH,
                }
                rects = pinControl.Layout(band) or {}
            end
            for _, r in ipairs(rects) do
                geom.controls[#geom.controls + 1] = {
                    pinName    = pin.name,
                    pinControl = pinControl,
                    default    = pin.default,
                    -- `kind`/`axis` name the sub-rect for the Editor's press + isEditingThis skip;
                    -- how it PAINTS is the Pin Control's Draw, not a discriminator the Node reads.
                    kind = r.kind, axis = r.axis,
                    enabled = r.enabled,          -- a mode checkbox row's toggle-ability
                    placeholder = r.placeholder,  -- e.g. the matcher needle's / capture's empty-state hint
                    x = r.x, y = r.y, w = r.w, h = r.h,
                }
            end
        end
    end

    return geom
end

-- Absolute Graph-space center of a pin (for wire endpoints).
function Node.PinCenter(geom, pinName)
    local p = geom.byName[pinName]
    if p == nil then return nil end
    return geom.x + p.cx, geom.y + p.cy
end

-- The node's own title/pin labels build the same 1-line shadowed TextDataConfig the control-box
-- Widgets do, so both share Box.TextData (a Node → Widget-helper dependency is allowed; the reverse
-- is not — ADR-0005). Aliased locally so the call sites below read unchanged.
local createTextDataConfig = Box.TextData

-- Draws the node body, header, title, and pin glyphs/labels through the View.
-- meta = { title, category }; opts = { selected = bool, mouseX, mouseY } — the local-space
-- cursor (opts.mouseX/Y) lets the header delete button light up when hovered.
function Node.Draw(canvas, view, geom, meta, opts)
    opts = opts or {}
    local sx, sy = view:ToScreen(geom.x, geom.y)
    local sw, sh = view:Scale(geom.w), view:Scale(geom.h)
    local headerH = view:Scale(Theme.HEADER_HEIGHT)

    -- Body, header band, border. A placeholder (#53) uses its own muted grey palette instead of
    -- a category color, so it reads as an inert stand-in rather than a real node of some type.
    local bodyCol = geom.placeholder and Theme.COL_NODE_UNKNOWN_BODY or Theme.COL_NODE_BODY
    local headerCol = geom.placeholder and Theme.COL_NODE_UNKNOWN_HEADER
        or Theme.CategoryColor(meta.category)
    canvas:AddRectangle(sx, sy, sw, sh, Theme.Vec4(bodyCol))
    canvas:AddRectangle(sx, sy, sw, headerH, Theme.Vec4(headerCol))
    local borderCol = opts.selected and Theme.COL_NODE_SEL or Theme.COL_NODE_BORDER
    canvas:AddOutline(sx, sy, sw, sh, Theme.BORDER_THICKNESS, Theme.Vec4(borderCol))

    local showTitle  = view.zoom >= Theme.TITLE_MIN_ZOOM
    local showLabels = view.zoom >= Theme.LABEL_MIN_ZOOM

    -- Title.
    if showTitle and meta.title then
        local font = Theme.Font(14 * view.zoom)
        if font ~= nil then
            local tw = Theme.TextWidth(14 * view.zoom, meta.title) or (#meta.title * view:Scale(7))
            local textData = createTextDataConfig(font, Theme.Vec4(Theme.COL_TITLE))
            canvas:AddText(sx + view:Scale(Theme.PIN_MARGIN_X),
                sy + headerH * 0.5 - view:Scale(8),
                tw, 0, meta.title, textData)
        end
    end

    -- Header delete button (an X). Only shown when the header is legible (title zoom),
    -- matching HitClose so an invisible button is never clickable.
    if showTitle and geom.close ~= nil then
        local ccx, ccy = view:ToScreen(geom.x + geom.close.cx, geom.y + geom.close.cy)
        local half = view:Scale(Theme.CLOSE_SIZE) * 0.5
        local arm  = half * 0.6
        local hot  = opts.mouseX ~= nil and Node.HitClose(geom, view, opts.mouseX, opts.mouseY)
        if hot then
            canvas:AddRectangle(ccx - half, ccy - half, half * 2, half * 2,
                Theme.Vec4(Theme.COL_CLOSE_BG))
        end
        local col = Theme.Vec4(hot and Theme.COL_CLOSE_HOT or Theme.COL_CLOSE)
        local t = math.max(1, view:Scale(2))
        canvas:AddLine(ccx - arm, ccy - arm, ccx + arm, ccy + arm, t, col)
        canvas:AddLine(ccx - arm, ccy + arm, ccx + arm, ccy - arm, t, col)
    end

    -- Mode strip (ADR-0011): ComboField-lookalike under the header. Skipped while the
    -- transient dropdown is mounted over it (`editingKind == "nodeMode"`).
    if view.zoom >= Theme.CONTROL_MIN_ZOOM and geom.modeStrip ~= nil
        and opts.editingKind ~= "nodeMode" then
        local ms = geom.modeStrip
        local bx, by = view:ToScreen(geom.x + ms.x, geom.y + ms.y)
        local bw, bh = view:Scale(ms.w), view:Scale(ms.h)
        local hot = opts.mouseX ~= nil
            and opts.mouseX >= bx and opts.mouseX <= bx + bw
            and opts.mouseY >= by and opts.mouseY <= by + bh
        local font = Theme.Font(11 * view.zoom)
        local scale = function(n) return view:Scale(n) end
        Dropdown:Draw(canvas, { x = bx, y = by, w = bw, h = bh },
            { display = ms.label },
            { hot = hot, font = font, zoom = view.zoom, scale = scale })
    end

    -- Pins.
    local hs = view:Scale(Theme.PIN_GLYPH) * 0.5
    local labelFont = showLabels and Theme.Font(12 * view.zoom) or nil
    for _, pin in ipairs(geom.pins) do
        local pcx, pcy = view:ToScreen(geom.x + pin.cx, geom.y + pin.cy)

        local color
        if pin.kind == "exec" then
            color = Theme.Vec4(Theme.COL_EXEC)
            -- Right-pointing arrowhead (Blueprint exec shape), same on both sides.
            canvas:AddTriangle(pcx - hs, pcy - hs, pcx - hs, pcy + hs, pcx + hs, pcy, color)
        else
            color = Theme.Vec4(Theme.TypeColor(pin.dataType))
            canvas:AddRectangle(pcx - hs, pcy - hs, hs * 2, hs * 2, color)
        end

        if labelFont ~= nil then
            local labelCol = Theme.Vec4(Theme.COL_PIN_LABEL)
            local ty = pcy - view:Scale(7)
            local tw = Theme.TextWidth(12 * view.zoom, pin.label) or (#pin.label * view:Scale(7))
            local textData = createTextDataConfig(labelFont, labelCol)
            if pin.direction == "in" then
                -- An exec-in pin's label is pushed right to clear its test button (labelInset,
                -- set in BuildGeometry); every other pin has no inset.
                local inset = Theme.PIN_LABEL_GAP + (pin.labelInset or 0)
                -- canvas:AddText(pcx + hs + view:Scale(inset), ty,
                --     pin.label, labelFont, labelCol)
                canvas:AddText(pcx + hs + view:Scale(inset), ty,
                    tw, 0, pin.label, textData)
            else
                -- Right-align output labels against the glyph (measured at the drawn size).
                canvas:AddText(pcx - hs - view:Scale(Theme.PIN_LABEL_GAP) - tw, ty,
                    tw, 0, pin.label, textData)
            end
        end
    end

    -- Control value boxes. Skipped when zoomed too far out to read, and the box currently
    -- being edited is skipped entirely — the transient InputField/ComboField covers it. A
    -- composite Control (#25) contributes several boxes sharing one pinName, so the "is this
    -- the one being edited" check also matches kind/axis — otherwise opening the editor on
    -- one coordgrid field would blank out its whole band.
    --
    -- Each box's paint is the Widget's own (ADR-0005 #63 render seam): the Node projects the
    -- graph-space rect to screen, computes `hot`, and hands both to the Pin Control's Draw with a
    -- small draw-context (dctx) — there is NO `kind`/`widget` branch here. The Node keeps only what
    -- is genuinely its own: the row/View transform and the isEditingThis skip (the transient editor
    -- overlay is an Editor concern, not the control's). The Widget never sees `view`/ToScreen/Scale.
    if view.zoom >= Theme.CONTROL_MIN_ZOOM then
        local ctrlFont = Theme.Font(11 * view.zoom)
        local scale = function(n) return view:Scale(n) end
        for _, ctrl in ipairs(geom.controls) do
            local isEditingThis = ctrl.pinName == opts.editingPin
                and ctrl.kind == opts.editingKind and ctrl.axis == opts.editingAxis
            if not isEditingThis then
                local bx, by = view:ToScreen(geom.x + ctrl.x, geom.y + ctrl.y)
                local bw, bh = view:Scale(ctrl.w), view:Scale(ctrl.h)
                local hot = opts.mouseX ~= nil
                    and opts.mouseX >= bx and opts.mouseX <= bx + bw
                    and opts.mouseY >= by and opts.mouseY <= by + bh
                ctrl.pinControl.Draw(canvas, { x = bx, y = by, w = bw, h = bh }, ctrl,
                    { hot = hot, font = ctrlFont, zoom = view.zoom, scale = scale })
            end
        end

        -- Test buttons (one per exec-in pin): a green square with a ▶ play triangle, gated on
        -- the same CONTROL_MIN_ZOOM as Control boxes so an undrawn button is never hittable.
        for _, tb in ipairs(geom.testButtons) do
            local bx, by = view:ToScreen(geom.x + tb.x, geom.y + tb.y)
            local bw, bh = view:Scale(tb.w), view:Scale(tb.h)
            local hot = opts.mouseX ~= nil
                and opts.mouseX >= bx and opts.mouseX <= bx + bw
                and opts.mouseY >= by and opts.mouseY <= by + bh
            canvas:AddRectangle(bx, by, bw, bh, Theme.Vec4(Theme.COL_TEST_BTN_BG))
            canvas:AddOutline(bx, by, bw, bh, math.max(1, view:Scale(1)),
                Theme.Vec4(hot and Theme.COL_TEST_BTN_HOT or Theme.COL_NODE_BORDER))
            -- Centered right-pointing play triangle.
            local cx, cy = bx + bw * 0.5, by + bh * 0.5
            local a = view:Scale(4)
            local glyph = Theme.Vec4(hot and Theme.COL_TEST_BTN_HOT or Theme.COL_TEST_BTN_GLYPH)
            canvas:AddTriangle(cx - a * 0.7, cy - a, cx - a * 0.7, cy + a, cx + a, cy, glyph)
        end
    end
end

-- Returns the test-button entry under the screen point (sx,sy), or nil. Gated on the same zoom
-- threshold as Draw so an undrawn button is never clickable.
function Node.TestButtonAt(geom, view, sx, sy)
    if view.zoom < Theme.CONTROL_MIN_ZOOM then return nil end
    for _, tb in ipairs(geom.testButtons) do
        local bx, by = view:ToScreen(geom.x + tb.x, geom.y + tb.y)
        local bw, bh = view:Scale(tb.w), view:Scale(tb.h)
        if sx >= bx and sx <= bx + bw and sy >= by and sy <= by + bh then
            return tb
        end
    end
    return nil
end

-- Returns the pin entry under the screen point (sx,sy), or nil. Hit area is the glyph
-- plus a constant screen-space pad so pins stay clickable when zoomed out.
function Node.PinAt(geom, view, sx, sy)
    local half = view:Scale(Theme.PIN_GLYPH) * 0.5 + Theme.PIN_HIT_PAD
    for _, pin in ipairs(geom.pins) do
        local pcx, pcy = view:ToScreen(geom.x + pin.cx, geom.y + pin.cy)
        if sx >= pcx - half and sx <= pcx + half
            and sy >= pcy - half and sy <= pcy + half then
            return pin
        end
    end
    return nil
end

-- Returns the control entry under the screen point (sx,sy), or nil. Gated on the same zoom
-- threshold as Draw so an undrawn box is never clickable.
function Node.ControlAt(geom, view, sx, sy)
    if view.zoom < Theme.CONTROL_MIN_ZOOM then return nil end
    for _, ctrl in ipairs(geom.controls) do
        local bx, by = view:ToScreen(geom.x + ctrl.x, geom.y + ctrl.y)
        local bw, bh = view:Scale(ctrl.w), view:Scale(ctrl.h)
        if sx >= bx and sx <= bx + bw and sy >= by and sy <= by + bh then
            return ctrl
        end
    end
    return nil
end

-- Whether the screen point is over this node's header delete button. Gated on title zoom
-- so it matches Draw — the glyph isn't drawn (and mustn't be hittable) when zoomed too far
-- out to read the header.
function Node.HitClose(geom, view, sx, sy)
    if geom.close == nil or view.zoom < Theme.TITLE_MIN_ZOOM then return false end
    local ccx, ccy = view:ToScreen(geom.x + geom.close.cx, geom.y + geom.close.cy)
    local half = view:Scale(Theme.CLOSE_SIZE) * 0.5 + Theme.PIN_HIT_PAD
    return sx >= ccx - half and sx <= ccx + half
        and sy >= ccy - half and sy <= ccy + half
end

-- Whether the screen point is over this node's Mode strip. Gated on CONTROL_MIN_ZOOM so it
-- matches Draw — an undrawn strip is never clickable.
function Node.HitModeStrip(geom, view, sx, sy)
    if geom.modeStrip == nil or view.zoom < Theme.CONTROL_MIN_ZOOM then return false end
    local ms = geom.modeStrip
    local bx, by = view:ToScreen(geom.x + ms.x, geom.y + ms.y)
    local bw, bh = view:Scale(ms.w), view:Scale(ms.h)
    return sx >= bx and sx <= bx + bw and sy >= by and sy <= by + bh
end

-- Whether the screen point is over this node's body rect.
function Node.HitBody(geom, view, sx, sy)
    local x0, y0 = view:ToScreen(geom.x, geom.y)
    local x1, y1 = view:ToScreen(geom.x + geom.w, geom.y + geom.h)
    return sx >= x0 and sx <= x1 and sy >= y0 and sy <= y1
end

return Node
