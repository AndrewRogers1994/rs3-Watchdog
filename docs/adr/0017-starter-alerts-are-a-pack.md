# Starter alerts are a Pack Watchdog registers

The starter graphs are Alert Presets on a Pack named Watchdog. Watchdog registers that Pack at startup. The player adds a copy from New alert. Those copies are ordinary Alerts. The starters are not rows in the Preset library, and nothing inserts them into a Scope on its own.

## Considered options

A separate Catalog section, plus a one-shot seed of disabled Alerts into the global Scope. Rejected. New alert already lists a Pack's Alert Presets.

## Consequences

The Tick Counter Alert, created when the global Bucket is missing, stays. It is not one of these Alert Presets.
