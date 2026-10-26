-- compress.lua - paste token for a string that has to fit in a text field.
--
-- The bytes are raw deflate (see deflate.lua). A text field cannot hold those
-- bytes, so the token is "WD1" plus unpadded URL-safe base64 (A-Z, a-z, 0-9,
-- "-", "_"). "WD1" is the codec version, the same job "TM2" does for tile
-- presets: the importer can tell this token from plain export JSON, which
-- starts with "{". No padding "=", because the field is a size-capped paste
-- and the decoder recovers the length from the character count.
--
-- Export calls this when the JSON envelope is over the paste-field cap. Import
-- calls decompress for a token and still accepts raw JSON, which starts with "{".

local Deflate = require("src/deflate")

local Compress = {}

-- Bump the prefix, not the deflate block, if the token layout changes.
Compress.PREFIX = "WD1"

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local VALUES = {}
for i = 1, #ALPHABET do
    VALUES[ALPHABET:sub(i, i)] = i - 1
end

local function base64url(data)
    local out = {}
    local i = 1
    local n = #data
    while i <= n do
        local b1, b2, b3 = data:byte(i, i + 2)
        local combined = b1 << 16
        if b2 ~= nil then
            combined = combined | (b2 << 8)
        end
        if b3 ~= nil then
            combined = combined | b3
        end
        out[#out + 1] = ALPHABET:sub(((combined >> 18) & 63) + 1, ((combined >> 18) & 63) + 1)
        out[#out + 1] = ALPHABET:sub(((combined >> 12) & 63) + 1, ((combined >> 12) & 63) + 1)
        if b2 ~= nil then
            out[#out + 1] = ALPHABET:sub(((combined >> 6) & 63) + 1, ((combined >> 6) & 63) + 1)
        end
        if b3 ~= nil then
            out[#out + 1] = ALPHABET:sub((combined & 63) + 1, (combined & 63) + 1)
        end
        i = i + 3
    end
    return table.concat(out)
end

local function base64url_decode(text)
    if text == "" or #text % 4 == 1 then
        error("Invalid compressed token.")
    end
    local out = {}
    local i = 1
    while i <= #text do
        local available = math.min(4, #text - i + 1)
        local combined = 0
        for offset = 0, available - 1 do
            local value = VALUES[text:sub(i + offset, i + offset)]
            if value == nil then
                error("Compressed token contains unsupported characters.")
            end
            combined = combined | (value << (18 - offset * 6))
        end
        out[#out + 1] = string.char((combined >> 16) & 255)
        if available >= 3 then
            out[#out + 1] = string.char((combined >> 8) & 255)
        end
        if available == 4 then
            out[#out + 1] = string.char(combined & 255)
        end
        i = i + 4
    end
    return table.concat(out)
end

---Deflate `data` and return a paste token.
---@param data string
---@return string
function Compress.compress(data)
    if type(data) ~= "string" then
        error("Compress.compress expects a string.")
    end
    return Compress.PREFIX .. base64url(Deflate.compress(data))
end

---Undo a token from compress(). Whitespace anywhere is ignored. A text field
---wraps a long paste and the copy picks up line breaks between the characters.
---@param token string
---@return string
function Compress.decompress(token)
    if type(token) ~= "string" then
        error("Compress.decompress expects a string.")
    end
    local text = token:gsub("%s", "")
    local prefix = Compress.PREFIX
    if text:sub(1, #prefix) ~= prefix then
        error("Expected a " .. prefix .. " compressed token.")
    end
    local payload = text:sub(#prefix + 1)
    if payload == "" then
        error("Invalid compressed token.")
    end
    return Deflate.decompress(base64url_decode(payload))
end

return Compress
