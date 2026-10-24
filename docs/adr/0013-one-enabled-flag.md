# An Alert has one enabled flag

The example Alert was saved disabled and passed to the Runtime enabled, so the row showed off while that session still fired. An Alert has one enabled flag, on its Entry. The checkbox and firing both read that flag. The Runtime does not keep an enabled value of its own.

## Considered options

A session-only enable, so the first-run example could fire once and come back disabled. Rejected. The row and the fire would disagree for that whole session.

## Consequences

A Group still has its own enabled flag. Group disable still does not write child flags. Disable still releases that Alert's visuals. Enable still does not restore them.

When the global Bucket is missing, the example Alert is created disabled. That session does not fire it.

Alert Toggle writes that same flag and saves the matched Bucket, including a character Bucket. The id-collision case is recorded in ADR 0014. A failed save leaves the new flag in place. That case is recorded in ADR 0015.
