# Watchdog (UI)

The graph-editor UI for Watchdog: an in-client, Unreal-Blueprints-style visual editor
that renders and manipulates a live `LibNodeGraph` Graph. This context owns only
*presentation and interaction* — the graph model, node types, and execution belong to
[LibNodeGraph](../LibNodeGraph/CONTEXT.md). Watchdog UI never invents graph structure; it
draws what the engine holds and calls back into the engine to mutate it.

The editor is drawn entirely on a single `ui.Canvas` in immediate mode (rebuilt each
`Event.Draw` frame), because Canvas is the only client primitive whose coordinates the
plugin fully controls — a prerequisite for pan and zoom.

## Language

**Editor**:
The Watchdog graph-editor as a whole: the Canvas, its View, the input Capture Layer, and
the interaction logic that binds them to a Graph.
_Avoid_: Blueprint editor, canvas (the Canvas is one part of it), window

**Viewport**:
The on-screen region the Editor draws into — the pannable, zoomable window onto the Graph.
_Avoid_: Canvas (that is the render primitive), pane, frame

**View**:
The transform mapping Graph-space to Screen-space: a pan offset and a zoom factor. Applied
when drawing, inverted when hit-testing. UI-only state the engine has no concept of.
_Avoid_: Camera, transform (in prose), matrix, scroll

**Graph-space**:
The coordinate space Node positions are stored and reasoned about in, independent of pan
and zoom. Distinct from Screen-space, the pixel coordinates the Canvas draws in.
_Avoid_: World space, model space, canvas space

**Layout**:
The UI-owned mapping from a Node's id to its Graph-space position. The engine deliberately
stores no positions, so the Editor owns Layout. Persisted alongside the graph (see Store) as
part of a saved graph, keyed by node id — which round-trips only because the engine now
preserves node ids across serialize/deserialize.
_Avoid_: Positions (as a concept name), coordinates, placement, arrangement

**Store**:
Watchdog's persistence backend (`store.lua`): saves and restores graphs via `PersistentDB`.
LibNodeGraph never persists (it owns only tables/strings, ADR-0007); the Store is the
consumer half. It bundles the engine's serialized structure with the UI-only Layout and View
into one document and writes it as a single JSON string. Multi-graph from the start — the
document holds an array of named graph entries plus a `current` pointer — even though the
Editor shows only the current one and there is no new/switch-graph UI yet.
_Avoid_: Database, save system, persistence layer (in prose), serializer (that's the engine's)

**Capture Layer**:
A single full-screen, visually-empty interactive component sitting over the Canvas whose
sole job is to receive raw pointer events (`ONDRAG`, `ONSCROLLWHEEL`, `ONCLICK`,
`ONRELEASE`) the Canvas cannot, since Canvas drawables are inert. All hit-testing against
Nodes, Pins, and Wires is done manually from `Mouse.GetPosition()`.
_Avoid_: Overlay, hit layer, glass pane, input catcher

**Node Body**:
The filled rectangle drawn for a Node, carrying its Header and Pin rows. Square-cornered
(Canvas has no rounded rectangle).
_Avoid_: Box, card, frame, panel

**Header**:
The category-colored band at the top of a Node Body showing its title. Its color is keyed
off the Node Type's Category.
_Avoid_: Title bar, caption, banner

**Pin Glyph**:
The clickable mark drawn for a Pin: a triangle for an Execution Pin (matching Blueprints'
exec shape), a small filled square/diamond for a Data Pin, tinted by its Type Tag color.
The Glyph's Screen-space rectangle is the hit-target for starting or ending a Wire.
_Avoid_: Dot, knob, socket art, handle

**Wire**:
The rendered connection line, drawn as a tessellated bezier S-curve (Canvas has no native
curve). Covers both a committed engine Connection and the *pending* Wire dragged from a Pin
toward the cursor before it commits. Colored by the source Data Pin's Type Tag, or a neutral
color for Execution. NOTE: this softens LibNodeGraph's "avoid wire" rule by design — Wire is
the UI-layer rendering; the engine's model object remains a Connection.
_Avoid_: Line, edge, link (for the model — that stays "Connection")

**Type Color**:
The Editor's mapping from an engine Type Tag (opaque string, e.g. "bool", "coord") to a
draw color for Data Pin Glyphs and their Wires. Owned by the Editor, since the engine is
deliberately tag-agnostic; Execution Pins/Wires use a fixed neutral color outside this map.
_Avoid_: Pin color, tag color (in prose); "palette" (that word names the Palette below)

**Palette**:
The plugin-drawn popup for creating Nodes: a scrollable list of the Registry's Node Types
grouped by Category, drawn on the Editor's Canvas and hit-tested manually like everything
else. Deliberately NOT the native RuneScape MiniMenu, which cannot be extended (ADR-0003).
Modal while open. Opened filtered (Drag-to-Create) or unfiltered (double-click empty
Viewport / the toolbar +). Named after Unreal Blueprints' palette.
_Avoid_: Catalog, menu, context menu, MiniMenu, node browser

**Drag-to-Create**:
Creating a Node by dragging a Wire off a Pin and releasing it on empty Viewport: opens the
Palette filtered to Node Types with a Pin that can receive the Wire, and auto-connects the
chosen Node's matching Pin. The typed, one-gesture creation path (as opposed to the
unfiltered double-click / toolbar-+ path).
_Avoid_: Pull-to-create, drag-off, quick-connect

**Control Box**:
The small value box the Editor draws on an unconnected data-input Pin's row, showing that
Pin's Control (the engine's stored value for the Pin). It is Canvas-drawn like everything
else and scales with zoom; connecting the Pin replaces it with a Wire (ADR-0004). Clicking
it opens the Control Editor.
_Avoid_: Field, input box, widget (that's the mounted Editor), textbox

**Control Editor**:
The single transient real component (`ui.InputField` for text/number, `ui.ComboField` for
an enum) mounted over a Control Box while the user edits it, committing through
`Graph:SetControl` and torn down on commit. The one place the editor uses a real interactive
component rather than a Canvas drawable — deliberately short-lived so its inability to
scale/clip with the View doesn't matter (ADR-0004).
_Avoid_: Inline editor, popup, input widget (in prose)

**Control Spec**:
_(Target model: this passive table dissolves into the active **Pin Control** module below — the
per-Type-Tag behavior is being re-homed so one control's layout, click behavior, and binding stop
living in three files. The description here is the current state until that refactor lands.)_
The Watchdog-owned mapping (`ui/controls.lua`) from an engine Type Tag to how its Control is
rendered and edited: a widget kind (`number` / `text` / `enum` / `composite` / `swatch`) plus,
for an enum, its choices, for a composite, its `extraH`/`Layout` (see Control Band), or for a
swatch, its hex8 `format`/`parse` (see Swatch Chip). Parallel to Type Color, and for the same
reason — the engine is deliberately tag-agnostic, so presentation lives here (ADR-0004). Tags
with no spec (coord, any) get no Control Editor.
_Avoid_: Type metadata, schema, control config

**Widget** _(target model, not yet built)_:
A generic, engine-agnostic input primitive — text field, number field, dropdown, swatch, button,
mode toggle. Draws itself at a rect and edits a value, reporting the edited value back out; knows
nothing of Pins, Nodes, or the Graph. The reusable half, isolated for a possible future UI-library
extraction, so it may depend only on Theme/Color/`ui.*` — never on a Pin Control, the Editor, the
Store, or the engine. Lives under `ui/widgets/`, one file per Widget.
_Avoid_: control, component (that's the client's), field/box (those name one Widget kind, not the concept)

**Pin Control** _(target model, not yet built)_:
The per-Type-Tag module that composes Widgets and binds them to a Pin's stored Control value (the
location Pin Control lays out three number Widgets + a grab-position button over a `coordgrid`; the
color Pin Control, one swatch Widget). Owns its own layout, internal hit-routing, display, click
behavior, and — crucially — the engine binding: the read-modify-write / codec mapping between a
Widget's natural value and the Pin's stored value, so the matcher's `mode` survives a needle edit.
Reaches the few Editor-only capabilities it needs (mount a transient field, open the Color Popup,
arm a capture, commit) through a passed **host** seam, whose test adapter is a fake host driving
press→commit headless. Replaces the passive Control Spec; registered by Type Tag in `ui/controls.lua`,
one module per control under `ui/controls/`.
_Avoid_: control spec (the passive table it replaces), widget (that's the primitive it composes), handler

**Control Band**:
A `composite`-widget Control's own full-width strip drawn below its Pin's row instead of the
narrow value-column Control Box scalars get (e.g. `coordgrid`'s x/z/level fields + "set to
current position" button). Its height is reserved by the Spec's `extraH`, which pushes every
later Pin row down (Node Body layout is a cumulative running offset, not a fixed
`PIN_ROW_HEIGHT` stride, for exactly this reason); its contents come from the Spec's
`Layout`, one or more Control Boxes sharing the Pin's name and discriminated by a `kind`
("field" for an editable sub-value, "action" for a one-shot button like "set to current
position"). Reserved always; drawn/hit-tested only above `CONTROL_MIN_ZOOM`, same as any
Control Box.
_Avoid_: Sub-panel, composite box, field group

**Matcher**:
A reusable text-match specification carried by a Data Pin (Type Tag `matcher`): a needle
string plus a Mode — **Substring** (case-insensitive, literal) or **Pattern** (case-sensitive,
Lua pattern with magic characters). An empty needle matches everything (the filter is a
no-op). Rendered as a Control Band holding a text field and a single-row Mode toggle after
it; its matching semantics are shared by every Node that filters text (chat message, chat
sender, entity name, …) rather than reimplemented per Node.
_Avoid_: Filter, search, query, "contains" (as the concept name)

**Swatch Chip**:
A `swatch`-widget Control's on-Pin box (e.g. `color`'s `{r,g,b,a}` table): a checker-backed
color-filled rect in the same value column a scalar Control Box occupies, discriminated by
`kind == "swatch"` in `geom.controls` the way a Control Band's sub-rects are discriminated by
`kind`. Unlike every other Control kind, clicking it does not mount a Control Editor — it
opens the Color Popup instead.
_Avoid_: Color box, preview, control box (that's the scalar/composite kind)

**Color Popup**:
The Canvas-drawn, click-to-open picker for a `swatch` Control (`ui/color_popup.lua`): an
SV field + hue strip (drag), a hex8 field (the Control Spec's `format`/`parse`, mounted as a
transient real `ui.InputField` exactly like a Control Editor), and R/G/B/A drag rows. Modal
like the Palette — drawn on the same editor-chrome Canvas, in the same fixed screen-space,
clamped inside the Viewport, and dismissed by an outside click / Esc / re-click / its own ✕ —
but unlike the Palette its SV/hue/channel rows are themselves draggable, not single-shot
picks. Deliberately transient editor state, not part of any Node's `geom.controls`.
_Avoid_: Color picker dialog, swatch popup, panel (in prose — that's the Palette's own word)

**Test Button**:
A small ▶ button drawn between an exec-in Pin's glyph and its label (`geom.testButtons`, one
per exec-in Pin, gated on `CONTROL_MIN_ZOOM` like a Control Box). Clicking it fires that exec
input directly through the engine (`Graph:FireInput`), running the Node's `run` as if a wire
had fired into that Pin — a live fire whose real side effects happen, for testing a Node in
isolation without wiring a Trigger.
_Avoid_: Run button, play button, trigger button

## Node domain

**Chat Trigger**:
A Trigger Node that fires on the client's `ChatMessage` event. There are two, split by who
authored the line: the **Game Message** trigger (system/engine/broadcast/examine lines) and
the **Player Chat** trigger (lines a player typed — public, private, friends/clan/group).
Each strips formatting tags from the incoming line before matching, so a Matcher never sees
`<col=…>` markup, and exposes only the Chat Type Groups relevant to it.
_Avoid_: Chat node, message node, chat listener

**Chat Type Group**:
A Watchdog-curated, named grouping of raw engine `ChatType` ids exposed as one choice in a
Chat Trigger's type dropdown (e.g. *Examine* = `OBJ_EXAMINE`/`NPC_EXAMINE`/`LOC_EXAMINE`;
*Private (Received)* = the incoming private + quickchat ids). Deliberately **not** 1:1 with
the client's `ChatType` enum — a simplified, useful vocabulary that hides noise types and
folds quick-chat into its parent channel. A Chat Trigger exposes only its own Groups, and
**Any** means the union of that Trigger's Groups, never the whole enum.
_Avoid_: Chat category, chat kind, chat class; "chat type" (that is the raw engine `ChatType`)

**Webhook** (`action.webhook`):
An Action Node that POSTs a JSON body to an HTTP endpoint when exec'd. The endpoint is a
**Base** (chosen from the manifest's `Plugin.urls` allowlist — the client refuses any URL not
declared at build time) plus a **Path**; the node is POST-only. Its body is a JSON template
carrying **Injection Tokens**, and it is the graph's first **async** node — it does not
complete inside the firing sweep but continues later, from the HTTP completion callback.
_Avoid_: HTTP node, request node, "URL node" (the URL is not free-form — see Base);
GET/PUT/DELETE (the node is POST-only and the API only exposes Get/Post)

**Base** (webhook):
The allowlisted host a Webhook targets, selected from the keys of `Plugin.urls` (declared in
`plugin.json`). The client only permits requests to bases declared in the manifest, so a
Webhook can reach any *path* under an allowlisted host but can never invent a new host without
a redeploy. This is a hard client constraint, not a Watchdog choice.
_Avoid_: URL, endpoint (those include the Path); domain

**Injection Token**:
A `{{N}}` placeholder in a Webhook's body template (`{{1}}`, `{{2}}`, `{{3}}`) that is replaced
at send time by the value wired into the node's positional data-input pin `N`. Because the
body is JSON-first, injected values are **JSON-escaped** before substitution, so arbitrary text
(a chat line with quotes or newlines) can't break the payload. The token set is fixed at three
because the engine has no dynamic pins.
_Avoid_: variable, placeholder, `$1`/`%1%` (the syntax is `{{N}}`); "merge field"

**Async Node**:
A node whose downstream exec pins do **not** fire during the synchronous trigger→…→node sweep,
but later, from an external callback. The Webhook is the first: its firing `run` starts the
POST and returns, and `On Success` / `On Failure` fire when the HTTP completion callback
arrives. Legal because the engine's `ctx` closure stays valid after `run` returns and the
client is single-threaded, so a deferred `ctx:Fire` simply propagates downstream at callback
time. See [ADR-0006](docs/adr/0006-async-continuation-node.md).
_Avoid_: deferred node, callback node, promise; conflating with a Pure Node (that is about
*pull* timing, not *push* timing)

## Testing node types

Node behavior (a node type's `run`) is verified against a **real** `LibNodeGraph` Graph —
`AddNode`, set Controls, drive with `Graph:FireInput(id, execPin)` / `Graph:Fire(id)`, assert
on the observable effect — **never** a hand-built `ctx` table, which is blind to divergence
from the real engine's run context. See `tests/test_screen_marker.lua` /
`tests/test_infobox_node.lua`, and [LibNodeGraph's CONTEXT.md](../LibNodeGraph/CONTEXT.md#the-runctx-contract-and-how-its-enforced)
for the full rationale and the two other guards (the runtime field guard + LuaLS typing).
