local luaunit = require("luaunit")
local Unavailable = require("nodes/unavailable")

TestUnavailable = {}

-- Overhead Text, Sound Fired, Overhead, Request Focus, and Text to Speech stay
-- permanently Unavailable. Game Message is a gated action, not one of these rows.
function TestUnavailable:testPermanentListIsTheFiveMissingApis()
    local names = {}
    for _, entry in ipairs(Unavailable) do
        names[#names + 1] = entry.category .. ":" .. entry.displayName
    end
    table.sort(names)
    luaunit.assertEquals(names, {
        "action:Overhead",
        "action:Request Focus",
        "action:Text to Speech",
        "trigger:Overhead Text",
        "trigger:Sound Fired",
    })
end

function TestUnavailable:testEveryEntryHasDisplayNameCategoryAndDescription()
    for i, entry in ipairs(Unavailable) do
        luaunit.assertNotNil(entry.displayName, "entry " .. i .. " missing displayName")
        luaunit.assertNotEquals(entry.displayName, "")
        luaunit.assertTrue(entry.category == "trigger" or entry.category == "action",
            "entry " .. i .. " has unexpected category '" .. tostring(entry.category) .. "'")
        luaunit.assertNotNil(entry.description, "entry " .. i .. " missing description")
        luaunit.assertNotEquals(entry.description, "")
    end
end

-- Entries are display-only data, never real Node Type definitions: they must not carry
-- the fields a Registry:RegisterNodeType definition needs (run, pins), which would let
-- something accidentally register or instantiate one.
function TestUnavailable:testEntriesCarryNoRegistrableNodeTypeFields()
    for _, entry in ipairs(Unavailable) do
        luaunit.assertIsNil(entry.run)
        luaunit.assertIsNil(entry.pins)
        luaunit.assertIsNil(entry.key)
    end
end

function TestUnavailable:testNoDuplicateDisplayNameWithinACategory()
    local seen = {}
    for _, entry in ipairs(Unavailable) do
        local k = entry.category .. "\0" .. entry.displayName
        luaunit.assertIsNil(seen[k], "duplicate entry '" .. entry.displayName .. "' in " .. entry.category)
        seen[k] = true
    end
end

return TestUnavailable
