# Issue tracker

This repo tracks work in **GitHub Issues** on `adamk33n3r/rs3-Watchdog` (via the `gh` CLI).
The engineering skills (`to-tickets`, `triage`, `to-spec`, `qa`, `wayfinder`, …) read from and
write to it there.

- Create: `gh issue create --title … --body … [--label …]`
- List / view: `gh issue list`, `gh issue view <n> --json …`
- Close with a resolution: `gh issue comment <n> --body …` then `gh issue close <n>`
- Assign (claim): `gh issue edit <n> --add-assignee @me`

PRs as a request surface: **off**. External PRs are not part of the triage queue.

## Wayfinding operations

How this repo expresses the pieces of a `wayfinder` map on GitHub Issues.

- **Map** — a normal issue labelled `wayfinder:map`. Its body is the low-resolution index
  (Destination, Notes, Decisions so far, Not yet specified, Out of scope).
- **Ticket** — a child issue linked to the map as a native **sub-issue**
  (`POST /repos/{owner}/{repo}/issues/{map}/sub_issues` with the child's database `id`).
  Each ticket carries exactly one `wayfinder:<type>` label: `research`, `prototype`,
  `grilling`, or `task`.
- **Blocking** — native issue dependencies where available
  (`POST /repos/{owner}/{repo}/issues/{blocked}/dependencies/blocked_by`), *plus* a
  human-readable `> Blocked by #N — <title>` line at the top of the blocked ticket's body so
  the relationship is legible even without the dependency graph. The body line is the
  source of truth for the fallback; the native dependency renders the frontier visually.
- **Claim** — assign the ticket to the map's driver (`--add-assignee @me`) before any work.
  An open, unassigned ticket is unclaimed.
- **Frontier query** — open sub-issues of the map that are unassigned and have no open
  blocker:
  `gh issue list --label wayfinder:grilling --state open` (and the other type labels),
  cross-checked against each ticket's `> Blocked by` lines.

## Labels

- `wayfinder:map` — the map issue
- `wayfinder:grilling`, `wayfinder:prototype`, `wayfinder:research`, `wayfinder:task` — ticket types
