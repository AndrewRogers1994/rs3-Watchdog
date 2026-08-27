-- Inventory Viewer overlay: a PrettyUI ItemGrid parked on overlayParent above the Capture
-- Layer (ADR-0010). Window math is pure; native ItemGrid is created only in-client.

local Theme = require("ui/theme")

local InvViewer = {}

InvViewer.TYPE_KEY = "inventory.viewer"
InvViewer.COLUMNS = 4
InvViewer.VISIBLE_ROWS = 7
-- Match PrettyUI ItemGrid / ItemSlot (src/item_grid.lua).
InvViewer.SLOT_SIZE = 40
InvViewer.SLOT_GAP = 2

function InvViewer.VisibleCapacity()
    return InvViewer.COLUMNS * InvViewer.VISIBLE_ROWS
end

function InvViewer.ScreenSize()
    local cols, rows = InvViewer.COLUMNS, InvViewer.VISIBLE_ROWS
    local s, gap = InvViewer.SLOT_SIZE, InvViewer.SLOT_GAP
    return cols * s + (cols - 1) * gap, rows * s + (rows - 1) * gap
end

function InvViewer.GraphExtra(zoom)
    local sw, sh = InvViewer.ScreenSize()
    if type(zoom) ~= "number" or zoom <= 0 then
        zoom = 1
    end
    return sw / zoom, sh / zoom
end

function InvViewer.ClampRowOffset(rowOffset, slotCount)
    local cap = slotCount or 0
    if cap < 0 then
        cap = 0
    end
    local totalRows = math.ceil(cap / InvViewer.COLUMNS)
    local maxOff = math.max(0, totalRows - InvViewer.VISIBLE_ROWS)
    local o = math.floor(rowOffset or 0)
    if o < 0 then
        o = 0
    end
    if o > maxOff then
        o = maxOff
    end
    return o
end

---@param snap Watchdog.InvSnapshot|nil
---@param rowOffset integer|nil
---@return table[]
function InvViewer.GridObjects(snap, rowOffset)
    local objects = {}
    local slots = (snap and snap.slots) or {}
    local start = InvViewer.ClampRowOffset(rowOffset, snap and snap.slotCount) * InvViewer.COLUMNS
    local n = InvViewer.VisibleCapacity()
    for i = 1, n do
        local s = slots[start + i]
        if s ~= nil and type(s.objId) == "number" then
            objects[i] = {
                object = { id = s.objId, name = s.name },
                tooltip = s.name,
                quantity = s.count,
            }
        else
            objects[i] = { object = nil, tooltip = nil, quantity = nil }
        end
    end
    return objects
end

local function destroyGrid(grid)
    if grid == nil then
        return
    end
    pcall(function()
        if grid.Destroy ~= nil then
            grid:Destroy()
        end
    end)
end

function InvViewer.DestroyAll(editor)
    if editor == nil or editor.inventoryGrids == nil then
        return
    end
    for id, grid in pairs(editor.inventoryGrids) do
        destroyGrid(grid)
        editor.inventoryGrids[id] = nil
    end
    editor.viewerScroll = {}
    editor.viewerBound = {}
end

local function ensureGrid(editor, nodeId)
    local grids = editor.inventoryGrids
    if grids == nil then
        grids = {}
        editor.inventoryGrids = grids
    end
    local existing = grids[nodeId]
    if existing ~= nil then
        return existing
    end
    local parent = editor.overlayParent or editor.contentParent
    local ItemGrid = prettyui and prettyui.ItemGrid
    if parent == nil or ItemGrid == nil or ItemGrid.new == nil then
        return nil
    end
    local grid
    local ok, err = pcall(function()
        grid = ItemGrid.new(parent, {}, {
            columns = InvViewer.COLUMNS,
            rows = InvViewer.VISIBLE_ROWS,
            tooltip = true,
            dragDrop = false,
            _onScrollWheel = function(_, delta)
                local d = tonumber(delta) or 0
                local dir = 0
                if d > 0 then
                    dir = 1
                elseif d < 0 then
                    dir = -1
                end
                if dir == 0 then
                    return false
                end
                local snap = editor.graph and editor.graph:GetState(nodeId)
                snap = snap and snap.snapshot
                local cap = snap and snap.slotCount or 0
                editor.viewerScroll = editor.viewerScroll or {}
                local nextOff = InvViewer.ClampRowOffset((editor.viewerScroll[nodeId] or 0) + dir, cap)
                editor.viewerScroll[nodeId] = nextOff
                if grid ~= nil and grid.SetObjects ~= nil then
                    grid:SetObjects(InvViewer.GridObjects(snap, nextOff))
                    editor.viewerBound = editor.viewerBound or {}
                    editor.viewerBound[nodeId] = { snap = snap, off = nextOff }
                end
                return false
            end,
        })
    end)
    if not ok or grid == nil then
        if log ~= nil then
            log("Watchdog: Inventory Viewer grid failed: " .. tostring(err))
        end
        return nil
    end
    grids[nodeId] = grid
    return grid
end

-- Reposition/rebind every Inventory Viewer ItemGrid. Call after buildGeoms, while the
-- Editor is visible. Grids sit above capture (frontOverlayInteractives).
function InvViewer.Sync(editor)
    if editor == nil then
        return
    end
    editor.inventoryGrids = editor.inventoryGrids or {}
    editor.viewerScroll = editor.viewerScroll or {}
    if not editor.visible or editor.graph == nil then
        for _, grid in pairs(editor.inventoryGrids) do
            pcall(function()
                if grid.root ~= nil then
                    grid.root.hidden = true
                end
            end)
        end
        return
    end

    local present = {}
    for _, n in ipairs(editor.graph:GetNodes()) do
        if n.typeKey == InvViewer.TYPE_KEY then
            present[n.id] = true
            local geom = editor.geoms[n.id]
            local grid = ensureGrid(editor, n.id)
            if grid ~= nil then
                local show = geom ~= nil and geom.viewerGrid ~= nil
                pcall(function()
                    if grid.root ~= nil then
                        grid.root.hidden = not show
                    end
                end)
                if show then
                    local vg = geom.viewerGrid
                    -- view:ToScreen is content-local (Canvas). Overlay SetPos is absolute
                    -- screen — same as toolbar / Control Editors (`Editor:toScreen`).
                    local lx, ly = editor.view:ToScreen(geom.x + vg.x, geom.y + vg.y)
                    local sx, sy = editor:toScreen(lx, ly)
                    local sw, sh = InvViewer.ScreenSize()
                    pcall(function()
                        grid.root:SetPos(sx, sy)
                        grid.root:SetSize(sw, sh)
                    end)
                    local state = editor.graph:GetState(n.id)
                    local snap = state and state.snapshot
                    local cap = snap and snap.slotCount or 0
                    local off = InvViewer.ClampRowOffset(editor.viewerScroll[n.id], cap)
                    editor.viewerScroll[n.id] = off
                    -- ItemSlot rebuilds its PrettyUI tooltip on every SetObject; doing that
                    -- each Draw frame unsubscribes ONMOUSEOVER so hover never sticks.
                    editor.viewerBound = editor.viewerBound or {}
                    local bound = editor.viewerBound[n.id]
                    if bound == nil or bound.snap ~= snap or bound.off ~= off then
                        pcall(function()
                            grid:SetObjects(InvViewer.GridObjects(snap, off))
                        end)
                    end
                    editor.viewerBound[n.id] = { snap = snap, off = off }
                end
            end
        end
    end
    for id, grid in pairs(editor.inventoryGrids) do
        if not present[id] then
            destroyGrid(grid)
            editor.inventoryGrids[id] = nil
            editor.viewerScroll[id] = nil
            if editor.viewerBound ~= nil then
                editor.viewerBound[id] = nil
            end
        end
    end
end

function InvViewer.Front(editor)
    if editor == nil or editor.inventoryGrids == nil then
        return
    end
    for _, grid in pairs(editor.inventoryGrids) do
        pcall(function()
            if grid.root ~= nil then
                grid.root:MoveToFront()
            end
        end)
    end
end

-- ItemGrid tooltips are overlay siblings, not children of the grid. Front() would bury them.
function InvViewer.FrontTooltips(editor)
    if editor == nil or editor.inventoryGrids == nil then
        return
    end
    local Tooltip = prettyui and prettyui.Tooltip
    if Tooltip == nil or Tooltip.moveContextTooltipsToFront == nil then
        return
    end
    for _, grid in pairs(editor.inventoryGrids) do
        pcall(function()
            if grid.root ~= nil then
                Tooltip.moveContextTooltipsToFront(grid.root)
            end
        end)
    end
end

function InvViewer.ExtraBodyOpts(zoom)
    local gw, gh = InvViewer.GraphExtra(zoom)
    return {
        extraBodyW = gw + Theme.PIN_MARGIN_X * 2,
        extraBodyH = gh,
    }
end

return InvViewer
