# Inventory Trigger is occupancy + snapshots; item totals are Item Count

RuneLite Watchdog jammed full/empty/count/amount/changed into one inventory trigger. RS3
Watchdog is a graph, so that taxonomy is the wrong seam. The **Inventory Trigger** Fires only
on `InventoryUpdated` for one Container (Inventory or Bank), with no Modes and no Matcher. It
republishes occupancy and frozen previous/current Inventory Snapshots. Matching items and
summing quantities is a separate inventory-Category Pure Node, **Item Count** (Matcher on
display name, Note Filter via `CERT_` `configName` prefix, default Both). Thresholds and
became-full are Compare/Branch on those pins, not extra Trigger Modes.

## Considered Options

- **Five-Mode Trigger** (RuneLite shape) — rejected: occupancy and item identity are different
  domains; each new question becomes another Mode.
- **Matcher on the Trigger** as a Fire gate — rejected: it duplicates Item Count's needle and
  means “this change touched that name,” not “the bag holds N.”
- **Author-facing ObjType ids** / `GetTotal` — rejected: authors match names; noted vs unnoted
  is the Note Filter, not an id Control.
- **Exec-through count node** — rejected: Item Count is a Pure Node so Compare can pull it.

## Consequences

Every `InventoryUpdated` for that Container Fires, including while `isFull` stays true or an
item total stays above a threshold. Edges are the author's graph (prev vs current used slots,
or two Item Counts). `invSnapshot` is a frozen copy; live `Inv` handles would corrupt `prev`.
v1 ships only this Trigger plus Item Count in the inventory Category.
