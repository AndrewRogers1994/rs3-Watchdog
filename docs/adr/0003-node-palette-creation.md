# Node creation is a Canvas-drawn Palette, not the native MiniMenu

Nodes are created through the **Palette**: a plugin-owned popup drawn on the Editor's
Canvas in immediate mode, listing the Registry's Node Types grouped by Category. It is
*not* built on RuneScape's native right-click MiniMenu, and it is *not* triggered by a
right-click.

This was forced by the client API (verified against the authoritative docs at
d1s24e1pcksyf8.cloudfront.net, which win over the stubs):

- **The native MiniMenu cannot be extended.** `game/minimenu.html` exposes only
  `MiniMenu.IsOpen()` and `MiniMenu:Swap(a, b)` — the docs state the principal management
  event `Event.MiniMenuReady` gives "access to the full list of entries, as well as the
  ability to Swap entries." There is no Add/Insert/Create/Remove/Clear. The
  `MiniMenuEntryType.PLUGIN = 10` enum value exists but has no author-side API, so a plugin
  cannot inject its own "Add Node…" entry into the Cancel-only menu that appears over the
  Viewport, nor delete that Cancel entry.
- **There is no right-click hook on components.** `ui.Hook` has `ONCLICK` (left button)
  only — no secondary/right variant — so the Capture Layer physically cannot receive a
  right-click to open a menu of our own.

Drawing our own Palette is therefore the only option, and it is also the *right* one: it is
consistent with ADR-0001 (the whole Editor is immediate-mode on one Canvas, hit-tested
manually), and only a plugin-drawn surface can offer categories, scrolling, and type
filtering — a flat MiniMenu could not.

## Two entry points, one Palette

- **Drag-to-create (filtered).** Dragging a Wire from a Pin and releasing it on empty
  Viewport opens the Palette filtered to Node Types that have a Pin able to receive it:
  matching kind, opposite direction, and (for Data) a compatible Type Tag — reusing the
  exact rules the Wire-drop path already enforces (ADR-0002). The first such Pin per type is
  the auto-connect target; choosing a type creates the Node at the drop point and links it
  in one gesture. A grab-from-input drag that lands on empty offers the same, rewiring the
  freed output into a fresh Node.
- **Unfiltered.** A double-click on empty Viewport (paired within a short Logic-tick window)
  or the toolbar **+** opens the Palette listing every Node Type. Double-click places the
  new Node's origin at the open point; the toolbar **+** places the Node Body's center at
  the center of the current Viewport (#96), while the panel itself still opens near the
  button.

Both go through a single Editor open path, so a future launcher (see below) can reuse it.

## Consequences

- **v1 is a categorized clickable list with no text search.** The Canvas has no text caret
  (the same limitation that deferred inline Control editing in ADR-0001), so a Blueprints-
  style search box would mean hand-rolling text input from `Event.KeyDown`. Deferred; for
  the current ~two-dozen Node Types a scrollable category list is enough. Type-to-filter is
  a later pass.
- **The Palette is modal and clamped inside the Viewport.** While open it consumes clicks
  (pick an item, or click-off to dismiss) and the wheel scrolls it instead of zooming. It is
  clamped so every row stays over the Window-sized Capture Layer, avoiding any Capture Layer
  resizing.
- **The native MiniMenu path is left open as a future refinement, not a dependency.** If
  Jagex ships an author-side entry-add API (the `PLUGIN` enum suggests it is planned), a
  right-click launcher can be added that simply calls the same Palette open path — the
  design does not bet on it.
