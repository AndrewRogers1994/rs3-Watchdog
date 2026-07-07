-- node.lua — Node Body geometry, drawing, and pin/body hit-testing.
--
-- Geometry is computed once per frame (BuildGeometry, pure Graph-space) and shared by
-- Draw and the hit helpers, so what you see and what you click can never disagree.
-- All stored geometry is Graph-space; the View converts to Screen-space at draw/hit time.

local Theme = require("ui/theme")

local Node = {}

-- Splits a node's pins into left (inputs) / right (outputs) columns and assigns each a
-- Graph-space center relative to the node origin. Returns a geometry table consumed by
-- Draw, PinAt and HitBody. `pins` is the list from graph:GetPins(nodeId).
function Node.BuildGeometry(pins, x, y, width)
    width = width or Theme.NODE_WIDTH

    local inputs, outputs = {}, {}
    for _, pin in ipairs(pins) do
        if pin.direction == "in" then
            inputs[#inputs + 1] = pin
        else
            outputs[#outputs + 1] = pin
        end
    end

    local rows = math.max(#inputs, #outputs)
    local height = Theme.HEADER_HEIGHT + Theme.BODY_PAD_TOP
        + rows * Theme.PIN_ROW_HEIGHT + Theme.BODY_PAD_BOTTOM

    local geom = { x = x, y = y, w = width, h = height, pins = {}, byName = {} }

    -- Delete button center, in the header, Graph-space relative to the node origin. Shared
    -- by Draw and HitClose so the glyph and its hit-target can't disagree.
    geom.close = { cx = width - Theme.CLOSE_MARGIN, cy = Theme.HEADER_HEIGHT * 0.5 }

    local function place(list, cx)
        for i, pin in ipairs(list) do
            local cy = Theme.HEADER_HEIGHT + Theme.BODY_PAD_TOP
                + (i - 0.5) * Theme.PIN_ROW_HEIGHT
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

    return geom
end

-- Absolute Graph-space center of a pin (for wire endpoints).
function Node.PinCenter(geom, pinName)
    local p = geom.byName[pinName]
    if p == nil then return nil end
    return geom.x + p.cx, geom.y + p.cy
end

local function calcTextWidth(fontID, text)
    if Interface == nil or Interface.CalcTextWidth == nil then return nil end
    local ok, w = pcall(function() return Interface.CalcTextWidth(fontID, text) end)
    if ok then return w end
    return nil
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
                -- Right-align output labels against the glyph.
                local tw = calcTextWidth(labelFont, pin.label) or (#pin.label * view:Scale(7))
                canvas:AddText(pcx - hs - view:Scale(Theme.PIN_LABEL_GAP) - tw, ty,
                    pin.label, labelFont, labelCol)
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
