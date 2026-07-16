-- node.lua — Node Body geometry, drawing, and pin/body hit-testing.
--
-- Geometry is computed once per frame (BuildGeometry, pure Graph-space) and shared by
-- Draw and the hit helpers, so what you see and what you click can never disagree.
-- All stored geometry is Graph-space; the View converts to Screen-space at draw/hit time.

local Theme    = require("ui/theme")
local Controls = require("ui/controls")
local Color    = require("ui/color")

local Node = {}

-- Splits a node's pins into left (inputs) / right (outputs) columns and assigns each a
-- Graph-space center relative to the node origin. Returns a geometry table consumed by
-- Draw, PinAt and HitBody. `pins` is the list from graph:GetPins(nodeId). `opts.connected`
-- is a set { [pinName] = true } of input pins that already have an incoming Connection —
-- those get a wire, not a Control box (ADR-0004).
-- The Control Spec for a data-input pin eligible for a Control box: unconnected, kind
-- "data", and its Type Tag has a spec. Returns nil for anything else (exec pins, connected
-- inputs, tags with no spec).
local function controlSpecFor(pin, connected)
    if pin.kind ~= "data" or connected[pin.name] then return nil end
    return Controls.For(pin.dataType)
end

function Node.BuildGeometry(pins, x, y, width, opts)
    width = width or Theme.NODE_WIDTH
    local connected = (opts and opts.connected) or {}

    local inputs, outputs = {}, {}
    for _, pin in ipairs(pins) do
        if pin.direction == "in" then
            inputs[#inputs + 1] = pin
        else
            outputs[#outputs + 1] = pin
        end
    end

    local rows = math.max(#inputs, #outputs)

    -- Row tops, cumulative (#25): row i normally advances by a fixed PIN_ROW_HEIGHT, but a
    -- composite Control on that row's input pin (e.g. coordgrid) reserves extra band height
    -- below it via spec.extraH(pin), pushing every later row down. Scalar/no-control rows
    -- have extraH 0, so this collapses to the old fixed-stride math. Both pin columns (inputs
    -- AND outputs) share this same rowTop table so a row's input and output glyph stay
    -- vertically aligned even when only the input side grew.
    local rowTop = {}
    do
        local cy = Theme.HEADER_HEIGHT + Theme.BODY_PAD_TOP
        for i = 1, rows do
            rowTop[i] = cy
            local extraH = 0
            local pin = inputs[i]
            if pin ~= nil then
                local spec = controlSpecFor(pin, connected)
                if spec ~= nil and spec.extraH ~= nil then
                    extraH = spec.extraH(pin) or 0
                end
            end
            cy = cy + Theme.PIN_ROW_HEIGHT + extraH
        end
        rowTop[rows + 1] = cy
    end
    local height = rowTop[rows + 1] + Theme.BODY_PAD_BOTTOM

    local geom = { x = x, y = y, w = width, h = height, pins = {}, byName = {}, controls = {} }

    -- Delete button center, in the header, Graph-space relative to the node origin. Shared
    -- by Draw and HitClose so the glyph and its hit-target can't disagree.
    geom.close = { cx = width - Theme.CLOSE_MARGIN, cy = Theme.HEADER_HEIGHT * 0.5 }

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

    -- Control boxes: one group per unconnected data-input Pin whose Type Tag has a spec.
    -- A scalar spec contributes one box in the "value column" to the right of the pin label
    -- (stopping short of an output glyph sharing the row via CONTROL_OUT_RESERVE); a composite
    -- spec (widget == "composite") instead lays out its own sub-rects in the full-width band
    -- reserved below the row (rowTop[i+1] - extraH .. rowTop[i+1]), via spec.Layout.
    local labelStart = Theme.PIN_MARGIN_X + Theme.PIN_GLYPH * 0.5 + Theme.PIN_LABEL_GAP
    for i, pin in ipairs(inputs) do
        local spec = controlSpecFor(pin, connected)
        if spec ~= nil then
            local cy = rowTop[i] + Theme.PIN_ROW_HEIGHT * 0.5

            if spec.widget == "composite" then
                local extraH = (spec.extraH ~= nil) and (spec.extraH(pin) or 0) or 0
                local band = {
                    x = Theme.PIN_MARGIN_X, y = rowTop[i + 1] - extraH,
                    w = width - Theme.PIN_MARGIN_X * 2, h = extraH,
                }
                local rects = spec.Layout and spec.Layout(band) or {}
                for _, r in ipairs(rects) do
                    geom.controls[#geom.controls + 1] = {
                        pinName = pin.name,
                        widget  = spec.widget,
                        spec    = spec,
                        default = pin.default,
                        kind = r.kind, axis = r.axis,
                        x = r.x, y = r.y, w = r.w, h = r.h,
                    }
                end
            else
                -- Start the box past the label instead of at a fixed reserve, so it can't
                -- cover long labels like "contains"/"soundId". Measured with real font
                -- metrics (Theme.TextWidth) at the zoom-1 label size — geometry is Graph-
                -- space at zoom 1 — falling back to a per-char estimate when unavailable.
                local label = pin.label or pin.name or ""
                local labelW = Theme.TextWidth(12, label) or (#label * Theme.CONTROL_LABEL_CHAR_W)
                local left = labelStart + labelW + Theme.CONTROL_LABEL_GAP
                local rightInset = (outputs[i] ~= nil) and Theme.CONTROL_OUT_RESERVE or Theme.CONTROL_PAD_X
                local right = width - Theme.PIN_MARGIN_X - rightInset
                if right < left + Theme.CONTROL_MIN_W then right = left + Theme.CONTROL_MIN_W end

                if spec.widget == "swatch" then
                    -- A fixed-width chip flush against the value column's right edge (#30),
                    -- not a full-width text box — narrower reads as a color swatch. `kind`
                    -- discriminates it from a scalar text/enum/number box the same way a
                    -- composite Control's sub-rects do, even though there's only ever one.
                    local swW = math.min(Theme.SWATCH_W, right - left)
                    geom.controls[#geom.controls + 1] = {
                        pinName = pin.name,
                        widget  = spec.widget,
                        spec    = spec,
                        default = pin.default,
                        kind = "swatch",
                        x = right - swW, y = cy - Theme.CONTROL_H * 0.5,
                        w = swW, h = Theme.CONTROL_H,
                    }
                else
                    geom.controls[#geom.controls + 1] = {
                        pinName = pin.name,
                        widget  = spec.widget,
                        spec    = spec,
                        default = pin.default,  -- shown/edited when the stored Control is nil
                        x = left, y = cy - Theme.CONTROL_H * 0.5,
                        w = right - left, h = Theme.CONTROL_H,
                    }
                end
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

-- Draws the node body, header, title, and pin glyphs/labels through the View.
-- meta = { title, category }; opts = { selected = bool, mouseX, mouseY } — the local-space
-- cursor (opts.mouseX/Y) lets the header delete button light up when hovered.
function Node.Draw(canvas, view, geom, meta, opts)
    opts = opts or {}
    local sx, sy = view:ToScreen(geom.x, geom.y)
    local sw, sh = view:Scale(geom.w), view:Scale(geom.h)
    local headerH = view:Scale(Theme.HEADER_HEIGHT)

    -- Body, header band, border.
    canvas:AddRectangle(sx, sy, sw, sh, Theme.Vec4(Theme.COL_NODE_BODY))
    canvas:AddRectangle(sx, sy, sw, headerH, Theme.Vec4(Theme.CategoryColor(meta.category)))
    local borderCol = opts.selected and Theme.COL_NODE_SEL or Theme.COL_NODE_BORDER
    canvas:AddOutline(sx, sy, sw, sh, Theme.BORDER_THICKNESS, Theme.Vec4(borderCol))

    local showTitle  = view.zoom >= Theme.TITLE_MIN_ZOOM
    local showLabels = view.zoom >= Theme.LABEL_MIN_ZOOM

    -- Title.
    if showTitle and meta.title then
        local font = Theme.Font(14 * view.zoom)
        if font ~= nil then
            canvas:AddText(sx + view:Scale(Theme.PIN_MARGIN_X),
                sy + headerH * 0.5 - view:Scale(8),
                meta.title, font, Theme.Vec4(Theme.COL_TITLE))
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
            if pin.direction == "in" then
                canvas:AddText(pcx + hs + view:Scale(Theme.PIN_LABEL_GAP), ty,
                    pin.label, labelFont, labelCol)
            else
                -- Right-align output labels against the glyph (measured at the drawn size).
                local tw = Theme.TextWidth(12 * view.zoom, pin.label) or (#pin.label * view:Scale(7))
                canvas:AddText(pcx - hs - view:Scale(Theme.PIN_LABEL_GAP) - tw, ty,
                    pin.label, labelFont, labelCol)
            end
        end
    end

    -- Control value boxes. Skipped when zoomed too far out to read, and the box currently
    -- being edited is skipped entirely — the transient InputField/ComboField covers it. A
    -- composite Control (#25) contributes several boxes sharing one pinName, so the "is this
    -- the one being edited" check also matches kind/axis — otherwise opening the editor on
    -- one coordgrid field would blank out its whole band.
    if view.zoom >= Theme.CONTROL_MIN_ZOOM then
        local ctrlFont = Theme.Font(11 * view.zoom)
        for _, ctrl in ipairs(geom.controls) do
            local isEditingThis = ctrl.pinName == opts.editingPin
                and ctrl.kind == opts.editingKind and ctrl.axis == opts.editingAxis
            if not isEditingThis then
                local bx, by = view:ToScreen(geom.x + ctrl.x, geom.y + ctrl.y)
                local bw, bh = view:Scale(ctrl.w), view:Scale(ctrl.h)
                local hot = opts.mouseX ~= nil
                    and opts.mouseX >= bx and opts.mouseX <= bx + bw
                    and opts.mouseY >= by and opts.mouseY <= by + bh

                if ctrl.kind == "swatch" then
                    -- Checker-backed so alpha reads visually; no value at all (nil Control
                    -- AND nil pin default, #30's "never fires until set") draws as a plain
                    -- empty box instead of implying a color that was never actually chosen.
                    if ctrl.value == nil then
                        canvas:AddRectangle(bx, by, bw, bh, Theme.Vec4(Theme.COL_CONTROL_BG))
                    else
                        Color.DrawChecker(canvas, bx, by, bw, bh, view:Scale(Theme.SWATCH_CHECKER_CELL),
                            Theme.Vec4(Theme.COL_CHECKER_LIGHT), Theme.Vec4(Theme.COL_CHECKER_DARK))
                        local v = ctrl.value
                        local a = (v.a == nil) and 255 or v.a
                        canvas:AddRectangle(bx, by, bw, bh, Vector4.new(v.r / 255, v.g / 255, v.b / 255, a / 255))
                    end
                    canvas:AddOutline(bx, by, bw, bh, math.max(1, view:Scale(1)),
                        Theme.Vec4(hot and Theme.COL_CONTROL_HOT or Theme.COL_CONTROL_BORDER))
                else
                    local bg = (ctrl.kind == "action") and Theme.COL_CONTROL_ACTION_BG or Theme.COL_CONTROL_BG
                    canvas:AddRectangle(bx, by, bw, bh, Theme.Vec4(bg))
                    canvas:AddOutline(bx, by, bw, bh, math.max(1, view:Scale(1)),
                        Theme.Vec4(hot and Theme.COL_CONTROL_HOT or Theme.COL_CONTROL_BORDER))

                    if ctrlFont ~= nil then
                        local text = ctrl.display
                        local col = Theme.Vec4(Theme.COL_CONTROL_TEXT)
                        if text == nil or text == "" then
                            text, col = ctrl.placeholder or "…", Theme.Vec4(Theme.COL_CONTROL_EMPTY)
                        end
                        canvas:AddText(bx + view:Scale(Theme.CONTROL_PAD_X), by + bh * 0.5 - view:Scale(6),
                            text, ctrlFont, col)
                    end

                    -- Enum dropdown indicator: a small ▾ drawn as a filled triangle at the right.
                    if ctrl.widget == "enum" then
                        local cxr = bx + bw - view:Scale(7)
                        local cyr = by + bh * 0.5
                        local a = view:Scale(3)
                        canvas:AddTriangle(cxr - a, cyr - a, cxr + a, cyr - a, cxr, cyr + a,
                            Theme.Vec4(Theme.COL_CONTROL_CARET))
                    end
                end
            end
        end
    end
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

-- Whether the screen point is over this node's body rect.
function Node.HitBody(geom, view, sx, sy)
    local x0, y0 = view:ToScreen(geom.x, geom.y)
    local x1, y1 = view:ToScreen(geom.x + geom.w, geom.y + geom.h)
    return sx >= x0 and sx <= x1 and sy >= y0 and sy <= y1
end

return Node
