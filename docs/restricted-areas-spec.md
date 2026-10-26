# Watchdog restricted areas

## Problem Statement

While the local player is somewhere Jagex has marked Restricted, Watchdog should not react to nearby entity spawns or to game messages. The player should be able to see that this is happening on the panel they keep open while playing. Everywhere else, Watchdog should keep working. RestrictedAreas is a required dependency.

## Solution

Watchdog asks RestrictedAreas. While that plugin reports Restricted, the Entity Spawn trigger and the Game Message trigger do not Fire. The content panel shows "In Restricted Area" in red under its Toggle button, and under that a description of what staying quiet means. Watchdog does not decide the areas itself. RestrictedAreas is a required dependency, so Watchdog calls that global directly.

## User Stories

1. As a player with RestrictedAreas installed, I want Entity Spawn not to Fire while I am Restricted, so that spawn alerts stay quiet there.
2. As a player with RestrictedAreas installed, I want the Game Message trigger not to Fire while I am Restricted, so that game-message alerts stay quiet there.
3. As a player, I want Player Chat, Location, Inventory, Skill, and Logic to keep Firing while I am Restricted, so that only those two triggers go quiet.
4. As a player, I want the Game Message action to still insert a local line while I am Restricted, so that sending a line is not the same thing as the trigger.
5. As a player, I want a toast or marker that is already showing to keep showing when I become Restricted, so that only new fires are suppressed.
6. As an alert author, I want Entity Spawn and the Game Message trigger to stay placeable while I am Restricted, so that they do not become Unavailable.
7. As a player, I want an alert's armed bucket and enabled-chain to stay the only general fire rule, so that Restricted does not grow a third global gate.
8. As a player, I want Watchdog to call RestrictedAreas directly, so that there is no separate missing-plugin answer.
9. As a player, I want RestrictedAreas declared as a required dependency, so that Watchdog does not load without it.
10. As a player, I want the content panel's button to stay labeled Toggle, so that the shell toggle does not change meaning.
11. As a player who is Restricted, I want a line under Toggle that reads In Restricted Area in red, and a description under it that spawn and game-message alerts stay quiet while other alerts still run, so that I can see what that means on the panel beside my inventory.
12. As a player who is not Restricted, I want that line gone, so that the panel is only the Toggle button.
13. As a player who opens the content panel while already Restricted, I want the line shown immediately, so that I do not have to leave and re-enter the area.
14. As a player who walks into a Restricted place with the panel open, I want the line to appear, so that the panel tracks me.
15. As a player who walks out with the panel open, I want the line to disappear.
16. As a player, I want the line to lag the two triggers by at most one logic tick, so that the panel and the triggers still agree.
17. As a player, I want the line to say In Restricted Area in red and not why, so that Blacklist versus Instance stays off the panel.
18. As a player whose tile cannot be read, I want those two triggers quiet and the line shown, because RestrictedAreas reports Restricted.
19. As a player who moves from one Restricted Area to another without becoming unrestricted, I want the line to stay, with no flicker off.
20. As a player, I want the Settings layer left unchanged, so that permissions stay where they are and the status lives on the content panel.
21. As Watchdog, when RestrictedAreas reloads and comes back, I want to read `IsRestricted()` again and subscribe again, so that the line matches the new instance of that plugin.
22. As Watchdog, I want to drop the Restricted change listener when the content panel subscription ends, so that a closed panel does not keep that plugin ticking.
23. As Watchdog, on plugin shutdown I want the client to destroy the content panel, and I want Watchdog not to destroy that panel itself.
24. As an alert author, I want a graph that already contains those triggers to keep them, so that Restricted does not delete or unregister node types.

## Implementation Decisions

- Declare RestrictedAreas as a required dependency. The global name is `RestrictedAreas`.
- Do not `require` the other plugin. Call the global. In tests, install a fake global the way the Shortest Path tests install `shortestpath`.
- Do not reimplement the predicate. `IsRestricted()` is the answer. True means Restricted. Call `RestrictedAreas` directly; do not branch on the global being missing.
- Entity Spawn and the Game Message trigger consult `IsRestricted()` when they handle an event. They do not subscribe. While the answer is true they do not Fire. Their node types stay registered and placeable.
- The armed-bucket and enabled-chain fire rule is unchanged. This silence is those two triggers' own rule.
- The content panel keeps one button labeled Toggle that performs the shell toggle. While Restricted, a line under that button reads In Restricted Area in red, and the line under that reads "Spawn and game-message alerts stay quiet. Other alerts still run." Otherwise the panel is only the button.
- When the panel is shown, call `IsRestricted()` and paint from that. Then `Subscribe` under one Watchdog-owned name. On a Restricted change, paint the new boolean. `Unsubscribe` that name when the panel subscription ends and on shutdown.
- On optional-dependency change for RestrictedAreas, read `IsRestricted()` and subscribe again. Call `Unsubscribe` on `RestrictedAreas` when the panel subscription ends. Do not keep a second reference to that table.
- On plugin shutdown, unsubscribe the listener and do not destroy the hub content panel. The client tears that panel down, and destroying it here crashes.
- The line may update on the logic tick while the triggers have already seen the new answer. That lag is accepted.

## Testing Decisions

- A good test asserts observable firing and observable panel text. It does not assert how a rectangle was computed, and it does not load the RestrictedAreas plugin.
- Trigger tests go through the real dispatcher and a fake event source, the way Entity Spawn and Game Message are tested today. With a fake global whose `IsRestricted()` is true, neither trigger Fires. With it false, they Fire as they do now. A sibling trigger, such as Player Chat, still Fires while `IsRestricted()` is true. The Game Message action still inserts a line.
- Content-panel tests drive the panel fill and the subscribed callback. On fill while the fake returns true, the line reads In Restricted Area in red, and the description under it reads "Spawn and game-message alerts stay quiet. Other alerts still run." On fill while it returns false, there is no such line and the button still reads Toggle. A later callback of true shows the line. A later callback of false removes it. Unsubscribe happens when the panel subscription is torn down.
- Prior art for the optional global is the Shortest Path tests, including `OptionalDependencyChanged`. Prior art for the triggers is their existing dispatcher suites. The content panel has no suite yet. This spec adds one at the panel's text, not a new fire predicate in the runtime.

## Out of Scope

- Implementing RestrictedAreas, editing its lists, or copying its predicate into Watchdog.
- Authoring Jagex coordinates, and confirming the source-tile return value in the client.
- Silencing any trigger other than Entity Spawn and the Game Message trigger.
- Changing the Game Message action, already-showing effects, the Settings layer, or the Toggle label.
- Making the nodes Unavailable.
- A reason on the line, a toast when Restricted begins, and a change to the armed-bucket fire rule.

## Further Notes

- Vocabulary for Restricted, the content layer, and the fire predicate is in Watchdog's glossary. The predicate decision itself belongs to RestrictedAreas and is closed.
- Call `IsRestricted()`, `Subscribe(name, callback)`, and `Unsubscribe(name)` only. The callback receives the new boolean. Subscribing does not replay, which is why the panel reads `IsRestricted()` when it is shown.
- Do not edit the RestrictedAreas plugin from this work.
