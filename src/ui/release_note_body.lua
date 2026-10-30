-- Collapse sections have AddText, not a picture or a title row. Those are
-- parented to the section content, then the section grows like a text row.

local ReleaseNoteBody = {}

local ITEM_GAP = 4
local TITLE_HEIGHT = 28
local TITLE_MARGIN_TOP = 16
local BULLET_PREFIX = "• "
local BULLET_INDENT = 16

---@param message string
local function report(message)
    if type(log) == "function" then
        log("Watchdog: " .. message)
    end
end

---@param path string
---@return string[]|nil
local function partsOf(path)
    local parts = {}
    for part in tostring(path):gmatch("[^/]+") do
        if part ~= "" then parts[#parts + 1] = part end
    end
    if parts[1] == "resources" then table.remove(parts, 1) end
    if parts[1] == "images" then table.remove(parts, 1) end
    if #parts == 0 then return nil end
    parts[#parts] = parts[#parts]:gsub("%.png$", "")
    return parts
end

-- A folder table is not a picture. Client resources are userdata, so a table
-- check alone would skip a real file.
---@param value any
---@return boolean
local function isResource(value)
    local kind = type(value)
    if kind ~= "table" and kind ~= "userdata" then return false end
    if type(value.Load) == "function" then return true end
    if type(value.path) == "string" then return true end
    if type(value.loaded) == "boolean" then return true end
    return false
end

---@param images any
---@param parts string[]
---@param leaf string
---@return any
local function walk(images, parts, leaf)
    local node = images
    for i = 1, #parts - 1 do
        if node == nil then return nil end
        node = node[parts[i]]
    end
    if node == nil then return nil end
    return node[leaf]
end

---@param resource any
---@return any|nil
---@return string|nil err
local function ensureLoaded(resource)
    if resource.loaded == true then return resource end
    if type(resource.Load) ~= "function" then return resource end
    local ok, result = pcall(function() return resource:Load() end)
    if not ok then return nil, tostring(result) end
    if resource.loaded == true or tostring(result) == "success" then return resource end
    return nil, tostring(result)
end

-- Path is under resources/images. A leading resources/ or images/, and a .png
-- suffix, are stripped. The client may key the file with or without .png.
---@param images any
---@param path string
---@return any|nil resource
---@return string|nil err
function ReleaseNoteBody.resolve(images, path)
    if images == nil or type(path) ~= "string" or path == "" then
        return nil, "not found"
    end
    local parts = partsOf(path)
    if parts == nil then return nil, "not found" end
    local leaf = parts[#parts]
    local resource = walk(images, parts, leaf)
    if not isResource(resource) then
        resource = walk(images, parts, leaf .. ".png")
    end
    if not isResource(resource) then return nil, "not found" end
    return ensureLoaded(resource)
end

---@param available number|nil
---@param sourceW number|nil
---@param sourceH number|nil
---@return number|nil width
---@return number|nil height
function ReleaseNoteBody.fit(available, sourceW, sourceH)
    if type(available) ~= "number" or available < 1 then return nil end
    if type(sourceW) ~= "number" or type(sourceH) ~= "number" then return nil end
    if sourceW < 1 or sourceH < 1 then return nil end
    local width = math.min(available, sourceW)
    local height = math.max(1, math.floor(width * sourceH / sourceW + 0.5))
    return math.floor(width + 0.5), height
end

---@param block any
---@param fallback number|nil
---@return number|nil
function ReleaseNoteBody.availableWidth(block, fallback)
    local indent = 20
    if block ~= nil and type(block.indent) == "number" then indent = block.indent end
    local rootW = block and block.root and block.root.width
    if type(rootW) == "number" and rootW > indent then
        return rootW - indent
    end
    if type(fallback) == "number" and fallback >= 1 then return fallback end
    return nil
end

---@class Watchdog.ReleaseNotePlanItem
---@field kind "text"|"title"|"bullets"|"image"
---@field text string|nil
---@field items string[]|nil
---@field resource any
---@field width number|nil
---@field height number|nil

-- A list of non-empty strings, with no holes. Anything else is skipped.
---@param value table
---@return string[]|nil
local function bulletLines(value)
    local n = 0
    for key, line in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil end
        if type(line) ~= "string" or line == "" then return nil end
        n = n + 1
    end
    if n == 0 or n ~= #value then return nil end
    return value
end

---@param paragraph table
---@return Watchdog.ReleaseNotePlanItem|nil
local function planBullets(paragraph)
    local items = bulletLines(paragraph.bullets)
    if items == nil then
        report("release note bullets were not a list of text")
        return nil
    end
    return { kind = "bullets", items = items }
end

---@param paragraph table
---@param images any
---@param available number|nil
---@return Watchdog.ReleaseNotePlanItem|nil
local function planImage(paragraph, images, available)
    local resource, err = ReleaseNoteBody.resolve(images, paragraph.image)
    if resource == nil then
        report("release image " .. paragraph.image .. " - " .. (err or "not found"))
        return nil
    end
    local width, height = ReleaseNoteBody.fit(available, paragraph.width, paragraph.height)
    if width == nil or height == nil then
        report("release image " .. paragraph.image .. " needs width and height")
        return nil
    end
    return {
        kind = "image",
        resource = resource,
        width = width,
        height = height,
    }
end

---@param paragraphs Watchdog.ReleaseNoteParagraph[]|nil
---@param images any
---@param available number|nil
---@return Watchdog.ReleaseNotePlanItem[]
function ReleaseNoteBody.plan(paragraphs, images, available)
    local plan = {}
    for _, paragraph in ipairs(paragraphs or {}) do
        local item
        if type(paragraph) == "string" then
            item = { kind = "text", text = paragraph }
        elseif type(paragraph) == "table" and type(paragraph.title) == "string" and paragraph.title ~= "" then
            item = { kind = "title", text = paragraph.title }
        elseif type(paragraph) == "table" and type(paragraph.bullets) == "table" then
            item = planBullets(paragraph)
        elseif type(paragraph) == "table" and type(paragraph.image) == "string" then
            item = planImage(paragraph, images, available)
        else
            report("release note paragraph was not text, a title, bullets, or an image")
        end
        if item ~= nil then plan[#plan + 1] = item end
    end
    return plan
end

---@param block any
---@param marginTop number|nil
---@return number
local function nextY(block, marginTop)
    if type(block._NextContentY) == "function" then
        if marginTop == nil then return block:_NextContentY({}) end
        return block:_NextContentY({ marginTop = marginTop })
    end
    local gap = marginTop or ITEM_GAP
    if type(block.contentHeight) == "number" and block.contentHeight > 0 then
        return block.contentHeight + gap
    end
    return 0
end

-- PrettyUI's title row is 28px and leaves 16px above it. The collapse section
-- has no AddTitle, so the heading uses that font and the section grows by the row.
---@param block any
---@param text string
---@return any|nil
function ReleaseNoteBody.mountTitle(block, text)
    if block ~= nil and type(block.AddTitle) == "function" then
        return block:AddTitle(text)
    end
    if block == nil or block.content == nil or type(block._SetContentHeight) ~= "function" then
        report("release title skipped, no title host")
        return nil
    end
    local y = nextY(block, TITLE_MARGIN_TOP)
    local label = prettyui.Text.title(block.content, {
        text = text,
        x = 0,
        y = y,
        height = TITLE_HEIGHT,
        _onScrollWheel = block._onScrollWheel,
    })
    if type(block.labels) == "table" then
        block.labels[#block.labels + 1] = label
    end
    block:_SetContentHeight(math.max(block.contentHeight or 0, y + TITLE_HEIGHT))
    return label
end

-- One row per line. A newline inside a row draws as a missing glyph.
-- Negative width keeps the default full-width anchor inside the indent.
---@param block any
---@param items string[]
function ReleaseNoteBody.mountBullets(block, items)
    if block == nil or type(block.AddText) ~= "function" then
        report("release bullets skipped, no text row")
        return
    end
    for _, line in ipairs(items) do
        block:AddText({
            text = BULLET_PREFIX .. line,
            x = BULLET_INDENT,
            width = -BULLET_INDENT,
        })
    end
end

---@param block any
---@param resource any
---@param width number
---@param height number
---@return any|nil
function ReleaseNoteBody.mountImage(block, resource, width, height)
    if block == nil or block.content == nil then
        report("release image skipped, no sprite host")
        return nil
    end
    local y = nextY(block)
    local sprite = prettyui.Sprite.new(block.content, resource, {
        x = 0,
        y = y,
        width = width,
        height = height,
        _onScrollWheel = block._onScrollWheel,
    })
    if type(block._SetContentHeight) ~= "function" then
        report("release image skipped, section could not grow")
        if sprite ~= nil and type(sprite.Destroy) == "function" then sprite:Destroy() end
        return nil
    end
    if type(block.children) == "table" then
        block.children[#block.children + 1] = sprite
    end
    block:_SetContentHeight(math.max(block.contentHeight or 0, y + height))
    return sprite
end

return ReleaseNoteBody
