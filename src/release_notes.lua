-- Oldest first. A version with no entry never pops.
-- A paragraph is a string, a title { title = "Known issues" }, or a picture:
-- { image = "releases/tutorial", width = 893, height = 554 }
-- image is a path under resources/images, without the .png extension.

---@type Watchdog.ReleaseNote[]
local catalog = {
    {
        version = "1.0.0",
        paragraphs = {
            "Watchdog 1.0.0 is out! This is the first release, and my first plugin on RuneScape's new plugin API. I am so excited to bring this to you :D",
            "An alert is a trigger wired to an action. The trigger watches the game. The action is what you see or hear. That is the whole idea, and you can build one now.",
            "Open the manager with F8 (configurable in settings), or with the Toggle button in the Watchdog panel.",
            "I recommend you start with a Preset. That copies a ready-to-go alert, and you can edit it to your liking.",
            "If the editor feels unfamiliar, hit the info button in the top right. That opens the Tutorial, and it is worth a look before you build anything.",
            { image = "releases/tutorial", width = 893, height = 554 },
            "Double-click empty space, or click +, to add a node. Then drag from one pin to another. A new alert starts enabled, so you can try it immediately.",
            "New alert can be blank, or it can copy a preset. There is a starter pack with a few ready to go, including low life points, low prayer, and low food. When you have a graph you like, the star in the title bar saves it as your own.",
            "Triggers can watch a game message, player chat, a spawn near you, your inventory, a skill, where you are standing, or a resource like life points.",
            "From there you can show a toast, a popup, or an infobox, play a sound, flash the screen, or mark a spot on the screen or in the world.",
            "Sound Effect plays a builtin sound. Other plugins can add their sounds to that list. Custom Sound plays an audio file that came with Watchdog or with a pack.",
            "In a restricted area, Watchdog will not alert you about nearby spawns, game messages, or walking into or out of a spot you chose. Your other alerts still run.",
            { title = "Known issues" },
            "Text to Speech is in the node list, with a note that it needs API support. It will not run. A plugin still cannot speak a line.",
            "Game Message, Player Chat, and the Game Message action stay unavailable until you grant chat permission. That switch is on the settings page.",
            "Shortest Path stays unavailable until the Shortest Path plugin is enabled.",
        },
    },
}

return catalog
