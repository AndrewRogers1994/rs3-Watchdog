# Character buckets are keyed on the tracking id

Character buckets used to key on the display name, so a rename was a character switch and the old bucket was orphaned. `Player.GetTrackingID` is a stable per-character id. Watchdog requires `trackingAccess` and keys the character bucket on that id, so a rename keeps the bucket. There is no display-name fallback. Existing `player_<display name>` keys are left unread: this was decided before players had saved character buckets, so nothing is migrated.

The character tab still shows the display name. Logged out, or an empty id while in game, means the global bucket only.
