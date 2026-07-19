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
require("test_poll")
require("test_store")
require("test_chat")
require("test_logic_triggers")
require("test_location")
require("test_skill")
require("test_entity_spawn")
require("test_node")
require("test_placeholder")
require("test_controls")
require("test_unavailable")
require("test_palette")
require("test_effects")
require("test_screen_flash")
require("test_popup")
require("test_color")
require("test_color_popup")
require("test_infobox")
require("test_infobox_node")
require("test_screen_marker_capture")
require("test_screen_marker")
require("test_toast")
require("test_sound")
require("test_custom_sound")
require("test_alert_toggle")
require("test_graph_editor")

os.exit(luaunit.LuaUnit.run())
