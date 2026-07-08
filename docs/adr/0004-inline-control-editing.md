# ADR-0004: Inline Control editing via transient real components

Status: Accepted (2026-07-07)
Amends: ADR-0001 (Canvas immediate-mode editor). Builds on ADR-0002 (editor mirrors
engine capability), ADR-0003 (Palette).

## Context

A data-input Pin with no incoming Connection resolves to its **Control** — the value stored
on the node (`Graph:GetControl` / `SetControl`, seeded from the pin's `default`). Until now
the Editor could show connections but gave no way to *edit* a Control: you could wire a Pin
but not type a number into an unconnected one. Inline Control editing was deferred three
times (see the milestone notes) for one stated reason: **"the Canvas has no text caret."**
That was not an oversight about what the toolkit offers — it was the *consequence* of a
deliberate earlier choice. ADR-0001 committed the whole editor to one immediate-mode Canvas
because Canvas is the only primitive the plugin can pan/zoom; real interactive components
were ruled out precisely because they **can't scale with the View**. Having ruled them out,
the only drawing surface (Canvas) is inert drawables with no way to host a keyboard cursor —
hence "no caret."

The compromise that unblocks it: those same components are perfectly fine *while editing*,
because during a single edit the user isn't zooming, so the component's inability to scale
doesn't matter. So the persistent picture stays pure Canvas (ADR-0001 intact) and a real
component appears only for the brief life of an edit. The two components used:

- **`ui.InputField`** — a text box with a caret, `filterMode` (`NUMERIC`, `ALPHANUMERIC`,
  `QUANTITY`, …), `maxLength`, `.content` / `.contentQuantity`, and an `ONCONTENTCHANGED`
  hook whose callback is `fn(component, cause, newContent)` where `cause` is an
  `ui.InputFieldActionResult` (`CONTENT_CHANGE`, `SUBMIT`, `SUBMIT_ON_FOCUS_LOSS`, …).
- **`ui.ComboField`** — a dropdown: `Add` / `SetEntries` / `Select`, `.selectedID` /
  `.selectedLabel`, and an `ONSELECTIONCHANGED` hook, callback `fn(component, id, status)`.
  **The `id` argument to `Add` is checked for uniqueness only, not respected for storage or
  sorting** (discovered in-client, contradicts what the docs imply): passing an id already in
  use is rejected as a collision, but otherwise `ComboField` always sorts its entries
  alphabetically by label and reassigns them sequential ids 1..N in that sorted order —
  `Add("Z", 0)` then `Add("A", 99)` ends up `A=1, Z=2`, ignoring the 0/99 passed in beyond
  collision-checking. This was the actual root of
  the enum picker "showing/setting the opposite value" bug: code that assumed `Add`'s id
  round-trips through `selectedID` was reading a different label than intended. The fix is to
  key off entry **text**, not id — see `ui/graph.lua`'s `openControlEditor` (pre-select
  matches `field.entries[i].text`) and `selectedChoice`'s caveat about `spec.choices[id]`
  indexing.

(Both hook constants are **absent from the generated `ui.Hook` stub** but present and working
in-client — the stubs lagged; the docs site is authoritative. Code resolves the hook as
`ui.Hook.ONCONTENTCHANGED or "ONCONTENTCHANGED"` to survive either.)

## Decision

**1. Editing mechanism — transient real component on click-to-edit.**
The Control's *current value* is drawn on the Canvas like everything else (a small value box
+ text, scaling with zoom). Clicking a Control mounts **one** real `InputField`/`ComboField`
over that box; on commit it writes back through `Graph:SetControl` and is destroyed. At most
one editor exists at a time. This keeps the immediate-mode render model of ADR-0001 intact —
the persistent picture is still all Canvas — and confines the real component to a short-lived
popup whose inability to scale/clip with the View doesn't matter.

Rejected: a persistent per-pin overlay of real components (many live components that don't
scale or clip, fight the Capture Layer for input, and churn as nodes cull); and hand-rolling
a text buffer + fake caret from `Event.KeyDown` (reinvents what `InputField` gives for free).

**2. Enum picker — transient real `ComboField`.** Same lifecycle as the text/number editor,
for consistency: click opens a real dropdown, `ONSELECTIONCHANGED` commits and closes.
Rejected: a Canvas-native dropdown reusing the Palette machinery — more code for a widget
the toolkit already provides, and the transient InputField already breaks pure-Canvas for
editing anyway, so a transient ComboField is the consistent choice.

**3. Control metadata lives in the Watchdog UI, keyed by Type Tag.** LibNodeGraph stays
tag-agnostic (ADR-0002): it neither knows nor validates which widget a tag uses or what an
enum's members are. Watchdog owns a **Control Spec** map (`ui/controls.lua`), parallel to
`Theme.TypeColor`: a Type Tag resolves to `{ widget = "number" | "text" | "enum", choices?,
format?, parse? }`. Built-in specs: `number` → numeric field, `string` → text field, `bool`
→ enum dropdown (`true`/`false`). A domain enum is one `Controls.Register(tag, spec)` call.
Rejected: putting a `choices` field on the engine's pin definition — that pushes presentation
metadata into the deliberately UI-free engine. (If a genuinely pin-specific enum is ever
needed, register a distinct tag for it; that keeps the boundary clean.)

## Consequences

- **A Control is shown only for an unconnected data-input Pin whose Type Tag has a spec.**
  Connecting a Pin hides its Control (the wire supplies the value); disconnecting shows it
  again. Exec pins, outputs, connected inputs, and tags with no spec get no editor.
- No engine or Store change. `SetControl` mutates `node.controls`, which already serializes
  and is already picked up by the debounced autosave diff — edits persist for free.
- The transient field mounts as a **child of the GroupBox**, positioned at the Control's
  Canvas-local rect **directly (no header offset)**. A GroupBox child and the child Canvas
  measure from the same content-area origin, so the box's draw coords are the field's coords
  as-is — verified in-client (adding `WINDOW_HEADER_H` put the field a header-height too low).
  It must also carry a `stylesheetID` (`BUTTON_DEFAULT` for the InputField, `COMBO_DEFAULT`
  for the ComboField), or it renders with no background sprite and is invisible — the cause of
  an early "the field just disappears" bug. It is re-fronted each frame like the toolbar
  Buttons, since `canvas:MoveToFront()` would otherwise bury it.
- **No programmatic focus.** Neither `Component` nor `InputField` exposes a focus method
  (`SetFocus`/`RequestFocus` absent from the docs), so a freshly-mounted field does not take
  keyboard focus — the user clicks it once to focus, then types. A best-effort `SetFocus()`
  pcall remains in case a future client adds one.
- **Nil-Control fallback.** The box display and the editor prefill fall back to the pin's
  `default` (now exposed via `Graph:GetPins`) when the stored Control is `nil` — e.g. a graph
  saved before the pin gained a default. Combined with the empty-box guard in `commitField`
  (an empty field never writes), this stopped an unseeded numeric pin from committing `0` on
  a click-and-close.
- The editor closes (committing first) on: a submit/focus-loss `cause`, a combo selection, a
  click that lands on the Capture Layer instead of the field (click-away), a scroll/zoom, and
  `SetVisible(false)` / `Unmount`. Clicking *into* the field is captured by the field itself,
  so it does not trip the click-away path.
- Verified in-client: the field mounts, renders (with the stylesheet), and accepts typed
  input; live-write via `ONCONTENTCHANGED` and click-away/submit commit both work. Focus
  needs a click (no API, above); the mount offset is zero, not `+WINDOW_HEADER_H` (above).
