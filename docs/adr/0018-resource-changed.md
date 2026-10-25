# Resource Changed is one trigger

Resource Changed is one trigger. A dropdown selects life points, prayer points, summoning points, adrenaline, or run energy. It samples the pool once without firing, then fires when that pool's current value changes. It outputs the current value, the maximum, and the previous current value. Changing the dropdown leaves those outputs in place. Prayer and summoning maximums are the skill's gameplay level times 10. Adrenaline's maximum is 100, and its current value can rise above that. Run energy's current value is the player percentage, and its maximum is 100. The trigger also subscribes to run-energy transmit, and that event drives the trigger only while run energy is selected. Life points are the life-point pool, not the Hitpoints skill.

## Considered options

A life-points trigger and a prayer trigger. Rejected. Summoning points, adrenaline, and run energy share the same outputs.

Stat Changed. Rejected. A hit does not move the Hitpoints skill, and prayer points are not the Prayer skill.

Reading run energy from a player var so the trigger could stay on one event. Rejected. The published var list has no current-run-energy percentage. The run-toggle var is a switch, not the percentage.

## Consequences

The low life points and low prayer starter presets use this trigger. Summoning points, adrenaline, and run energy are selectable and are not starter presets. The summoning special-move bar is not one of the pools.
