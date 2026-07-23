# Player identity & login-lifecycle API (wayfinder ticket #74)

## The question

What does the RS3 (BETA) client-side Lua plugin API expose for:

- **(a)** reading the currently logged-in player's **display name**, and
- **(b)** **login / logout / character-switch / world-hop lifecycle events**,

so a plugin can scope behavior per player and re-evaluate when the active character changes?

We need exact global/object names, method signatures, `Event.<Channel>` names + callback
payload shapes, and the caveats around availability, world-hop vs account switch, and a
reliable logged-in signal.

Sources consulted, in priority order:

1. Authoritative docs site — https://d1s24e1pcksyf8.cloudfront.net/ (accessible; fetched
   the `Player`, `PlayerEntity`, and `Events` pages).
2. Local scraped stubs at `D:\dev\rs3\runescape-api-stubs` (cross-check only).
3. Existing `Watchdog` plugin code for prior usage patterns.

**The docs site was accessible.** Every claim below is cited to the docs URL and
corroborated against the local stub where one exists; no discrepancies were found.

---

## (a) Reading the current player's display name

There is a **`Player`** global — a static table holding data for the *currently
logged-in player character*.

- `Player.IsAvailable() -> Boolean` — "Returns whether a player character is logged in
  and exists in a game world." This is the gate: it is `false` on the login screen / lobby
  and `true` only once in-world.
  (docs: https://d1s24e1pcksyf8.cloudfront.net/game/player.html; stub:
  `runescape-api-stubs/generated/game/player.lua:41-42`)
- `Player.GetEntity() -> PlayerEntity` — returns the local player's entity object.
  (docs: game/player.html; stub: `generated/game/player.lua:79`)

**The display name is not a method on `Player` directly.** `Player` exposes no
`GetName`/`GetDisplayName`/`GetUsername`. You read the name off the **`PlayerEntity`**
returned by `Player.GetEntity()`:

- `PlayerEntity.displayName : String` — "The display name of this entity." (read-only)
  (docs: https://d1s24e1pcksyf8.cloudfront.net/game/entity/playerentity.html; stub:
  `generated/game/entity/playerentity.lua:6`)

Other `PlayerEntity` fields (all read-only): `isValid : Boolean`, `uid : Integer`,
`position : Vector3`, `coordGrid : CoordGrid`, `facing : Integer`,
`facingTarget : Integer`. It is a "Proxy usertype" — safe to copy but **not** to persist;
check `isValid` before reading fields, and dispose when invalid. There is **no
constructor**. (docs: playerentity.html)

So the read pattern is:

```lua
local name
if Player.IsAvailable() then
    local e = Player.GetEntity()
    if e ~= nil and e.isValid then
        name = e.displayName
    end
end
```

Notes on identity granularity:

- The only identity string exposed is the **character display name** (`displayName`).
  There is **no documented API for the account/login username** as a runtime property.
  The `*_USERNAME` entries in the stubs (e.g. `LOGINSCREEN_USERNAME` = VarClient 2576,
  `CREATE_DISPLAYNAME` = 2563 in `runescape-api-stubs/consts/VarClient.lua` /
  `csvs/VarClient.csv`) are **login-form / account-creation UI fields**, not a reliable
  "who is currently playing" signal — do not key player scope on them.
- `Watchdog` already relies on `PlayerEntity.displayName` for *nearby* players in
  `nodes/triggers/entity_spawn.lua:75` (`entity.displayName`), so the field name is
  battle-tested in this repo — but that is the name of an arbitrary nearby player entity,
  **not** necessarily the local player. For the local player you must go through
  `Player.GetEntity()`.

### Caveat: is the name available before full login completes?

No. `Player.GetEntity().displayName` is only meaningful once `Player.IsAvailable()` is
`true`, i.e. the character exists in a game world (GameState `GAME`, see below). On the
login screen, lobby, during loading, or mid-reconnect, `Player.IsAvailable()` is `false`
and there is no local `PlayerEntity` to read a name from. Always gate on `IsAvailable()`
(and `entity.isValid`) rather than assuming a name is present.

---

## (b) Login / logout / character-switch / world-hop events

The single documented lifecycle channel is **`Event.GameStateChanged`**.

- **Channel:** `Event.GameStateChanged.Subscribe(name, fn)`
- **Payload fields:** `oldState` and `newState` — each a **`GameState`** enum value.
  Docs describe it as fired "when the client's internal state changes."
  (docs: https://d1s24e1pcksyf8.cloudfront.net/core/events.html; stub:
  `generated/core/events.lua:195-200`)
- The docs example converts the numeric states with `GameState.FromID(...)`:

  ```lua
  "Game state changed: " .. GameState.FromID(e.oldState)
      .. " -> " .. GameState.FromID(e.newState)
  ```

### The `GameState` enum

(docs: core/events.html; stub: `runescape-api-stubs/generated/core/events.lua:86-99`)

| Name                | Value | Meaning                                   |
|---------------------|-------|-------------------------------------------|
| `BOOT`              | 0     | Client boot phase                         |
| `INIT`              | 1     | Initialization                            |
| `LOGINSCREEN`       | 10    | Login screen (logged out)                 |
| `LOBBY`             | 20    | Lobby / character selection               |
| `ACCOUNT_CREATE`    | 23    | Account-creation screen                   |
| `GAME`              | 30    | In-game / playing (logged in, in world)   |
| `RECONNECTING`      | 35    | Reconnection attempt in progress          |
| `RECONNECTING_FULL` | 36    | Full reconnection sequence                |
| `SWITCH_WORLD`      | 37    | World switching / hopping                 |
| `LOADING`           | 40    | Loading screen                            |

### How the lifecycle maps to the ticket's four cases

- **Login (reliable "logged in" signal):** a transition to `newState == GameState.GAME`
  (30). This is the moment `Player.IsAvailable()` flips to `true` and a local
  `PlayerEntity` (hence `displayName`) becomes readable. Treat `newState == GAME` as
  "logged in / re-evaluate identity."
- **Logout ("logged out" signal):** a transition *away* from `GAME` to `LOGINSCREEN` (10)
  or `LOBBY` (20). At that point `Player.IsAvailable()` is `false`.
- **World hop:** `SWITCH_WORLD` (37) — an explicit state the client passes through when
  hopping worlds. There is also a lower-level `Event.ServerLogic` (fires when the client
  finishes processing a server packet) but that is not a hop signal; `SWITCH_WORLD` is the
  one to watch.
- **Character / account switch:** **there is no dedicated event.** The API exposes no
  "account changed" or "character switched" channel. Detect it yourself by capturing
  `displayName` on each `GAME` transition and comparing to the previously captured name.

There is **no** `Event.Login` / `Event.Logout` / `Event.WorldHop` / `Event.CharacterSwitch`
channel in the docs — `GameStateChanged` (plus `Player.IsAvailable()`) is the whole story.
If a name is not in the docs, it is stated here as absent rather than guessed.

### Caveat: world-hop vs actual character/account switch

- A **world hop keeps the same character**, so `displayName` is **unchanged** across a
  `SWITCH_WORLD` → `GAME` cycle. (The docs do not explicitly assert this in prose; it
  follows from a hop being the same logged-in account. Flagged as inference, not a quoted
  guarantee.)
- An **actual character/account switch** requires a full logout to `LOGINSCREEN`/`LOBBY`
  and a fresh login back to `GAME`, at which point `displayName` **may differ**. Because no
  event distinguishes "same account" from "different account," the only robust
  discriminator is the display name itself captured at each `GAME` entry.

### Caveat: reconnects and transient states

`RECONNECTING` (35) / `RECONNECTING_FULL` (36) are transient — the session usually returns
to `GAME` with the *same* character. Don't treat a reconnect as a logout+login for
scoping; re-confirm identity by comparing `displayName` on return to `GAME` rather than
tearing down per-player state on every non-`GAME` blip.

---

## Recommendation for scoping

- **Key player-scope on `PlayerEntity.displayName`** read via
  `Player.GetEntity().displayName`, gated behind `Player.IsAvailable()` and
  `entity.isValid`. It is the only runtime identity string the API exposes for the local
  player. (There is no account-username API; ignore the `*_USERNAME` VarClient fields.)
- **Re-evaluate on `Event.GameStateChanged`:** subscribe once, and whenever
  `newState == GameState.GAME`, read the current `displayName` and compare it to the last
  stored one:
  - name differs / was empty → treat as a **new active character**: swap/reload
    per-player scope.
  - name identical → same character returning from a hop/reconnect: keep existing scope.
  On a transition *away from* `GAME` (to `LOGINSCREEN`/`LOBBY`), mark "logged out" and
  clear any live per-player state, but persist per-name data keyed by the last known
  display name so it can be restored on next login.
- **Do not read identity eagerly at plugin load** — a plugin can load on the login screen
  where `Player.IsAvailable()` is `false`. Wait for the first `GAME` transition (or poll
  `IsAvailable()` on `Event.Logic` until true) before capturing a name.

### One-shot capture sketch

```lua
local currentName -- nil while logged out

local function readLocalName()
    if not Player.IsAvailable() then return nil end
    local e = Player.GetEntity()
    if e == nil or not e.isValid then return nil end
    return e.displayName
end

Event.GameStateChanged.Subscribe("watchdog.identity", function(ev)
    if ev.newState == GameState.GAME then
        local name = readLocalName()
        if name ~= nil and name ~= currentName then
            currentName = name
            -- (re)bind per-player scope for `name`
        end
    elseif ev.newState == GameState.LOGINSCREEN
        or ev.newState == GameState.LOBBY then
        currentName = nil
        -- logged out: tear down live scope, keep persisted per-name data
    end
    -- SWITCH_WORLD / RECONNECTING* are ignored; identity is re-checked on the
    -- following GAME transition.
end)
```

(`Player`/`Player.IsAvailable`/`Player.GetEntity`: game/player.html;
`PlayerEntity.displayName`/`isValid`: game/entity/playerentity.html;
`GameStateChanged` + `GameState` enum: core/events.html.)
