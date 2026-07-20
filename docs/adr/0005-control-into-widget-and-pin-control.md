# ADR-0005: Split the Control into a Widget seam and a Pin Control seam

Status: Accepted (2026-07-20) — design agreed, implementation pending (coordgrid PoC first).
Amends: ADR-0004 (inline Control editing). The **Control Spec** map ADR-0004 introduced is
superseded by the **Pin Control** module described here. Builds on ADR-0001 (Canvas
immediate-mode editor), ADR-0002 (editor mirrors engine capability).

## Context

ADR-0004 established that a Control's presentation metadata lives in the Watchdog UI keyed by
Type Tag — a passive **Control Spec** table (`ui/controls.lua`) resolving a tag to
`{ widget, choices?, format?, parse?, extraH?, Layout? }`. Since then the set of Controls has
grown well past the original number/text/enum: composite bands (coordgrid), a swatch + color
popup, a reusable matcher, capture-arming buttons, object-marker mode checkboxes. Each
addition confirmed the same friction.

**A single Control's logic is smeared across three files, and one discriminator (`kind`)
reappears in four places:**

1. `ui/controls.lua` — the Spec (band height, `Layout` closure producing sub-rects tagged with `kind`).
2. `ui/node.lua` `BuildGeometry` — turns the Spec's `Layout` into concrete `geom.controls` rects.
3. `ui/graph.lua` `buildGeoms` — a switch on `kind` for the display string.
4. `ui/graph.lua` `beginPress` — a switch on `kind` for what a click does.
5. `ui/graph.lua` `commitField` — a switch on `kind`/`axis`/`widget` for how to commit.

So coordgrid alone touches `controls.lua` (spec), `node.lua` (one branch), and five-plus
methods in `graph.lua`. This is not an accident of neglect — it is the scar of the **original
seams**. The architecture was cut into *presentation-config* (`controls.lua`, pure data, loads
headless), *drawing-geometry* (`node.lua`, builds the whole node's rects), and *interaction*
(`graph.lua`, owns mouse + transient components + engine mutation). A control's concerns cut
*across* all three, so its code is scattered across all three. "Add a Control" edits three
files and appends to two growing switch statements, each far from the others.

The deletion test confirms the switches earn nothing: they are pure dispatch by control type,
duplicated across the three phases. Pulling that dispatch behind a per-control module
concentrates it; the switches vanish.

A second concern surfaced in the design discussion: several of these input primitives (text
box, dropdown, color swatch) are generic and may later be extracted into a reusable UI
library. They should be isolated from the engine now so that extraction is a move, not a
rewrite.

## Decision

Re-cut the seam **around the control**, in two stacked layers, with a host seam between the
Pin Control and the Editor.

**1. Two seams — Widget and Pin Control.**

- A **Widget** is a generic, engine-agnostic input primitive (text field, number field,
  dropdown, swatch, button, mode toggle). It draws itself at a rect and edits a *value*,
  reporting the edited value back out. It knows nothing of Pins, Nodes, or the Graph, and may
  depend only on `Theme`/`Color`/`ui.*` — never on a Pin Control, the Editor, the Store, or the
  engine. Lives under `ui/widgets/`, one file per Widget. This dependency rule is what keeps a
  future UI-library extraction a move rather than a rewrite.

- A **Pin Control** is the per-Type-Tag module that composes Widgets and **binds them to a
  Pin's stored Control value**. It owns its own layout, internal hit-routing, display, click
  behavior, and — crucially — the engine binding: the read-modify-write / codec that maps
  between a Widget's natural value and the Pin's stored value (e.g. writing the matcher's
  `needle` while preserving its `mode`; one axis of a coordgrid while preserving the others).
  Registered by Type Tag in `ui/controls.lua`; one module per control under `ui/controls/`.

The Control Spec of ADR-0004, as a *passive table read from a distance*, dissolves — the Pin
Control module **is** the spec, but active: it owns its layout and behavior instead of being
interpreted by two other files. `ui/controls.lua` shrinks to the Type-Tag → Pin Control
**registry**. The value **codec** (`format`/`parse`) moves onto the Widget (a number Widget
knows how to parse `"1K"`); an enum's `choices` become config a Pin Control hands its dropdown
Widget; the RMW stays the Pin Control's.

Rejected — a pure-transform extraction (move only the bodies of the switch branches into
`controls.lua`, leave the switches as one-line calls in `graph.lua`): it does not deliver the
win. The switches survive, so a new control still edits `beginPress` and `commitField`.

**2. Pin Control owns its own geometry and hit-routing.** The Editor hit-tests only to *which
Pin Control is under the cursor* (one rect per control), then hands the local point to the Pin
Control, which routes to its own Widget. The Node still owns *row* layout — pins, header, the
cumulative row-height math — and asks each Pin Control two things: "how tall are you?" and "lay
out your insides in this band." Node lays out rows; Pin Control lays out itself; Widget draws
itself.

Rejected — the Editor keeping a flat `geom.controls` rect list and routing centrally: it
leaves a thinner version of the same smear (the Editor stays aware of a control's internals),
so "add a Pin Control" would still touch Editor code.

**3. The host seam — a pushed object, not returned intents.** Most of a Pin Control is pure
(layout, display, value-mapping) and needs nothing external. The few Editor-only capabilities
— mount a transient real field/dropdown (needs the GroupBox parent + ADR-0004's stylesheet /
zero-offset quirks), open the Color Popup, arm a screen/object-marker capture, and commit
(`Graph:SetControl` + preload pass + geom rebuild) — are reached through a **host** object
passed to the Pin Control. The host is a genuine seam with exactly two adapters: the real
Editor in-client, and a **fake host** in tests that drives a full press→commit sequence and
asserts the committed value headless, with no `ui.*` involved.

Rejected — an intent-return model (`onPress` returns a description the Editor executes): it
re-introduces a switch (over intent types) in the Editor, the very thing this ADR removes.
Bounded though that switch would be, the host-object model needs no Editor branching at all.

**4. Color popup and captures stay as host-routed services.** `ui/color_popup.lua`,
`ui/screen_marker_capture.lua`, `ui/object_marker_capture.lua` keep their current homes and
lifecycles (the captures are runtime-level and run even when the editor is closed). A Pin
Control triggers them through the host; it does not own them. Folding the color popup into a
self-contained color Widget is deferred until the Widget seam exists to receive it (one-adapter
= hypothetical seam: don't move it until there's a second reason).

**5. Landing strategy — spike then sweep.** Because saving an editor file deploys to the live
client, build one control end-to-end as a proof of concept behind a temporary bridge (the
Editor routes new-style controls to their Pin Control, else falls through to the old `kind`
switches), verify it in-client, *then* sweep the remaining controls in one pass and delete the
switches and the bridge. The PoC is **coordgrid** — it exercises the most mechanics at once
(composite band, self-owned hit-routing, multiple Widgets, per-axis RMW, the host transient
field, and a one-shot action). Sweep order thereafter: scalar (string/number) → matcher →
enum/bool → swatch → capture.

## Consequences

- **Adding a Control becomes one file.** A new Type Tag = one Pin Control module + whatever
  Widgets it composes (reusing existing ones where possible), registered in `ui/controls.lua`.
  No edit to `node.lua`, no edit to `graph.lua`, no switch to extend. The `kind` discriminator
  stops being a cross-module concept and becomes internal to whichever Pin Control uses it.
- **`ui/widgets/` carries a hard dependency rule:** Theme/Color/`ui.*` only. A lint/typecheck
  or review catch on any `require` of `controls`/`graph`/`store`/`runtime`/engine from that
  directory protects the future extraction.
- **The interface is the test surface.** New tests drive each Pin Control's press→commit
  through the fake host and assert the committed value; Widgets get value-in → value-out tests.
  No test reaches past a Pin Control's interface. `test_controls.lua`, `test_node.lua`
  (geometry), and `test_graph_editor.lua` must stay green through every migration step.
- **Testability improves where it was worst.** The commit paths that motivated recent bug
  fixes (matcher needle vs mode, text-clear-vs-reset, empty-box guard) become pure functions in
  their Pin Control, exercised headless — today they are reachable only through the live Editor.
- ADR-0004 stays in force in substance: inline editing via a transient real component is
  unchanged; that component is now mounted *by the host on a Widget's behalf* rather than by
  `graph.lua` directly, and its discovered quirks (zero header offset, required `stylesheetID`,
  re-front each frame, no programmatic focus, ComboField label-not-id) move behind the host's
  mount helper — one place instead of inline in `openControlEditor`.
- No engine or Store change. Controls still live on `node.controls`, still serialize, still
  ride the debounced autosave diff.
- During the PoC window a temporary dual path exists (new Pin Control for coordgrid, old
  switches for the rest). It is deleted in the sweep; it is not a permanent abstraction.
