# Popup theme sprites — collection-log + achievement frames + curated icon set

Research for GitHub issue **rs3-Watchdog #20** (blocks #14 — Popup effect + action node
design). Goal: RS3 client sprite ids usable via
`ui.Canvas:AddSprite(x, y, w, h, spriteID, rgba)` for sprite-based Popup themes and a
curated notification-icon dropdown.

**Sources**

- **API docs (gospel):** <https://d1s24e1pcksyf8.cloudfront.net/index.html> →
  `ui/decorative_components/canvas.html` (Canvas method reference).
- **Generated constants (cross-check, may lag docs):**
  `D:\dev\rs3\runescape-api-stubs\consts\Sprite.lua` (`id.Sprite` enum, ~71k lines,
  scraped from the docs' sprite dump). Line numbers below are from that file.

**Confidence legend:** High = named for exactly this purpose in the constant table;
Medium = a plausible generic frame/banner but not named for this specific popup;
Low = best guess, must be eyeballed in-client.

---

## 0. AddSprite semantics (tint + scaling) — READ FIRST

From `canvas.html`, `AddSprite` has **three overloads** (verbatim parameter lists):

1. `AddSprite(x: Int, y: Int, width: Int, height: Int, spriteID: Int, colourRGBA: Uint)`
2. `AddSprite(x, y, width, height, spriteID, uvs: Rect, colourRGBA: Uint)`
3. `AddSprite(x, y, width, height, spriteID, uvs: Rect, spriteConfig: ui.SpriteDataConfig)`

- `uvs` — *"Rectangle identifying the UV coordinates to use when drawing this sprite"*
  (i.e. sub-rect sampling from a spritesheet).
- `spriteConfig` — `ui.SpriteDataConfig` (defined under `common_types.html`).

**Does `colourRGBA` tint the sprite?** **UNCONFIRMED by the docs.** The Canvas page lists
`colourRGBA` as a parameter but does **not** state whether it multiplies/tints the sprite
pixels or only sets an untextured fill colour. There is **no `AddSprite` usage anywhere in
the Watchdog or DevTools plugin source** to cross-check empirically (grep found none). By
convention in this API the colour arg on draw calls is a straight RGBA multiply, so a
white sprite would tint and a full-colour sprite would darken — **but this must be
verified in-client** before relying on tinting for theming.

**Does it scale cleanly to arbitrary width?** **UNCONFIRMED by the docs.** The signature
takes explicit `width`/`height`, and the page says nothing about tiling, wrapping, or
9-slice. So `AddSprite` almost certainly **stretches** a single sprite to the given box
(no edge-preserving 9-slice built in). Consequence: single-sprite frames will distort at
extreme aspect ratios; edge-preserving frames must be assembled from multiple sprites
(corners fixed size, edges stretched along one axis) by the plugin itself.

There is **no documented sprite-browser tool and no `id.Sprite` reference page** in the
docs; `id.Sprite` exists only as the scraped enum in `consts/Sprite.lua`.

> Net: treat every frame below as "stretch a single sprite" or "hand-assemble a
> multi-part frame", and plan a quick in-client spike to confirm (a) tint and (b) how the
> multi-part frames tile, before committing #14's theming to any of them.

---

## 1. Collection Log completion popup — frame / backdrop

**Finding: no sprite is named for a "collection log completion popup frame."** The
constant table has collection-log *icons* but no dedicated completion-frame/backdrop
sprite. Confidence that the exact asset exists under an obvious name: **Low.** Best path
is a generic popup frame (below) themed with a collection-log icon, OR an in-client hunt
(see "How to confirm").

Collection-log-themed decoration (icons, not frames):

| Sprite | id | Source | Notes |
|---|---|---|---|
| `RS3_ICON_BOSS_COLLECTION_LOG_0` | **15064** | Sprite.lua:15069 | Collection-log book icon (state 0). High confidence it *is* a collection-log icon; it is an icon, not a frame. |
| `RS3_ICON_BOSS_COLLECTION_LOG_1` | **15065** | Sprite.lua:15070 | Same, state 1 (hover/active variant). |

Generic frame/backdrop candidates to pair it with (see §4 for the shared frame list):
`FRAME_PANEL_9_SLICE_MAINMENU_*`, `LOBBY_POPUP_FRAME_0/1/2`, `GENERICPOPUP_TITLE`.

Title / bell / decoration sprites that could ride with a popup:

| Sprite | id | Source | Notes |
|---|---|---|---|
| `GENERICPOPUP_TITLE` | **13465** | Sprite.lua:13470 | Generic popup title bar/plate. Medium. |
| `GENERICPOPUP_TITLE_60PX` | **13466** | Sprite.lua:13471 | 60px-tall variant of the above. Medium. |

No "bell" notification sprite exists for this purpose — the only `BELL` matches are
unrelated (ritual bell, POP-clan azure bell, invention bell jar). Confidence: **High**
that there is no notification-bell sprite in the table.

---

## 2. League-task / achievement completion banner — frame

Two distinct, better-named candidates than for the collection log:

### 2a. `PANEL_TASK_COMPLETE` — task-complete panel (best "achievement/task complete" match)

| Sprite | id | Source | Notes |
|---|---|---|---|
| `PANEL_TASK_COMPLETE` | **11424** | Sprite.lua:11429 | Named exactly "task complete" panel. **Medium-High.** |

Sibling sprites in the same UI set (same interface — likely the Premier/task-token
system, given neighbours `ICON_TASK_TOKEN`, `ICON_PREMIER_PASS`), useful for assembling
the full banner:

| Sprite | id | Source | Role |
|---|---|---|---|
| `PANEL_MAIN` | 11423 | Sprite.lua:11423 | Main panel body/backdrop |
| `PANEL_TEXT_CONTAINER` | 11425 | Sprite.lua:11425 | Text area plate |
| `PANEL_TASK_INFO` | 11441 | Sprite.lua:11446 | Task-info sub-panel |
| `ICON_TASK_TOKEN` | 11422 | Sprite.lua:11422 | Task token icon (decoration) |

Whether `PANEL_TASK_COMPLETE` is a single stretchable plate or needs the siblings for a
clean banner is **unconfirmed — verify in-client.**

### 2b. `RS3_RIBBON_LEAGUES_*` — 3-part Leagues ribbon banner (best "league" match)

A genuine multi-part (3-piece, almost certainly left/middle/right) ribbon banner, named
for Leagues. **Medium-High** that this is the leagues ribbon; the 3-part split strongly
implies a stretchable center piece.

| Sprite | id | Source | Notes |
|---|---|---|---|
| `RS3_RIBBON_LEAGUES_GOLD_0` | **35186** | Sprite.lua:35128 | Gold ribbon, piece 0 (left) |
| `RS3_RIBBON_LEAGUES_GOLD_1` | **35187** | Sprite.lua:35129 | Gold ribbon, piece 1 (middle — stretch this) |
| `RS3_RIBBON_LEAGUES_GOLD_2` | **35188** | Sprite.lua:35130 | Gold ribbon, piece 2 (right) |
| `RS3_RIBBON_LEAGUES_RED_0..2` | **35189–35191** | Sprite.lua:35131–35133 | Red variant |
| `RS3_RIBBON_LEAGUES_RED_GOLD_0..2` | **35192–35194** | Sprite.lua:35134–35136 | Red+gold variant |

Native dimensions are **not** in the docs/table (the scrape carries id + name only, not
w/h) — measure in-client.

---

## 3. Curated notification-icon set (for #14's dropdown)

All ids below come from `consts/Sprite.lua` and are **High** confidence as *icons* (named
for the thing). Exact pixel size is unconfirmed except where the name encodes it (e.g.
`_24PX`). `AddSprite` lets you request any `w`/`h`, so nominal size only matters for
crispness.

| Label (dropdown) | Sprite constant | id | Source |
|---|---|---|---|
| Tick / checkmark (24px) | `RS3_ICON_CHECK_MARK_24PX_0` | **17127** | Sprite.lua:17132 |
| Tick / checkmark (18px) | `RS3_ICON_CHECK_MARK_18PX_0` | **15172** | Sprite.lua:15177 |
| Green checkmark | `RS3_CONTEXTUAL_INPUT_GREEN_CHECK_MARK` | **21747** | Sprite.lua:21740 |
| Star (filled) | `ICON_STAR_FILL` | **12764** | Sprite.lua:12769 |
| Star (empty) | `ICON_STAR_EMPTY` | **12765** | Sprite.lua:12770 |
| Coins (classic) | `COINS` | **431** | Sprite.lua:436 |
| Coins (modern AIF) | `AIF_COINS_ICON` | **23968** | Sprite.lua:23910 |
| Exclamation / alert | `EXCLAMATION_MARK` | **937** | Sprite.lua:942 |
| Quest (ribbon) | `ICON_RIBBON_QUESTS_INACTIVE` | **6953** | Sprite.lua:6958 |
| Collection log | `RS3_ICON_BOSS_COLLECTION_LOG_0` | **15064** | Sprite.lua:15069 |
| Skill: Attack (classic stat icon) | `STATICONS_0` | **197** | Sprite.lua:202 |
| Skill: Hitpoints (modern 24px) | `RS3_ICON_SKILL_HITPOINTS_24PX` | **24773** | Sprite.lua:24715 |
| Skill: Prayer (modern 24px) | `RS3_ICON_SKILL_PRAYER_24PX` | **24776** | Sprite.lua:24718 |

Notes:
- `STATICONS_0..17` (ids **197–214**) are the classic in-order skill icons
  (0 = Attack, 1 = Defence, … as laid out in the Stats interface). Pick individual
  members for specific skills; verify the exact index→skill mapping in-client since the
  table gives no per-index label.
- The `RS3_ICON_SKILL_*_24PX` family is the modern clean skill-icon set; only a subset
  (Hitpoints 24773, Prayer 24776) was spot-checked — grep `RS3_ICON_SKILL_` for the full
  list if more skills are needed.
- `SKILL_ICON_ARCHAEOLOGY_25PX_0` (**10782**) etc. exist as another per-skill family.

---

## 4. Shared generic frame options (for §1 and any un-themed popup)

Because no purpose-named collection-log frame exists, these are the reusable frame
backdrops. Multi-part sets are the way to get a clean edge-preserving frame given
`AddSprite` has no built-in 9-slice.

| Frame | ids | Source | Kind | Confidence |
|---|---|---|---|---|
| `FRAME_PANEL_9_SLICE_MAINMENU_0..8` | **3022, 3042, 3043, 3044, 3045, 3048, 3049, 3050, 3051** | Sprite.lua:3027–3056 | **True 9-slice** (9 pieces: 4 corners + 4 edges + center). Underlying ids are non-contiguous — use the named constants, not `first+n`. | **High** it is a 9-slice frame; Medium that its look suits a completion popup |
| `LOBBY_POPUP_FRAME_0/1/2` | **2697, 2698, 2699** | Sprite.lua:2702–2704 | 3-part popup frame (lobby/login styling) | Medium |
| `PANEL_BACKGROUND_TOP_LEFT_CORNER` / `_TOP_RIGHT_CORNER` | **12770 / 12771** | Sprite.lua:12775–12776 | Corner pieces of a panel background (only top corners named nearby) | Low |
| `GENERICPOPUP_TITLE` / `_60PX` | **13465 / 13466** | Sprite.lua:13470–13471 | Popup title plate | Medium |

---

## How to confirm in-client (build-session spike)

1. **Tint & scale test:** on an overlay `ui.Canvas`, draw one icon (e.g. `COINS` = 431)
   twice — once with `rgba = 0xFFFFFFFF`, once with `0xFF0000FF` — at two different
   `w`/`h` boxes. Observe (a) whether the red-tinted copy is actually tinted, and (b)
   whether the stretched copy looks clean. Repeat with a frame sprite to see if it
   stretches or wants 9-slice.
2. **Frame reality-check:** draw `FRAME_PANEL_9_SLICE_MAINMENU_0..8`, `LOBBY_POPUP_FRAME_*`,
   `PANEL_TASK_COMPLETE`, and `RS3_RIBBON_LEAGUES_GOLD_*` at a known box and screenshot to
   pick the best-looking completion/banner frame and read off native piece sizes.
3. **Collection-log frame hunt:** if none of the generic frames read as "collection log",
   scan ids near the collection-log icon (`RS3_ICON_BOSS_COLLECTION_LOG_*` = 15064–15065)
   by drawing a range and eyeballing, since related UI assets are often grouped.
4. **Skill-icon mapping:** draw `STATICONS_0..17` in a row to confirm which index is which
   skill before wiring the dropdown.

## Caveats

- `consts/Sprite.lua` is scraped from the docs and can lag/duplicate (the file repeats its
  body ~halfway through; both copies agree on the ids cited here). Docs site wins on any
  conflict, but the docs expose these only as the same dump — there is no richer per-sprite
  metadata (no width/height, no preview) available without going in-client.
- No id here was fabricated; every id was read from `consts/Sprite.lua` at the cited line.
