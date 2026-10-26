# Alert Manager × PrettyUI — findings and migration design

**Status:** Approved approach (Option A hybrid).  
**Related:** [ADR-0007](adr/0007-alert-manager-native-ui-panel.md), [#92](https://github.com/adamk33n3r/rs3-Watchdog/issues/92), [#93](https://github.com/adamk33n3r/rs3-Watchdog/issues/93).  
**PrettyUI reference:** sibling plugin `../prettyui/` — local docs at `prettyui/PrettyUI Documentation.html`, published at https://prettyui.j3.gg/.

## Summary

Watchdog already depends on PrettyUI for **window chrome** (`prettyui.Window` via `ui/multiplexer.lua`). The Alert Manager (`ui/manager.lua`) still builds **all content** with native `ui.*` on a `ui.Panel`.

After reviewing PrettyUI v0.5.x, the recommended path is **Option A (hybrid)**:

- **Migrate to PrettyUI:** scope tabs, toolbar buttons, row action icons, rename field, bulk-action bar chrome.
- **Keep native `ui.Panel` rows:** hierarchical tree, enable toggle, selection checkboxes (#93), drag gestures (#92), drop-target math.

PrettyUI has **no tree widget**, **no row drag**, and **no inline table-row checkbox** — so ADR-0007's rationale for native panels on the tree strip still holds. PrettyUI improves chrome and form controls without blocking #92/#93.

---

## Current architecture

```
prettyui.Window (Multiplexer)
└── manager.lua content (mux:Content())
    ├── scope tab bar          ← ui.Button, hand-positioned
    ├── + Alert / + Group      ← ui.Button, right-aligned on tab row
    └── treePanel (ui.Panel)   ← vertical scroll; one horizontal ui.Panel per VisibleRow
        └── [enable][name][ren][del] per row
```

**Pure logic** (scope resolution, `VisibleRows()`, expand state, mutation reporting) is headless-tested in `tests/test_manager.lua`. **Render** is client-only, full teardown/rebuild on signature change.

---

## PrettyUI integration (consumer plugins)

| Topic | Detail |
|-------|--------|
| Dependency | `"prettyui"` in `plugin.json` `requiredDependencies` (already present) |
| Access | Global `prettyui` table — no `require` |
| Content hosts | `Window`, `SimpleView`, `Panel`, tab pages (`Tabs:GetPage(n)`), `CollapseButton` expanded region |
| Layout | `Add…` methods on content hosts — vertical flow with `inline = true` for horizontal groups |
| Styling | RS3 sprites via `id.Sprite`; `TextField` / `ComboBox` set stylesheets automatically |

### Exported components (relevant subset)

| Export | Use in Manager |
|--------|----------------|
| `Tabs` | Scope tab bar (Global / character) |
| `FancyButton` | + Alert, + Group, bulk actions (#93) |
| `SpriteButton` | PENCIL (rename), TRASH (delete), EXPORT (#93) |
| `TextField` | Inline rename (replaces overlay `ui.InputField`) |
| `SimpleButton` | Row name / open affordance (optional) |
| `Divider`, `Text`, `Title` | Bulk bar separator, empty state |
| `CollapseButton` | **Deferred** — poor fit for #92/#93 (see below) |
| `List` | **Rejected** — flat only, no rich rows (ADR-0007) |
| `CheckboxButton` | **Rejected** for per-row selection — vertical choice group, not a column |

### SpriteButton names (from `prettyui/src/core/sprites.lua`)

`PENCIL`, `TRASH`, `CROSS`, `PLUS`, `EXPORT`, `IMPORT`, `EYE`, `HIDE`, `ERASER`, `BACK`, …

---

## Control mapping

| Manager control | Today | PrettyUI | Notes |
|-----------------|-------|----------|-------|
| Scope tabs | `ui.Button` + `[label]` active marker | **`Tabs`** + `onChange` → `SetActiveScope` | Tab pages have built-in scroll |
| + Alert / + Group | `ui.Button` on tab row | **`FancyButton`** on active tab page header (`inline = true`) | `variant = "positive"` for create actions |
| Tree scroll | `ui.Panel` vertical | Tab page scroll **or** nest `ui.Panel` inside `GetPage(active)` | Nesting native panel inside tab page is lowest churn for Phase 1 |
| Group hierarchy | Flat rows + `RowLabel()` indent/chevron | **Keep native rows** | `CollapseButton` optional prototype only |
| Enable | `ui.Check` per row | **Keep `ui.Check`** | `CheckboxButton` is wrong shape; EYE/HIDE sprite optional later |
| Selection (#93) | — | **Keep native `ui.Check`** (2nd column) | Antichain logic stays pure |
| Rename | Overlay `ui.InputField` | **`TextField`** (`onSubmit`) | May still need absolute position over name column |
| Delete | ASCII `del` / `OK N?` | **`SpriteButton` TRASH** + confirm state | Two-step confirm logic unchanged |
| Open alert | Double-click name `ui.Button` | Keep gesture on native name button **or** add explicit Open | Double-click timing stays in pure logic |
| Bulk bar (#93) | — | **`FancyButton` row** + `Divider` | Delete / New group / Move / Export |
| Drag (#92) | — | — | `dragConfig` on native row `ui.Panel` |
| Cross-scope drop (#92) | — | **`Tabs` tab `hit` layers** as drop targets | Custom `ONDRAGCOMPLETE` wiring on inactive tabs |

---

## Options considered

### Option A — Chrome + controls only (**chosen**)

PrettyUI for form-like UI; native horizontal row `ui.Panel`s for the tree strip.

**Pros:** Preserves ADR-0007 drag and rich rows; #92/#93 logic stays on flat `VisibleRows()`; incremental risk.  
**Cons:** Two UI paradigms; glue between Tabs lifecycle and row rebuild.

### Option B — CollapseButton hierarchy

One `CollapseButton` per group; alerts as buttons/list inside expanded content.

**Pros:** Clear visual grouping.  
**Cons:** No sibling reorder (#92); shift-range (#93) fights reflow; deep nesting awkward; per-row enable/actions still need native children.

### Option C — Tabs + flat List

Flatten tree to indented list entries.

**Rejected:** Loses inline per-row controls; contradicts #78/#82 and ADR-0007.

---

## #92 and #93 — what stays custom

### #92 — Drag reorder / nest / move-to-scope

| Requirement | Owner |
|-------------|-------|
| Row drag gesture | Native `ui.Panel.dragConfig` + `ONDRAG` / `ONDRAGCOMPLETE` |
| Drop between siblings | Hit-test flattened `VisibleRows()` rects |
| Drop on group middle band | Row band detection on group rows |
| Drop on inactive scope tab | `Tabs` tab `hit` `ui.Layer` + Store cross-bucket move |
| Insert-at-index / cross-bucket API | `store.lua` extensions |
| Id-preserving move, append at dest root | Store + runtime sync (no `Enter` replay) |

PrettyUI does not expose drag on `List` or `CollapseButton`.

### #93 — Multi-select + bulk actions

| Requirement | Owner |
|-------------|-------|
| Selection checkbox column | Native `ui.Check` (separate from enable) |
| Shift-click range | Pure logic on `VisibleRows()` order |
| Group-as-unit antichain | Pure logic in `manager.lua` |
| Bulk-action bar | PrettyUI `FancyButton` row |
| Selection lifecycle (scope switch, collapse, hide) | Pure logic + hooks |
| Esc clears selection | Manager / nav owner |

---

## Target layout (Option A)

```
prettyui.Window (Multiplexer, unchanged)
└── contentParent (mux:Content)
    ├── Tabs (Global | Character) — pages left empty
    │   └── FancyButton + Alert / + Group on tabs.root (right-aligned in tab strip)
    ├── [when selection #93] bulk bar
    └── native ui.Panel tree (sibling below TAB_BASELINE ≈ 42)
        └── per row: [enable Check][select Check #93][name Button][PENCIL][TRASH]
```

**Do not** nest the tree inside `Tabs:GetPage().content` — PrettyUI scroll content height
only grows for flow children, so an absolute-positioned Panel there was clipped (rows invisible).
**Do not** call `SpriteButton:Destroy` and then Destroy the parent row Panel — double-frees
native components after the window has been `Show`n and freezes/crashes on reload.

---

## Implementation phases

| Phase | Scope | Tracker |
|-------|-------|---------|
| **1** | PrettyUI tabs, toolbar, sprite actions, TextField rename | Implementation plan (Phase 1 only) |
| **2** | Selection column + antichain + bulk bar | [#93](https://github.com/adamk33n3r/rs3-Watchdog/issues/93) |
| **3** | Row drag + drop targets + Store move APIs | [#92](https://github.com/adamk33n3r/rs3-Watchdog/issues/92) |

Run Phase 1 first; #93 and #92 are separate tasks with implementation notes on their issues.

---

## Verification

After each phase:

```bash
lua tests/run.lua
lua-language-server --check d:/dev/rs3/Watchdog --checklevel=Warning
# or: ../.vscode/typecheck.sh Watchdog
```

In-client: persistentdb mirror pattern per AGENTS.md; save → reload plugin → exercise Manager.

---

## References

- `ui/manager.lua` — Manager pure + render halves
- `ui/multiplexer.lua` — PrettyUI window host
- `docs/adr/0007-alert-manager-native-ui-panel.md` — native panel decision (still valid for tree strip)
- `prettyui/src/tabs.lua`, `collapse_button.lua`, `text_field.lua`, `sprite_button.lua`, `list.lua`
- `prettyui/tests/tabs_test.lua`, `text_field_test.lua`, `list_test.lua` — usage examples
