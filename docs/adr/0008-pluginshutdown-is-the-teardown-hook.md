# `PluginShutdown` is the teardown hook, not the re-execution guard

The client calls an undocumented global **`PluginShutdown()`** when a plugin is disabled, when it
is reloaded, and when the game client exits cleanly. It takes **no arguments**, and
`PersistentDB` writes are **accepted from inside it**. Watchdog treats this — not the
`if watchdog ~= nil then watchdog.Stop() end` guard at the top of `main.lua` — as the point where
teardown and state-flushing happen.

This was established empirically (the function appears nowhere in the API docs) by driving a
probe plugin through disable/enable/reload cycles and reading its journal out of `PluginData.db`.
The measured behaviour:

| Trigger | `PluginShutdown` fires | New instance loads |
|---|---|---|
| `poff <plugin>` (disable) | yes | no |
| `pon <plugin>` (enable) | — | yes |
| `plugins_reload <plugin>` | yes | yes, after |
| Clean client exit | **yes** | — |
| Client crash | no | — |

The decisive finding is the clean-exit row. Watchdog carries live state — alert definitions,
graph edits, toast history — and until now had no way to know the game was closing; anything not
already debounced to disk at that moment was simply lost. `PluginShutdown` is the only hook the
client offers for that, and because `PersistentDB` still accepts writes there, a synchronous
final flush is possible.

The re-execution guard is a **different mechanism for a different case** and does not subsume
this. On `plugins_reload` the client discards the Lua state entirely, so the new instance sees
`watchdog == nil` and the guard never fires — measurably: across three reload cycles the probe's
guard logged nothing while `PluginShutdown` logged every time. The guard only covers a script
re-executed *within a live state* (a save-triggered redeploy over a running instance). Both are
needed; neither replaces the other.

## Consequences

Watchdog gains a `PluginShutdown` that unsubscribes its events and flushes any pending debounced
save synchronously. The flush must be synchronous and cheap — the client is tearing down around
it, and there is no next tick in which to finish. That argues for keeping the persisted document
small enough to write in one call, which the store already does.

**It must not unmount or destroy its UI there**, which is the counter-intuitive part. Calling
`:Destroy()` on a component from inside `PluginShutdown` crashes the client outright — the
client performs its own teardown of the plugin's component tree afterwards and does not tolerate
the components already being gone. Unsubscribing events in the same hook is fine; UI teardown is
the client's job and must be left to it. Both were isolated by controlled experiment: four
variants identical except for the shutdown body, where "not defined", "empty", and "unsubscribe
only" all survive and "destroy the layer" dies. This differs from `Stop()`, which *does* destroy
its UI — `Stop()` runs on script re-execution within a live state, where no client teardown is
coming and the plugin genuinely owns the cleanup.

**Nothing may be relied on at crash time.** `PluginShutdown` does not fire when the client dies,
confirmed directly: the probe's journal shows two consecutive load entries with no shutdown
between them, spanning a hard crash. So the existing debounced-save behaviour stays as the
durability floor and the shutdown flush is a best-effort improvement on top, never the only thing
standing between the user and data loss.

A second, unrelated constraint applies to any plugin issuing lifecycle console commands:
**`ExecuteConsoleCommand("plugins_reload" / "pon" / "poff", …)` must not be called from inside an
`Event.Logic` handler.** Doing so kills the process with a different access violation
(`+0x947123`, versus `+0x593d8b` for the UI-destroy crash — two distinct faults, initially
mistaken for one). Driving the same commands from `Event.Draw` runs a full disable/enable/reload
script cleanly.

Both are client bugs rather than design constraints we chose, so these rules may relax if they
are fixed. See `ReproPluginReloadCrash/` for the minimal reproductions and crash analysis.

The probe plugins that produced these findings (`ProbeShutdown`, `ProbeHarness`) are throwaway
and live outside this repo. `ProbeHarness` is worth keeping as a general-purpose driver — it
runs a scripted sequence of console commands on a timer and journals the result to
`PersistentDB` — but it is not a Watchdog dependency.
