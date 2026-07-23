# The Alert Manager is built from native ui.* components, not Canvas immediate-mode

The Alert Manager — the single management surface the keybind and the LibPluginMenu button
open — is composed from **real interactive components** on a native `ui.Panel`, *not* drawn in
immediate mode on a `ui.Canvas` the way the graph editor is (ADR-0001). Each alert or group is a
horizontal row `ui.Panel` holding its own children (an enable `ui.Check`, a label, a scope badge,
edit/delete `ui.Button`s, an expand chevron); groups are **nested vertical `ui.Panel`s**, so the
folder tree is expressed directly in the component hierarchy rather than modeled and hand-drawn.

ADR-0001 chose Canvas for the editor because Canvas is the only primitive whose draw coordinates
the plugin fully controls, which is the prerequisite for continuous **pan and zoom**. The Alert
Manager is a scrolling list, not a pannable/zoomable viewport — it has no pan or zoom — so that
justification simply does not extend to it, and the trade-off inverts. A `ui.Panel`
(`ui.ComponentCollection`) supplies, for free, exactly the machinery a manager needs and an
editor did not: native vertical/horizontal **auto-layout** (`isVertical`, `spacing`, relayout on
child change and on visibility toggle), native **scrolling** (`scrollable`, `SetScrollPos/Size`),
per-control **click hooks** (`ONBUTTONPRESSED`, `ONVARTRANSMIT`) so no per-widget hit-testing,
the native **drag gesture** (`Component.dragConfig` + `ONDRAG`/`ONDRAGCOMPLETE`, with client-side
drag-delay and dead-zone), and — decisively — `ui.InputField`, a text field **with a caret** for
renaming alerts and groups, which Canvas cannot provide (the unsolved problem ADR-0004 deferred;
the Canvas editor itself already falls back to a native `ui.InputField` when it needs typed text).

## Consequences

The plugin now runs **two UI paradigms**: the Canvas immediate-mode editor and the native-component
Alert Manager. That second paradigm is not foreign — the editor's window chrome is already a native
`ui.GroupBox` with native toolbar `ui.Button`s, and `toast.lua` / the node palette already build
native `ui.Panel`s — so the Manager extends an existing seam rather than opening a new one. The
`ui.List` component is deliberately **not** used: it is a selection/dropdown widget whose entries are
a flat `(label, id)` pair with no nesting and no rich per-row content, which fits neither the group
tree nor the multi-control rows.

Two pieces of behaviour remain **bespoke in this paradigm too**, and belong to the interaction-spec
ticket, not here: (1) **multi-select** — `ui.Panel` has no built-in selection, so selection state and
the selected-row restyle are the Manager's own; (2) **drop-target resolution** — the drag *gesture*
is native, but deciding whether a released row landed as a reorder-between-siblings or a
drop-into-group is our hit-test against sibling/group rects. Both are unavoidable in either paradigm,
so they are not a mark against native components.

The cost paid for all of the above is **visual styling**: native components render with the client's
default look and must be themed to match the editor's dark palette via `stylesheetID`s and sprite
overrides — friction the codebase already meets (`safePanelStyle`, `safeButtonStyle`, the sprite
experiments commented out in `ui/graph.lua`). Canvas would have given pixel-exact control instead,
at the price of hand-rolling scroll, layout, every hit-test, and a text-caret workaround. We judged
the interaction and text-input machinery worth more than pixel-exact chrome for a management surface.

The Canvas immediate-mode alternative was rejected on that trade: it re-implements list, scroll,
drag, expand/collapse, and caret-less text entry by hand to buy a visual match the manager does not
depend on. This decision is presentation-layer only — it changes nothing in the LibNodeGraph engine
or in node types, and it does not touch the graph editor, which stays on Canvas per ADR-0001.
