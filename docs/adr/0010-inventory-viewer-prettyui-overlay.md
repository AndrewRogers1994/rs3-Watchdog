# Inventory Viewer is a persistent PrettyUI overlay on a Canvas node

ADR-0004 keeps Control editing transient so the Editor stays a pan/zoom Canvas
(ADR-0001). Associated-object item icons cannot be drawn with `Canvas:AddSprite`; they
need `ui.Sprite:SetAssociatedObject`, which PrettyUI's ItemGrid already wraps.

Inventory Viewer is the exception: a 4×7 ItemGrid lives on `overlayParent` above the
Capture Layer for the life of the node (empty chrome before the first latch). It does
not scale with the View; Node Body Graph-space size is derived from that fixed screen
rectangle each frame so the hole tracks the overlay. Native ItemSlot tooltips and
windowed wheel-scroll work because the grid eats that rectangle.

0004 still holds for Controls. Do not grow a persistent component tree for pin editing.
