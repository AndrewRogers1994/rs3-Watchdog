-- Oldest first. A version with no entry never pops.
-- A paragraph is a string, a title { title = "Known issues" },
-- a list { bullets = { "First.", "Second." } }, or a picture:
-- { image = "releases/tutorial", width = 893, height = 554 }
-- image is a path under resources/images, without the .png extension.

---@type Watchdog.ReleaseNote[]
local catalog = {
    {
        version = "1.0.0",
        paragraphs = {
            { title = "Watchdog 1.0.0 is out!" },
            "This is the first release, and my first plugin on RuneScape's new plugin API. I am so excited to bring this to you :D",
            "An alert is a trigger wired to an action. The trigger watches the game. The action is what you see or hear. That is the whole idea, and you can build one now.",
            "Open the manager with F8 (configurable in settings), or with the Toggle button in the Watchdog panel.",
            "I recommend you start with a Preset. That copies a ready-to-go alert, and you can edit it to your liking.",
            "If the editor feels unfamiliar, hit the info button in the top right. That opens the Tutorial, and it is worth a look before you build anything.",
            { image = "releases/tutorial",     width = 893, height = 554 },
            "Double-click empty space, or click +, to add a node. Then drag from one pin to another.",
            "You can create a new alert from scratch, or you can start with a Preset. There is a starter pack with a few ready to go, including low life points, low prayer, and low food.",
            "When you have a graph you like, the star in the title bar saves it as your own Preset that you can use later.",
            "Game Message and Player Chat triggers and the Game Message action stay unavailable until you grant the chat permission.",
            "In a restricted area, Watchdog will not trigger Spawn, Game Message, or Location triggers.",
            { title = "Planned features" },
            {
                bullets = {
                    "Drag to reorder and group alerts.",
                    "Interactive tutorial.",
                    "Area select, copy/paste, delete operations in editor.",
                    "Display current state of nodes.",
                    "Chat piker for chat nodes.",
                    "More nodes!",
                }
            },
            { title = "Known issues" },
            {
                bullets = {
                    "Angle brackets are stripped from text until an API bug is fixed.",
                    "Have to click twice on some controls in editor until I make my own components.",
                    "Lag when loading sound effects.",
                }
            },
        },
    },
}

return catalog
