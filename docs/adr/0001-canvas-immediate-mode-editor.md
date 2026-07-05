# The graph editor is drawn in immediate mode on a single ui.Canvas

The whole editor — every Node Body, Header, Pin Glyph, and Wire — is drawn onto one
`ui.Canvas`, `Clear()`-ed and fully rebuilt each `Event.Draw` frame through a View
(pan + zoom) transform the plugin owns. Nodes are *not* built from real interactive
components (`ui.Panel`/`ui.Button`/`ui.InputField`). We chose this because Canvas is the
only client primitive whose draw coordinates the plugin fully controls, which is what makes
continuous pan and zoom possible: real components position in fixed interface units with no
scale transform, so a component-per-node editor cannot zoom without recomputing every
component's pos/size/font each frame, fighting the layout engine.

## Consequences

Canvas drawables are inert, so the editor gets no interactivity for free. All input arrives
through a single full-screen **Capture Layer** component (the only real interactive
component) forwarding `ONDRAG`/`ONSCROLLWHEEL`/`ONCLICK`/`ONRELEASE`, and every hit-test
against Nodes, Pins, and Wires is done manually from `Mouse.GetPosition()` in Graph-space —
the pattern `DevTools/overlay.lua` already uses for its gizmo. Canvas offers no rounded
rectangle, no circle, and no bezier: Node Bodies are square-cornered, Data Pin Glyphs are
squares/diamonds, and Wires are bezier curves we tessellate into straight `AddLine`
segments ourselves. There is also no text caret, so inline Control editing is deferred until
a text-input workaround is designed (out of the first milestone's scope).
