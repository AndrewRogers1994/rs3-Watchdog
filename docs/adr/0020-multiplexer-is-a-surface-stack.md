# Multiplexer is a surface stack

Save as preset destroyed its window on every step and mounted a new one in the center of the editor, so a drag was lost. The Multiplexer already keeps one window mounted and shows only the top surface. It also created the shell window, the overlay, the resize handle, and the object-capture hide, which left a dialog unable to use that stack.

A Multiplexer is a stack of surfaces in a window it is given. Only the top surface is visible. The window stays mounted across push and pop. The shell keeps the window, the overlay, the resize handle, and object-capture hide, and it still swaps the Manager and the Editor with one Multiplexer. Save as preset keeps one dialog window and stacks its steps on a second Multiplexer.

## Considered options

Remount the dialog on each step. Rejected. The new window opens centered, which discards the drag.

Clear the body and refill it. Rejected. Push and pop are the step changes, and the window has to stay mounted either way.

## Consequences

Shell behavior that used to live on the Multiplexer stays with the shell. A dialog can be given the same stack. The top surface still supplies the shell window title. The dialog uses that same title update for Save as preset, Save as preset - Choose a node, and Save as preset - Choose a pin.
