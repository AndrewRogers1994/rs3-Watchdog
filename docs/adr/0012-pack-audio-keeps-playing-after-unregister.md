# A play already started keeps going after a pack audio file is unregistered

A pack audio file is offered only while its Pack is registered. The client will still start that file after the Pack is disabled if Watchdog keeps the object, so unregister drops it from the live registry. The alert keeps the Pack name and author id. A play that has not started is silent, including one that fires while an earlier play of that file is still audible. A play already started runs until it finishes, including the loop count it was started with. Watchdog does not stop it.

## Considered options

Cutting off every live play of that file at unregister. A sound already going is left to finish.

## Consequences

The client docs do not say a playing sound survives releasing the last reference to the file. Watchdog may keep the object privately until that play finishes. That hold is not the file being loaded, so a new play stays silent. When the Pack loads and registers the file again, a new play works, and a play still finishing from before keeps going.

A pack sound effect is a different contribution. It plays a snapshotted builtin sound id whether or not the Pack is loaded.

Watchdog does not observe Pack shutdown. The Pack releases the registration from its own `PluginShutdown` by clearing the registration token, and this rule runs there. See [Does Watchdog drop a loaded pack audio file when the Pack shuts down?](https://github.com/adamk33n3r/rs3-Watchdog/issues/142) and [What does a Pack hand over when it registers?](https://github.com/adamk33n3r/rs3-Watchdog/issues/125).
