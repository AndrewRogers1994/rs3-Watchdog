-- Test entry point. Run from anywhere with a standalone Lua interpreter:
--   lua Watchdog/tests/run.lua
-- Exit code is 0 on success, non-zero on any test failure (suitable for CI).

local function scriptDir()
    local info = debug.getinfo(1, "S")
    local path = info.source:match("^@(.*)$") or ""
    return path:match("(.*[/\\])") or "./"
end

local testsDir = scriptDir()
local rootDir = testsDir .. "../"

-- runtime.lua and the node files are exercised against a real Graph/Registry, so
-- LibNodeGraph (a sibling deployed folder, see CLAUDE.md) must be on the path too.
package.path = rootDir .. "?.lua;" .. testsDir .. "?.lua;" .. rootDir .. "../LibNodeGraph/?.lua;" .. package.path

local luaunit = require("luaunit")

require("test_runtime")
require("test_chat")
require("test_node")
require("test_controls")
require("test_effects")

os.exit(luaunit.LuaUnit.run())
