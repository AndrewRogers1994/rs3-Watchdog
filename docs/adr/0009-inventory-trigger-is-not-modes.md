# Inventory Trigger is occupancy + snapshots; item totals are Item Count

RuneLite Watchdog jammed full/empty/count/amount/changed into one inventory trigger. RS3
Watchdog is a graph, so that taxonomy is the wrong seam. The **Inventory Trigger** Fires only
on `InventoryUpdated` for one Container (Inventory or Bank), with no Modes and no Matcher. It
republishes occupancy and frozen previous/current Inventory Snapshots. Matching items and
summing quantities is a separate inventory-Category Pure Node, **Item Count** (Matcher on
display name, Note Filter via `CERT_` `configName` prefix, default Both). Matching-sum edges
are **Item Count Changed** (exec-through, same Matcher and Note Filter, previous vs current
Snapshot sums) rather than a Matcher on the Trigger. Thresholds and became-full are
Compare/Branch on those pins, not extra Trigger Modes.

## Considered Options

- **Five-Mode Trigger** (RuneLite shape) — rejected: occupancy and item identity are different
  domains; each new question becomes another Mode.
- **Matcher on the Trigger** as a Fire gate — rejected: it duplicates Item Count's needle and
  means "this change touched that name," not "the Container holds N." Matching-sum edges use Item
  Count Changed.
- **Author-facing ObjType ids** / `GetTotal` — rejected: authors match names; noted vs unnoted
  is the Note Filter, not an id Control.
- **Exec-through count node** — rejected for Item Count: it stays a Pure Node so Compare can
  pull it. Item Count Changed is the separate exec node for the edge.

## Consequences

Every `InventoryUpdated` for that Container Fires, including while `isFull` stays true or an
item total stays above a threshold. Edges are the author's graph (prev vs current used slots,
two Item Counts, or Item Count Changed). `invSnapshot` is a frozen copy; live `Inv` handles
would corrupt `prev`. The inventory Category holds Item Count and Item Count Changed; the
Trigger stays in the trigger Category.
