# Alert Toggle saves the Bucket it matched

Alert Toggle turns on, turns off, or flips every Alert of a given name on a resident Scope. Each match writes that Alert's enabled flag and saves that Scope's Bucket. A character Alert used to change only in memory. The save hook had the global document and wrote by id, and the same id can exist in two Buckets, so a global write could hit the wrong Entry. The match is already an Entry on a Scope, so the save goes to that Scope's Bucket.

## Considered options

Leave the character Alert memory-only. Rejected. This session would fire the new value, and the next login would restore the old one.

## Consequences

An Alert whose Scope is not loaded is not matched. A disarmed resident Scope is matched. Disable releases that Alert's visuals. Enable does not restore them. A matched Alert inside a disabled Group still has its own flag written, and it stays silent until that Group is enabled. The Manager checkbox is a different control. It flips one Entry by id and saves that Entry's Bucket. A failed save does not put the flag back. That rule is ADR 0015.
