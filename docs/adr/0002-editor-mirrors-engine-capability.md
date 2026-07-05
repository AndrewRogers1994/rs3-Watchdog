# The editor mirrors engine capability rather than imposing Blueprint conventions

Where the LibNodeGraph engine and Unreal Blueprints disagree on connection rules, the editor
follows the engine. Concretely: an Execution output Pin may fan out to multiple Wires,
because the engine deliberately supports that (ADR-0004: an exec output with multiple
Connections fires all of them, unordered) — even though Blueprints forbids it and pushes
users to a Sequence node. The editor never rejects a Connection the engine would accept, and
never invents a constraint the engine does not enforce. This keeps the UI an honest window
onto the real graph, consistent with "UI owns layout only, the engine owns structure."

## Consequences

Blueprint muscle memory is violated in one place (multi-wire exec outputs), accepted as the
cost of not lying about the model. The engine's *actual* constraints are still honored and
surfaced as UX: a Data input accepts only one Connection (the engine hard-asserts on a
second), so dropping a new Wire onto an occupied Data input auto-disconnects the existing
Connection first — Blueprints' replace behavior, here driven by the engine rule rather than
imitation. Illegal drops (type-tag mismatch, wrong pin kind/direction, or a would-be cycle)
are refused because the engine's `Connect` would reject them; the editor validates against
those same rules before committing so a rejected drag simply snaps back.
