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
The Watchdog-owned mapping (`ui/controls.lua`) from an engine Type Tag to how its Control is
rendered and edited: a widget kind (`number` / `text` / `enum`) plus, for an enum, its
choices. Parallel to Type Color, and for the same reason — the engine is deliberately
tag-agnostic, so presentation lives here (ADR-0004). Tags with no spec (coord, any) get no
Control Editor.
_Avoid_: Type metadata, schema, control config
