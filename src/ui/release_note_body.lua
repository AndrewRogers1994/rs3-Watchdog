-- Release-note paragraphs are text, or a picture loaded from Plugin.resources.
-- The shipped PrettyUI collapse section has no image row. The picture is parented
-- to that section's content layer, then the section grows the same way its text rows do.

local ReleaseNoteBody = {}

local ITEM_GAP = 4

---@param message string
local function report(message)
    if type(log) == "function" then
        log("Watchdog: " .. message)
    end
end

---@param node any
---@param key string
---@return any
local function index(node, key)
    if node == nil then return nil end
    local ok, value = pcall(function() return node[key] end)
    if not ok then return nil end
    return value
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

---@param value any
---@return boolean
local function isResource(value)
    if value == nil then return false end
    local okLoad, loadFn = pcall(function() return value.Load end)
    if okLoad and type(loadFn) == "function" then return true end
    local okPath, path = pcall(function() return value.path end)
    if okPath and type(path) == "string" then return true end
    local okLoaded, loaded = pcall(function() return value.loaded end)
    if okLoaded and type(loaded) == "boolean" then return true end
    return false
end

---@param images any
---@param parts string[]
---@param leaf string
---@return any
local function walk(images, parts, leaf)
    local node = images
    for i = 1, #parts - 1 do
        node = index(node, parts[i])
        if node == nil then return nil end
    end
    return index(node, leaf)
end

---@param resource any
---@return any|nil
---@return string|nil err
local function ensureLoaded(resource)
    local okLoaded, loaded = pcall(function() return resource.loaded end)
    if okLoaded and loaded == true then return resource end
    local okFn, loadFn = pcall(function() return resource.Load end)
    if not okFn or type(loadFn) ~= "function" then return resource end
    local ok, result = pcall(function() return resource:Load() end)
    if not ok then return nil, tostring(result) end
    local okAfter, after = pcall(function() return resource.loaded end)
    if okAfter and after == true then return resource end
    if tostring(result) == "success" then return resource end
    return nil, tostring(result)
end

--- Path is relative to resources/images. A leading resources/ or images/, and a
--- .png suffix, are accepted. The client keys the file both with and without
--- the extension, so both are tried.
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

--- Fit the source pixels into the section. Never scales up.
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
---@field kind "text"|"title"|"image"
---@field text string|nil
---@field resource any
---@field width number|nil
---@field height number|nil

---@param paragraphs Watchdog.ReleaseNoteParagraph[]|nil
---@param images any
---@param available number|nil
---@return Watchdog.ReleaseNotePlanItem[]
function ReleaseNoteBody.plan(paragraphs, images, available)
    local plan = {}
    for _, paragraph in ipairs(paragraphs or {}) do
        if type(paragraph) == "string" then
            plan[#plan + 1] = { kind = "text", text = paragraph }
        elseif type(paragraph) == "table" and type(paragraph.title) == "string" and paragraph.title ~= "" then
            plan[#plan + 1] = { kind = "title", text = paragraph.title }
        elseif type(paragraph) == "table" and type(paragraph.image) == "string" then
            local resource, err = ReleaseNoteBody.resolve(images, paragraph.image)
            if resource == nil then
                report("release image " .. paragraph.image .. " - " .. (err or "not found"))
            else
                local width, height = ReleaseNoteBody.fit(available, paragraph.width, paragraph.height)
                if width == nil or height == nil then
                    report("release image " .. paragraph.image .. " needs width and height")
                else
                    plan[#plan + 1] = {
                        kind = "image",
                        resource = resource,
                        width = width,
                        height = height,
                    }
                end
            end
        else
            report("release note paragraph was not text, a title, or an image")
        end
    end
    return plan
end

---@param block any
---@return number
local function nextY(block)
    if type(block._NextContentY) == "function" then
        return block:_NextContentY({})
    end
    if type(block.contentHeight) == "number" and block.contentHeight > 0 then
        return block.contentHeight + ITEM_GAP
    end
    return 0
end

-- PrettyUI's AddTitle row is 28px tall and leaves 16px above it. The collapse
-- section has no AddTitle, so the title is drawn with the same font and colour
-- and the section grows by that row.
local TITLE_HEIGHT = 28
local TITLE_MARGIN_TOP = 16

---@param block any
---@param text string
---@return any|nil
function ReleaseNoteBody.mountTitle(block, text)
    if block ~= nil and type(block.AddTitle) == "function" then
        return block:AddTitle(text)
    end
    if block == nil or block.content == nil
        or prettyui == nil or prettyui.Text == nil or type(prettyui.Text.title) ~= "function"
        or type(block._SetContentHeight) ~= "function" then
        report("release title skipped, no title host")
        return nil
    end
    local y = 0
    if type(block._NextContentY) == "function" then
        y = block:_NextContentY({ marginTop = TITLE_MARGIN_TOP })
    elseif type(block.contentHeight) == "number" and block.contentHeight > 0 then
        y = block.contentHeight + TITLE_MARGIN_TOP
    end
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

--- Parent a PrettyUI sprite to the collapse body and extend that section.
---@param block any
---@param resource any
---@param width number
---@param height number
---@return any|nil
function ReleaseNoteBody.mountImage(block, resource, width, height)
    if block == nil or block.content == nil
        or prettyui == nil or prettyui.Sprite == nil or type(prettyui.Sprite.new) ~= "function" then
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
