-- Picture paragraphs: resource lookup, fit, and mounting onto a collapse section.

local luaunit = require("luaunit")
local ReleaseNoteBody = require("src/ui/release_note_body")

TestReleaseNoteBody = {}

function TestReleaseNoteBody:testResolvesNestedImage()
    local resource = { loaded = true }
    local images = { releases = { tutorial = resource } }
    local found, err = ReleaseNoteBody.resolve(images, "releases/tutorial")
    luaunit.assertEquals(found, resource)
    luaunit.assertNil(err)
end

function TestReleaseNoteBody:testAcceptsPngSuffixAndImagesPrefix()
    local resource = { loaded = true, path = "tutorial.png" }
    local images = { releases = { tutorial = resource } }
    luaunit.assertEquals(
        ReleaseNoteBody.resolve(images, "images/releases/tutorial.png"),
        resource
    )
    luaunit.assertEquals(
        ReleaseNoteBody.resolve(images, "resources/images/releases/tutorial.png"),
        resource
    )
end

function TestReleaseNoteBody:testTriesFilenameWithExtension()
    local resource = { loaded = true }
    local images = { releases = { ["tutorial.png"] = resource } }
    luaunit.assertEquals(ReleaseNoteBody.resolve(images, "releases/tutorial"), resource)
end

function TestReleaseNoteBody:testLoadsWhenNotYetLoaded()
    local calls = 0
    local resource = {
        loaded = false,
        Load = function(self)
            calls = calls + 1
            self.loaded = true
            return "success"
        end,
    }
    local found = ReleaseNoteBody.resolve({ releases = { tutorial = resource } }, "releases/tutorial")
    luaunit.assertEquals(found, resource)
    luaunit.assertEquals(calls, 1)
    luaunit.assertEquals(ReleaseNoteBody.resolve({ releases = { tutorial = resource } }, "releases/tutorial"), resource)
    luaunit.assertEquals(calls, 1)
end

function TestReleaseNoteBody:testLoadFailureSkipsThePicture()
    local resource = {
        loaded = false,
        Load = function() error("decode") end,
    }
    local found, err = ReleaseNoteBody.resolve({ shot = resource }, "shot")
    luaunit.assertNil(found)
    luaunit.assertStrContains(err, "decode")
end

function TestReleaseNoteBody:testFolderIsNotAResource()
    local found = ReleaseNoteBody.resolve({ releases = { tutorial = { nested = true } } }, "releases/tutorial")
    luaunit.assertNil(found)
end

function TestReleaseNoteBody:testFitScalesDownAndDoesNotScaleUp()
    local width, height = ReleaseNoteBody.fit(576, 893, 554)
    luaunit.assertEquals(width, 576)
    luaunit.assertEquals(height, 357)
    width, height = ReleaseNoteBody.fit(1000, 893, 554)
    luaunit.assertEquals(width, 893)
    luaunit.assertEquals(height, 554)
    luaunit.assertNil(ReleaseNoteBody.fit(100, nil, 10))
end

function TestReleaseNoteBody:testPlanIncludesATitle()
    local plan = ReleaseNoteBody.plan({
        "Before.",
        { title = "Known issues" },
        "After.",
    }, nil, 100)
    luaunit.assertEquals(plan[1].kind, "text")
    luaunit.assertEquals(plan[2].kind, "title")
    luaunit.assertEquals(plan[2].text, "Known issues")
    luaunit.assertEquals(plan[3].text, "After.")
end

function TestReleaseNoteBody:testPlanIncludesBullets()
    local plan = ReleaseNoteBody.plan({
        { bullets = { "One.", "Two." } },
    }, nil, 100)
    luaunit.assertEquals(#plan, 1)
    luaunit.assertEquals(plan[1].kind, "bullets")
    luaunit.assertEquals(plan[1].items, { "One.", "Two." })
end

function TestReleaseNoteBody:testBadBulletsAreLeftOut()
    local logged = {}
    local previous = log
    _G.log = function(message) logged[#logged + 1] = message end
    local plan = ReleaseNoteBody.plan({
        { bullets = {} },
        { bullets = { "Ok.", 3 } },
        "Still here.",
    }, nil, 100)
    _G.log = previous
    luaunit.assertEquals(#plan, 1)
    luaunit.assertEquals(plan[1].text, "Still here.")
    luaunit.assertTrue(#logged >= 2)
end

function TestReleaseNoteBody:testMountBulletsIndentsEachLine()
    local rows = {}
    local block = {
        AddText = function(_, value)
            rows[#rows + 1] = value
        end,
    }
    ReleaseNoteBody.mountBullets(block, { "Alpha.", "Beta." })
    luaunit.assertEquals(rows[1].text, "• Alpha.")
    luaunit.assertEquals(rows[1].x, 16)
    luaunit.assertEquals(rows[1].width, -16)
    luaunit.assertEquals(rows[2].text, "• Beta.")
    luaunit.assertNil(rows[3])
end

function TestReleaseNoteBody:testMountTitleUsesAddTitleWhenTheSectionHasIt()
    local block = {
        called = nil,
        AddTitle = function(self, text)
            self.called = text
            return "row"
        end,
    }
    luaunit.assertEquals(ReleaseNoteBody.mountTitle(block, "Known issues"), "row")
    luaunit.assertEquals(block.called, "Known issues")
end

function TestReleaseNoteBody:testMountTitleGrowsTheSection()
    local created = {}
    local previous = prettyui
    prettyui = {
        Text = {
            title = function(parent, options)
                created[#created + 1] = { parent = parent, options = options }
                return created[#created]
            end,
        },
    }
    local block = {
        content = {},
        contentHeight = 40,
        labels = {},
        _onScrollWheel = function() end,
        _NextContentY = function(_, options)
            return 40 + (options.marginTop or 4)
        end,
        _SetContentHeight = function(self, height)
            self.contentHeight = height
        end,
    }
    local label = ReleaseNoteBody.mountTitle(block, "Known issues")
    prettyui = previous
    luaunit.assertEquals(label, created[1])
    luaunit.assertEquals(created[1].parent, block.content)
    luaunit.assertEquals(created[1].options.text, "Known issues")
    luaunit.assertEquals(created[1].options.y, 56)
    luaunit.assertEquals(created[1].options.height, 28)
    luaunit.assertEquals(block.labels[1], created[1])
    luaunit.assertEquals(block.contentHeight, 84)
end

function TestReleaseNoteBody:testPlanMixesTextAndImage()
    local resource = { loaded = true }
    local plan = ReleaseNoteBody.plan({
        "Hello.",
        { image = "releases/tutorial", width = 893, height = 554 },
    }, { releases = { tutorial = resource } }, 416)
    luaunit.assertEquals(plan[1].kind, "text")
    luaunit.assertEquals(plan[1].text, "Hello.")
    luaunit.assertEquals(plan[2].kind, "image")
    luaunit.assertEquals(plan[2].resource, resource)
    luaunit.assertEquals(plan[2].width, 416)
    luaunit.assertEquals(plan[2].height, 258)
    luaunit.assertNil(plan[3])
end

function TestReleaseNoteBody:testMissingImageIsLeftOut()
    local logged = {}
    local previous = log
    _G.log = function(message) logged[#logged + 1] = message end
    local plan = ReleaseNoteBody.plan({
        "Still here.",
        { image = "releases/missing", width = 10, height = 10 },
        { image = "releases/tutorial" },
    }, { releases = {} }, 100)
    _G.log = previous
    luaunit.assertEquals(#plan, 1)
    luaunit.assertEquals(plan[1].text, "Still here.")
    luaunit.assertTrue(#logged >= 2)
end

function TestReleaseNoteBody:testAvailableWidthUsesTheSection()
    luaunit.assertEquals(ReleaseNoteBody.availableWidth({
        indent = 20,
        root = { width = 436 },
    }, 576), 416)
    luaunit.assertEquals(ReleaseNoteBody.availableWidth({
        indent = 20,
        root = { width = -28 },
    }, 576), 576)
end

function TestReleaseNoteBody:testMountImageGrowsTheSection()
    local created = {}
    local previous = prettyui
    prettyui = {
        Sprite = {
            new = function(parent, sprite, options)
                local widget = {
                    parent = parent,
                    sprite = sprite,
                    options = options,
                }
                function widget:Destroy() self.destroyed = true end
                created[#created + 1] = widget
                return widget
            end,
        },
    }
    local heights = {}
    local scroll = function() end
    local block = {
        content = {},
        contentHeight = 40,
        children = {},
        _onScrollWheel = scroll,
        _NextContentY = function() return 44 end,
        _SetContentHeight = function(_, height) heights[#heights + 1] = height end,
    }
    local resource = { loaded = true }
    local sprite = ReleaseNoteBody.mountImage(block, resource, 200, 120)
    prettyui = previous
    luaunit.assertEquals(sprite, created[1])
    luaunit.assertEquals(created[1].parent, block.content)
    luaunit.assertEquals(created[1].sprite, resource)
    luaunit.assertEquals(created[1].options.x, 0)
    luaunit.assertEquals(created[1].options.y, 44)
    luaunit.assertEquals(created[1].options.width, 200)
    luaunit.assertEquals(created[1].options.height, 120)
    luaunit.assertEquals(created[1].options._onScrollWheel, scroll)
    luaunit.assertEquals(block.children[1], created[1])
    luaunit.assertEquals(heights[1], 164)
end

function TestReleaseNoteBody:testMountImageWithoutASectionDestroysTheSprite()
    local created = {}
    local previous = prettyui
    prettyui = {
        Sprite = {
            new = function()
                local widget = {}
                function widget:Destroy() self.destroyed = true end
                created[#created + 1] = widget
                return widget
            end,
        },
    }
    local block = { content = {}, children = {} }
    local sprite = ReleaseNoteBody.mountImage(block, {}, 10, 10)
    prettyui = previous
    luaunit.assertNil(sprite)
    luaunit.assertTrue(created[1].destroyed)
    luaunit.assertNil(block.children[1])
end

function TestReleaseNoteBody:testShippedNoteIncludesTheTutorialShot()
    local catalog = require("src/release_notes")
    luaunit.assertEquals(catalog[1].version, "1.0.0")
    local image
    for _, paragraph in ipairs(catalog[1].paragraphs) do
        if type(paragraph) == "table" and paragraph.image ~= nil then image = paragraph end
    end
    luaunit.assertEquals(image.image, "releases/tutorial")
    luaunit.assertEquals(image.width, 893)
    luaunit.assertEquals(image.height, 554)
    local tutorialAt
    for i, paragraph in ipairs(catalog[1].paragraphs) do
        if type(paragraph) == "string" and paragraph:find("Tutorial", 1, true) then
            tutorialAt = i
        end
    end
    luaunit.assertEquals(type(catalog[1].paragraphs[tutorialAt + 1]), "table")
    local titleAt
    for i, paragraph in ipairs(catalog[1].paragraphs) do
        if type(paragraph) == "table" and paragraph.title == "Known issues" then
            titleAt = i
        end
    end
    luaunit.assertNotNil(titleAt)
    luaunit.assertTrue(titleAt < #catalog[1].paragraphs)
end
