-- HSV is source of truth so hue survives a drag to s=0 / v=0.

local Theme = require("src/ui/theme")
local Color = require("src/ui/color")

local ColorPopup = {}
ColorPopup.__index = ColorPopup

local function clamp01(t)
    if t < 0 then return 0 end
    if t > 1 then return 1 end
    return t
end

-- AddGradientH interpolates 2 colors; hue strip is 6 segments over these stops.
local HUE_STOPS = {
    { 1, 0, 0 }, { 1, 1, 0 }, { 0, 1, 0 }, { 0, 1, 1 }, { 0, 0, 1 }, { 1, 0, 1 }, { 1, 0, 0 },
}

function ColorPopup.new()
    return setmetatable({
        open = false,
        nodeId = nil,
        pinName = nil,
        codec = nil,
        value = { r = 255, g = 255, b = 255, a = 255 },
        prevValue = nil,   -- value at Open, for the "prev" chip
        h = 0, s = 0, v = 1,
        screenX = 0, screenY = 0,  -- clamped into Viewport at Draw
        rect = nil,
    }, ColorPopup)
end

function ColorPopup:Open(nodeId, pinName, codec, value, anchorX, anchorY)
    self.open = true
    self.nodeId = nodeId
    self.pinName = pinName
    self.codec = codec
    self.screenX, self.screenY = anchorX, anchorY
    local seed = value or { r = 255, g = 255, b = 255, a = 255 }
    self.value = {
        r = Color.ClampByte(seed.r or 255), g = Color.ClampByte(seed.g or 255),
        b = Color.ClampByte(seed.b or 255), a = Color.ClampByte(seed.a == nil and 255 or seed.a),
    }
    self.prevValue = { r = self.value.r, g = self.value.g, b = self.value.b, a = self.value.a }
    self.h, self.s, self.v = Color.RGBtoHSV(self.value.r, self.value.g, self.value.b)
    self.rect = nil
end

function ColorPopup:Close()
    self.open = false
    self.nodeId = nil
    self.pinName = nil
    self.codec = nil
    self.rect = nil
end

function ColorPopup:Format(value)
    local c = self.codec
    if c == nil or c.format == nil then return "" end
    local ok, s = pcall(c.format, value)
    if ok and s ~= nil then return tostring(s) end
    return ""
end

function ColorPopup:Parse(raw, current)
    local c = self.codec
    if c == nil or c.parse == nil then return current end
    local ok, v = pcall(c.parse, raw, current)
    if ok then return v end
    return current
end

-- Copy; callers must not mutate popup state through the returned table.
function ColorPopup:Value()
    return { r = self.value.r, g = self.value.g, b = self.value.b, a = self.value.a }
end

function ColorPopup:SetValue(value)
    if value == nil then return end
    self.value = {
        r = Color.ClampByte(value.r or 0), g = Color.ClampByte(value.g or 0),
        b = Color.ClampByte(value.b or 0), a = Color.ClampByte(value.a == nil and 255 or value.a),
    }
    self.h, self.s, self.v = Color.RGBtoHSV(self.value.r, self.value.g, self.value.b)
end

--- Layout ----------------------------------------------------------------------------------

function ColorPopup:layout()
    local w = Theme.COLOR_POPUP_W
    local pad = Theme.COLOR_POPUP_PAD
    local gap = Theme.COLOR_POPUP_ROW_GAP
    local rowH = Theme.COLOR_POPUP_ROW_H
    local contentW = w - pad * 2

    local cy = Theme.COLOR_POPUP_HEADER_H + pad
    local sv = { x = pad, y = cy, w = contentW, h = Theme.COLOR_POPUP_SV_H }
    cy = cy + sv.h + gap
    local hue = { x = pad, y = cy, w = contentW, h = Theme.COLOR_POPUP_HUE_H }
    cy = cy + hue.h + gap

    local chipW = (contentW - gap) / 2
    local prevChip = { x = pad, y = cy, w = chipW, h = rowH }
    local curChip  = { x = pad + chipW + gap, y = cy, w = chipW, h = rowH }
    cy = cy + rowH + gap

    local hex = { x = pad, y = cy, w = contentW, h = rowH }
    cy = cy + rowH + gap

    local function chanRow()
        local r = { x = pad, y = cy, w = contentW, h = rowH }
        cy = cy + rowH + gap
        return r
    end
    local r, g, b, a = chanRow(), chanRow(), chanRow(), chanRow()

    return {
        w = w, h = cy - gap + pad,
        sv = sv, hue = hue, prevChip = prevChip, curChip = curChip, hex = hex,
        r = r, g = g, b = b, a = a,
        close = { cx = w - pad - 6, cy = Theme.COLOR_POPUP_HEADER_H * 0.5 },
    }
end

--- Drag application (screen-space points; uses the rect Draw last recorded) --------------

function ColorPopup:ApplyDrag(part, sx, sy)
    local r = self.rect
    if r == nil then return end

    if part == "sv" then
        local rr = r.sv
        self.s = clamp01((sx - rr.x) / rr.w)
        self.v = 1 - clamp01((sy - rr.y) / rr.h)
        self.value.r, self.value.g, self.value.b = Color.HSVtoRGB(self.h, self.s, self.v)
    elseif part == "hue" then
        local rr = r.hue
        self.h = clamp01((sx - rr.x) / rr.w) * 360
        self.value.r, self.value.g, self.value.b = Color.HSVtoRGB(self.h, self.s, self.v)
    elseif part == "r" or part == "g" or part == "b" or part == "a" then
        local rr = r[part]
        local byte = Color.ClampByte(clamp01((sx - rr.x) / rr.w) * 255)
        self.value[part] = byte
        if part ~= "a" then
            self.h, self.s, self.v = Color.RGBtoHSV(self.value.r, self.value.g, self.value.b)
        end
    end
end

--- Hit-testing (uses the rect from the last Draw) -----------------------------------------

-- "other" = inside padding/header/chips (keep open); nil = outside or not drawn yet.
function ColorPopup:PartAt(sx, sy)
    local r = self.rect
    if not self.open or r == nil then return nil end
    if not self:Contains(sx, sy) then return nil end

    local half = 8  -- close-glyph hit pad, same idea as Node.HitClose's PIN_HIT_PAD
    if sx >= r.close.cx - half and sx <= r.close.cx + half
        and sy >= r.close.cy - half and sy <= r.close.cy + half then
        return "close"
    end

    local function within(rr)
        return sx >= rr.x and sx <= rr.x + rr.w and sy >= rr.y and sy <= rr.y + rr.h
    end
    if within(r.sv) then return "sv" end
    if within(r.hue) then return "hue" end
    if within(r.hex) then return "hex" end
    if within(r.r) then return "r" end
    if within(r.g) then return "g" end
    if within(r.b) then return "b" end
    if within(r.a) then return "a" end
    return "other"
end

function ColorPopup:Contains(sx, sy)
    local r = self.rect
    if not self.open or r == nil then return false end
    return sx >= r.x and sx <= r.x + r.w and sy >= r.y and sy <= r.y + r.h
end

--- Drawing -----------------------------------------------------------------------------

-- opts.hexEditing skips hex text; a transient InputField sits over the box (same as Node.Draw).
function ColorPopup:Draw(canvas, vx, vy, vw, vh, mx, my, opts)
    if not self.open then return end
    opts = opts or {}

    local L = self:layout()
    local px, py = self.screenX, self.screenY
    if px + L.w > vx + vw then px = vx + vw - L.w end
    if py + L.h > vy + vh then py = vy + vh - L.h end
    if px < vx then px = vx end
    if py < vy then py = vy end

    local function abs(rr) return { x = px + rr.x, y = py + rr.y, w = rr.w, h = rr.h } end
    local rect = {
        x = px, y = py, w = L.w, h = L.h,
        sv = abs(L.sv), hue = abs(L.hue), prevChip = abs(L.prevChip), curChip = abs(L.curChip),
        hex = abs(L.hex), r = abs(L.r), g = abs(L.g), b = abs(L.b), a = abs(L.a),
        close = { cx = px + L.close.cx, cy = py + L.close.cy },
    }
    self.rect = rect

    self:drawChrome(canvas, rect)
    self:drawSV(canvas, rect.sv)
    self:drawHue(canvas, rect.hue)
    self:drawChips(canvas, rect.prevChip, rect.curChip)
    if not opts.hexEditing then self:drawHex(canvas, rect.hex) end
    self:drawChannelRow(canvas, rect.r, "R", self.value.r, function(v) return { r = v, g = 0, b = 0 } end)
    self:drawChannelRow(canvas, rect.g, "G", self.value.g, function(v) return { r = 0, g = v, b = 0 } end)
    self:drawChannelRow(canvas, rect.b, "B", self.value.b, function(v) return { r = 0, g = 0, b = v } end)
    self:drawAlphaRow(canvas, rect.a)
end

function ColorPopup:drawChrome(canvas, rect)
    canvas:AddRectangle(rect.x, rect.y, rect.w, rect.h, Theme.Vec4(Theme.COL_PALETTE_BG))
    canvas:AddRectangle(rect.x, rect.y, rect.w, Theme.COLOR_POPUP_HEADER_H,
        Theme.Vec4(Theme.COL_PALETTE_HEADER_BG))
    canvas:AddOutline(rect.x, rect.y, rect.w, rect.h, Theme.BORDER_THICKNESS,
        Theme.Vec4(Theme.COL_PALETTE_BORDER))

    local font = Theme.Font(12)
    if font ~= nil then
        canvas:AddText(rect.x + Theme.COLOR_POPUP_PAD, rect.y + 5, "Color", font,
            Theme.Vec4(Theme.COL_PALETTE_HEADER_TX))
    end

    local half = 5
    local col = Theme.Vec4(Theme.COL_CLOSE)
    canvas:AddLine(rect.close.cx - half, rect.close.cy - half, rect.close.cx + half, rect.close.cy + half, 2, col)
    canvas:AddLine(rect.close.cx - half, rect.close.cy + half, rect.close.cx + half, rect.close.cy - half, 2, col)
end

function ColorPopup:drawSV(canvas, r)
    local hr, hg, hb = Color.HSVtoRGB(self.h, 1, 1)
    canvas:AddRectangle(r.x, r.y, r.w, r.h, Vector4.new(hr / 255, hg / 255, hb / 255, 1))
    canvas:AddGradientH(r.x, r.y, r.w, r.h, Vector4.new(1, 1, 1, 1), Vector4.new(1, 1, 1, 0))
    canvas:AddGradientV(r.x, r.y, r.w, r.h, Vector4.new(0, 0, 0, 0), Vector4.new(0, 0, 0, 1))
    canvas:AddOutline(r.x, r.y, r.w, r.h, 1, Theme.Vec4(Theme.COL_PALETTE_BORDER))

    -- White ringed in black so the SV cursor reads on any hue.
    local cx = r.x + self.s * r.w
    local cy = r.y + (1 - self.v) * r.h
    local half = 4
    canvas:AddOutline(cx - half - 1, cy - half - 1, half * 2 + 2, half * 2 + 2, 1, Vector4.new(0, 0, 0, 1))
    canvas:AddOutline(cx - half, cy - half, half * 2, half * 2, 1, Vector4.new(1, 1, 1, 1))
end

function ColorPopup:drawHue(canvas, r)
    local segW = r.w / 6
    for i = 1, 6 do
        local c0, c1 = HUE_STOPS[i], HUE_STOPS[i + 1]
        canvas:AddGradientH(r.x + (i - 1) * segW, r.y, segW, r.h,
            Vector4.new(c0[1], c0[2], c0[3], 1), Vector4.new(c1[1], c1[2], c1[3], 1))
    end
    canvas:AddOutline(r.x, r.y, r.w, r.h, 1, Theme.Vec4(Theme.COL_PALETTE_BORDER))

    local kx = r.x + (self.h / 360) * r.w
    canvas:AddRectangle(kx - 1.5, r.y - 1, 3, r.h + 2, Vector4.new(1, 1, 1, 1))
    canvas:AddOutline(kx - 1.5, r.y - 1, 3, r.h + 2, 1, Vector4.new(0, 0, 0, 1))
end

function ColorPopup:drawChips(canvas, prevChip, curChip)
    local function chip(rr, value)
        Color.DrawChecker(canvas, rr.x, rr.y, rr.w, rr.h, Theme.COLOR_POPUP_CHECKER_CELL,
            Theme.Vec4(Theme.COL_CHECKER_LIGHT), Theme.Vec4(Theme.COL_CHECKER_DARK))
        local a = (value.a == nil) and 255 or value.a
        canvas:AddRectangle(rr.x, rr.y, rr.w, rr.h, Vector4.new(value.r / 255, value.g / 255, value.b / 255, a / 255))
        canvas:AddOutline(rr.x, rr.y, rr.w, rr.h, 1, Theme.Vec4(Theme.COL_PALETTE_BORDER))
    end
    chip(prevChip, self.prevValue or self.value)
    chip(curChip, self.value)
end

function ColorPopup:drawHex(canvas, r)
    canvas:AddRectangle(r.x, r.y, r.w, r.h, Theme.Vec4(Theme.COL_CONTROL_BG))
    canvas:AddOutline(r.x, r.y, r.w, r.h, 1, Theme.Vec4(Theme.COL_CONTROL_BORDER))
    local font = Theme.Font(11)
    if font ~= nil then
        -- Codec format hook (same as hex commit), not Color.FormatHex8.
        canvas:AddText(r.x + 4, r.y + r.h * 0.5 - 6, "#" .. self:Format(self.value), font,
            Theme.Vec4(Theme.COL_CONTROL_TEXT))
    end
end

function ColorPopup:drawChannelRow(canvas, r, label, byte, channelAt)
    local font = Theme.Font(11)
    local labelW = 12
    local valueW = 28
    local trackX, trackW = r.x + labelW, r.w - labelW - valueW
    local trackR = { x = trackX, y = r.y + 2, w = trackW, h = r.h - 4 }

    if font ~= nil then
        canvas:AddText(r.x, r.y + r.h * 0.5 - 6, label, font, Theme.Vec4(Theme.COL_PIN_LABEL))
    end

    local lo, hi = channelAt(0), channelAt(255)
    canvas:AddGradientH(trackR.x, trackR.y, trackR.w, trackR.h,
        Vector4.new(lo.r / 255, lo.g / 255, lo.b / 255, 1),
        Vector4.new(hi.r / 255, hi.g / 255, hi.b / 255, 1))
    canvas:AddOutline(trackR.x, trackR.y, trackR.w, trackR.h, 1, Theme.Vec4(Theme.COL_PALETTE_BORDER))

    local kx = trackR.x + (byte / 255) * trackR.w
    canvas:AddRectangle(kx - 1.5, trackR.y - 1, 3, trackR.h + 2, Vector4.new(1, 1, 1, 1))
    canvas:AddOutline(kx - 1.5, trackR.y - 1, 3, trackR.h + 2, 1, Vector4.new(0, 0, 0, 1))

    if font ~= nil then
        canvas:AddText(r.x + r.w - valueW + 4, r.y + r.h * 0.5 - 6, tostring(byte), font,
            Theme.Vec4(Theme.COL_CONTROL_TEXT))
    end
end

function ColorPopup:drawAlphaRow(canvas, r)
    local font = Theme.Font(11)
    local labelW = 12
    local valueW = 28
    local trackX, trackW = r.x + labelW, r.w - labelW - valueW
    local trackR = { x = trackX, y = r.y + 2, w = trackW, h = r.h - 4 }

    if font ~= nil then
        canvas:AddText(r.x, r.y + r.h * 0.5 - 6, "A", font, Theme.Vec4(Theme.COL_PIN_LABEL))
    end

    Color.DrawChecker(canvas, trackR.x, trackR.y, trackR.w, trackR.h, Theme.COLOR_POPUP_CHECKER_CELL,
        Theme.Vec4(Theme.COL_CHECKER_LIGHT), Theme.Vec4(Theme.COL_CHECKER_DARK))
    local rc, gc, bc = self.value.r / 255, self.value.g / 255, self.value.b / 255
    canvas:AddGradientH(trackR.x, trackR.y, trackR.w, trackR.h,
        Vector4.new(rc, gc, bc, 0), Vector4.new(rc, gc, bc, 1))
    canvas:AddOutline(trackR.x, trackR.y, trackR.w, trackR.h, 1, Theme.Vec4(Theme.COL_PALETTE_BORDER))

    local a = self.value.a or 255
    local kx = trackR.x + (a / 255) * trackR.w
    canvas:AddRectangle(kx - 1.5, trackR.y - 1, 3, trackR.h + 2, Vector4.new(1, 1, 1, 1))
    canvas:AddOutline(kx - 1.5, trackR.y - 1, 3, trackR.h + 2, 1, Vector4.new(0, 0, 0, 1))

    if font ~= nil then
        canvas:AddText(r.x + r.w - valueW + 4, r.y + r.h * 0.5 - 6, tostring(a), font,
            Theme.Vec4(Theme.COL_CONTROL_TEXT))
    end
end

return ColorPopup
