# One-shot notices

What's new shows every unseen release note in one dialog. Getting started shows once, the first time the editor is entered. Both use the existing Dialog on the shell overlay. Seen ids are the plugin-wide PersistentDB string `watchdog_seen_notices`, a JSON array. Hiding the shell does not mark them seen. A failed save still counts as seen until the plugin unloads. The next load shows the notice again if the write never landed.

## Considered options

Per-character storage. Rejected. The notice is about the plugin, not one character's alerts.

One modal per missed version. Rejected. Someone who missed several versions gets one dialog. The newest section starts open. Older sections start collapsed.

A checkbox or remind-later. Rejected. Close and the title-bar X both record every id that was in that dialog. Escape stays unbound.

Auto-opening the full Tutorial. Rejected. Getting started is four short paragraphs. The info button still opens the Tutorial every time.

Backfill of older versions. Rejected. A version with no entry never pops. 1.0.0 is the first entry.

## Consequences

The catalog is `src/release_notes.lua`, oldest first. A paragraph is text, a title `{ title = "Known issues" }`, or a picture `{ image = "releases/tutorial", width = 893, height = 554 }`. `image` is a path under `resources/images`, without the extension. The dialog loads that resource and scales it down to the section width. A release id is `release:<version>`, using the version string on that entry. Getting started uses the stable id `editor-tips`. Rewriting those paragraphs does not show it again. Capture restore does not offer a notice. Dismissing What's new does not open Getting started during that same editor stay. The hold clears on the way back to the alerts list, and when a window open finds the alerts list on top.
