# Compare takes numbers

Compare's two inputs are numbers. An unconnected input stores 0, so the editor can show the number control. Equality and the ordered operations share that operand type. The hidden Equals and Not Equals types still load saved graphs that compare other values, and they stay off the palette. Saved Compare graphs are not rewritten.

## Considered options

Leave the inputs as `any`. Rejected. An `any` pin has no number control, and an ordered comparison of mixed values raises at run time.
