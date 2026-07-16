-- palette.lua — the Palette: the popup Node-Type chooser used to create Nodes.
--
-- A Canvas-drawn, immediate-mode popup listing the Registry's Node Types grouped by
-- Category. The Editor opens it two ways: filtered to Node Types that have a Pin
-- compatible with a dragged Wire (drag-to-create), or unfiltered (double-click empty
-- Viewport / the toolbar +). Like everything in the Editor it is inert — drawn each
-- frame by the Editor and hit-tested manually.
--
-- The Palette owns no graph state. On Open it flattens the Registry into an ordered list
-- of rows (Category headers interleaved with item rows); the Editor reads the chosen
-- item back out and performs the AddNode/Connect itself. Kept clamped inside the Viewport
-- so every row lands on the Window-sized Capture Layer (no capture resizing needed).
--
-- Unfiltered opens also interleave the dimmed, inert rows from nodes/unavailable.lua so a
-- Node Type that can't be built on the current API is visible (with why) instead of just
-- silently absent. Filtered/drag-to-create opens never show them — there's nothing there
-- to auto-connect to.

local Theme = require("ui/theme")
local Unavailable = require("nodes/unavailable")

local Palette = {}
Palette.__index = Palette

-- Category display order: Triggers first, then Actions, then everything else
-- alphabetically. Lower rank sorts first; unranked categories share the same high rank
-- and fall back to an alphabetical tie-break.
local CATEGORY_RANK = { trigger = 1, action = 2 }

local function categoryRank(cat)
    return CATEGORY_RANK[cat] or math.huge
end

-- Title-cases a category key for the header label (e.g. "trigger" -> "Trigger").
local function categoryLabel(cat)
    return cat:sub(1, 1):upper() .. cat:sub(2)
end

function Palette.new()
    return setmetatable({
        open = false,
        rows = {},        -- flat draw list; header rows { header=true, category } or item rows
        scroll = 0,       -- rows scrolled off the top
        maxScroll = 0,    -- recomputed each Draw (needs the visible-row count)
        screenX = 0,      -- where the panel was requested (clamped into the Viewport at Draw)
        screenY = 0,
        anchorGX = 0,     -- Graph-space point the new Node's origin is placed at
        anchorGY = 0,
        connect = nil,    -- { nodeId, entry } source Pin for drag-to-create; nil when unfiltered
        rect = nil,       -- last drawn panel rect + metrics, for hit-testing
    }, Palette)
end

-- Builds the row list from the Registry. `filterFn(def)` returns the name of the Pin to
-- auto-connect for a compatible Node Type, or nil to exclude it; pass nil to include every
-- type (unfiltered). `opts` = { screenX, screenY, anchorGX, anchorGY, connect }.
function Palette:Open(registry, filterFn, opts)
    self.rows = {}
    self.scroll = 0
    self.open = true
    self.screenX = opts.screenX
    self.screenY = opts.screenY
    self.anchorGX = opts.anchorGX
    self.anchorGY = opts.anchorGY
    self.connect = opts.connect

    -- Group the (compatible) Node Types by Category.
    local byCat, cats = {}, {}
    local function ensureCat(cat)
        if byCat[cat] == nil then
            byCat[cat] = {}
            cats[#cats + 1] = cat
        end
    end
    for key, def in pairs(registry.nodeTypes) do
        local targetPin = true
        if filterFn ~= nil then targetPin = filterFn(def) end
        if targetPin then
            local cat = def.category or "other"
            ensureCat(cat)
            byCat[cat][#byCat[cat] + 1] = {
                typeKey = key,
                displayName = def.displayName or key,
                category = cat,
                -- Only carried in filtered mode; unfiltered opens leave it nil.
                targetPin = (filterFn ~= nil) and targetPin or nil,
            }
        end
    end

    -- Unavailable rows (nodes/unavailable.lua) are display-only and only make sense on an
    -- unfiltered open: a filtered/typed open exists to find a Pin-compatible Node Type,
    -- which nothing here has.
    if filterFn == nil then
        for _, entry in ipairs(Unavailable) do
            local cat = entry.category or "other"
            ensureCat(cat)
            byCat[cat][#byCat[cat] + 1] = {
                displayName = entry.displayName,
                category = cat,
                reason = entry.reason,
                unavailable = true,
            }
        end
    end

    table.sort(cats, function(a, b)
        local ra, rb = categoryRank(a), categoryRank(b)
        if ra ~= rb then return ra < rb end
        return a < b
    end)
    for _, cat in ipairs(cats) do
        local items = byCat[cat]
        table.sort(items, function(a, b) return a.displayName < b.displayName end)
        self.rows[#self.rows + 1] = { header = true, category = cat, label = categoryLabel(cat) }
        for _, item in ipairs(items) do
            self.rows[#self.rows + 1] = item
        end
    end
end

function Palette:Close()
    self.open = false
    self.rows = {}
    self.rect = nil
    self.connect = nil
end

-- Scrolls the list. `delta` follows the wheel convention (delta > 0 = wheel up).
function Palette:Scroll(delta)
    if not self.open then return end
    local dir = delta > 0 and 1 or -1     -- wheel up scrolls toward the top
    self.scroll = self.scroll + dir * 3
    if self.scroll < 0 then self.scroll = 0 end
    if self.scroll > self.maxScroll then self.scroll = self.maxScroll end
end

-- Draws the panel, clamped fully inside the Viewport rect. Rows are a uniform height so
-- headers and items share the same scroll math. Records `self.rect` for hit-testing.
function Palette:Draw(canvas, vx, vy, vw, vh, mx, my)
    if not self.open then return end
    local rowH = Theme.PALETTE_ROW_H
    local pad = Theme.PALETTE_PAD
    local total = #self.rows
    if total == 0 then return end

    local panelW = math.min(Theme.PALETTE_W, vw)
    local maxPanelH = math.min(total * rowH + pad * 2, math.floor(vh * 0.92))
    local visibleRows = math.floor((maxPanelH - pad * 2) / rowH)
    if visibleRows < 1 then visibleRows = 1 end
    if visibleRows > total then visibleRows = total end
    local panelH = visibleRows * rowH + pad * 2

    -- Clamp the panel inside the Viewport so every row is over the Capture Layer.
    local px, py = self.screenX, self.screenY
    if px + panelW > vx + vw then px = vx + vw - panelW end
    if py + panelH > vy + vh then py = vy + vh - panelH end
    if px < vx then px = vx end
    if py < vy then py = vy end

    self.maxScroll = math.max(0, total - visibleRows)
    if self.scroll > self.maxScroll then self.scroll = self.maxScroll end
    if self.scroll < 0 then self.scroll = 0 end

    canvas:AddRectangle(px, py, panelW, panelH, Theme.Vec4(Theme.COL_PALETTE_BG))
    canvas:AddOutline(px, py, panelW, panelH, Theme.BORDER_THICKNESS,
        Theme.Vec4(Theme.COL_PALETTE_BORDER))

    local font = Theme.Font(12)
    for i = 1, visibleRows do
        local row = self.rows[self.scroll + i]
        if row ~= nil then
            local ry = py + pad + (i - 1) * rowH
            if row.header then
                canvas:AddRectangle(px + 1, ry, panelW - 2, rowH,
                    Theme.Vec4(Theme.COL_PALETTE_HEADER_BG))
                if font ~= nil then
                    canvas:AddText(px + 6, ry + 3, row.label or row.category, font,
                        Theme.Vec4(Theme.COL_PALETTE_HEADER_TX))
                end
            else
                -- Unavailable rows are inert (RowAt excludes them): no hover highlight, no
                -- click affordance to suggest otherwise.
                local hovered = not row.unavailable
                    and mx >= px and mx <= px + panelW and my >= ry and my < ry + rowH
                if hovered then
                    canvas:AddRectangle(px + 1, ry, panelW - 2, rowH,
                        Theme.Vec4(Theme.COL_PALETTE_HOVER))
                end
                if font ~= nil then
                    local label = row.displayName
                    local color = Theme.COL_PALETTE_TEXT
                    if row.unavailable then
                        label = label .. " — " .. row.reason
                        color = Theme.COL_PALETTE_TEXT_DIM
                    end
                    canvas:AddText(px + 14, ry + 3, label, font, Theme.Vec4(color))
                end
            end
        end
    end

    self.rect = { x = px, y = py, w = panelW, h = panelH,
                  pad = pad, rowH = rowH, visibleRows = visibleRows }
end

-- The item row under a screen point, or nil (header rows, unavailable rows, and empty
-- padding all return nil — an unavailable row has nothing to create).
function Palette:RowAt(sx, sy)
    local r = self.rect
    if not self.open or r == nil then return nil end
    if sx < r.x or sx > r.x + r.w or sy < r.y or sy > r.y + r.h then return nil end
    local i = math.floor((sy - (r.y + r.pad)) / r.rowH) + 1
    if i < 1 or i > r.visibleRows then return nil end
    local row = self.rows[self.scroll + i]
    if row ~= nil and not row.header and not row.unavailable then return row end
    return nil
end

-- Whether a screen point falls within the drawn panel (a click inside keeps it open).
function Palette:Contains(sx, sy)
    local r = self.rect
    if not self.open or r == nil then return false end
    return sx >= r.x and sx <= r.x + r.w and sy >= r.y and sy <= r.y + r.h
end

return Palette
