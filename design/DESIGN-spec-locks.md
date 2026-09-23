# Design — Spec-Level Concurrency Control (Spec Locks)

> **Status:** **Implemented 2026-09-19; two-state revision 2026-09-23** (design intent vs hold, after review — see D7). Design record for a change to the **SpecHub framework itself**, not to the platform it specifies (see `DESIGN-observability-metrics.md` §1 for why such records live in `design/`). The code is the contract — `scripts/lock.sh`, `templates/LOCKS-TEMPLATE.md` — this file is why it is shaped that way.
> **Scope:** `scripts/lock.sh` (new), `LOCKS.md` (new board), `templates/LOCKS-TEMPLATE.md`, `WORKFLOW.md` Steps 1 / 2a / 4h / Staled, `WORKFLOW-CHEATSHEET.md`, `AGENTS.md`, `skills/cascade-and-prompt`, `skills/close-loop`, `templates/FEATURE-TEMPLATE.md`, `templates/BUG-TEMPLATE.md`, `.claude/agents/hub-ops.md`, `.claude/settings.json`, `scripts/instance.sh sync`, `README.md`, `spechub.conf(.example)`.

## 1. Problem

Git worktrees isolate implementation: every dispatched prompt works on its own branch in its own worktree, and two prompts never share a working tree. Nothing isolated the **specs**. Two developers (or two instances of the stack, see `scripts/instance.sh`) designing against the same service spec at the same time found out only when the second cascade met the first one as a merge conflict in a module file — after both had spent an Advanced-tier design session and possibly generated contradictory prompts against the same service.

`STATUS.md` already carries the closest signal — an In Flight row lists the services a feature touches — but it appears at Step 2a (the cascade), not at the start of design, it is per service rather than per module file, it records no owner, and `scripts/status.sh claim` does not refuse a service that another row already names.

## 2. Principles

| # | Principle | Consequence |
|---|---|---|
| P1 | **Advisory, not enforced.** | The lock is a row on a board. Nothing prevents an edit; the skills stop at `scripts/lock.sh check`. Heavyweight enforcement (pre-commit hooks, file permissions) would fight the tools and the human. |
| P2 | **Same protocol as feature numbers.** | Origin is the one place every instance shares. A claim fetches, fast-forwards the hub, edits the board, commits `LOCKS.md` alone and pushes; a rejected push undoes the commit and retries on top of the other instance's row. `scripts/status.sh claim` proved this shape; `lock.sh` reuses it rather than inventing a second one. |
| P3 | **Notice at design, hold at cascade.** | The spec is not touched during design, only from the cascade to close-out — so that is the only window where a refusal is justified. A design can take days and may never be cascaded; blocking others for it costs more than it protects. Design therefore posts an *intent* (visible, warns, blocks nobody) so the conversation happens on day one; the cascade takes the *hold* on the exact files it edits. |
| P4 | **Release after the reconciled spec, never before.** | Close-out releases with `--no-push`: the row leaves with the close-out commit, together with the reconciled spec. A release pushed on its own would let the next designer claim a file whose reconciled version is not on origin yet. |
| P5 | **Module granularity.** | Two features on different modules of one service are the common case and do not conflict. A whole-service claim (`NN-svc.md` or `NN-svc/`) blocks every module under it and vice versa. A module file may be held before it exists (a new module). |
| P6 | **Zero session tokens.** | `LOCKS.md` is tiny, but it is still written only by the script and read through `lock.sh list` / `check`; no skill lists it as a required read. |

## 3. Decisions

| # | Decision | Alternatives rejected |
|---|---|---|
| D1 | **A separate board, `LOCKS.md`**, one row per in-flight feature: feature slug, spec files, by, since, note. | *A marker inside each spec file* — editing a spec to lock it creates the very merge conflict the lock exists to prevent, and adds a line every session reads. *Extra columns on `STATUS.md`* — rows there are numbered at 2a and per service; the board's parser and template would change for a different concern. |
| D2 | **Keyed by the feature's kebab slug** (the `{name}` of `Features/FEATURE-{name}.md` / `BUG-{name}.md`), the same key the metrics ledger uses — it exists before the feature number does. | The feature number (unknown at Step 1); the feature title (free text, not a key). |
| D3 | **No `merge=union` for `LOCKS.md`.** Two offline claims of the same file meet as a real git conflict, which `instance.sh sync` reports and leaves to a human; keeping both rows and running `check` names the two holders. | Union merge — it resurrects deleted lines when a release and a claim touch the same hunk, i.e. a shipped feature's lock would come back. The ledger and changelog are append-only, so union is right for them and wrong here. |
| D4 | **Release is not restricted to the claimant.** Close-out is often run by someone other than the designer, and a soft lock that only its holder can drop stalls on absence. The release is logged (commit message, who ran it). | `--force` for a foreign release — process weight without protection, since anyone can edit the file anyway. |
| D5 | **`check` warns on stale (`LOCK_STALE_DAYS`, default 14) and orphaned rows (feature file already in `Features/Implemented/` or `Staled/`), fails only on two features holding one file.** `instance.sh sync` ends with it, so the warning reaches every developer without a session. | Auto-expiry — a design that took three weeks is still in flight; the human decides. |
| D6 | **Service names resolve to spec paths** (`api` → `02-api.md`, `api/orders` → `02-api/orders.md`) so the design conversation's vocabulary works at the terminal. | Paths only. |
| D7 | **Two states on one row: `designing` and `held`.** `intend` (Step 1) posts a designing row and warns about every overlap; `claim` (Step 2a) upgrades it to held on the exact module files, replacing the coarse intent, and refuses only against another *held* row — a design against a held file is warned, not refused, since it only has to re-validate once the hold is released. The design session itself runs `intend` as its first action (the user's choice: no separate terminal ritual, and a forgotten notice cannot happen). | *A blocking claim at Step 1* (the first version): it held a module for the whole design, days or weeks, for a design that might never be cascaded, and the designer did not need to know the exact files yet. *No Step 1 row at all*: loses the day-one conversation, which is the cheapest coordination there is. |

## 4. Where it enters the workflow

| Step | Action | Who |
|---|---|---|
| 1 Design | `scripts/lock.sh intend <name> <service>...` as the session's first action, coarse scope. Overlap → reported to the user, design continues. | Design session |
| 2a Cascade | `scripts/status.sh claim` (number), then `scripts/lock.sh claim` for every file about to be edited: the intent becomes a hold on exactly those files. Refused (another hold) → the skill stops; nothing cascaded, no prompt. Overlap with a design → named in the report. | `cascade-and-prompt` skill |
| 3 Implement | Nothing — the specs are not edited. | — |
| 4h Close | `scripts/lock.sh release <name> --no-push` after reconciliation; `scripts/lock.sh check` reported, not fixed. | `close-loop` skill |
| Staling, abandoning a design | `scripts/lock.sh release <name>`; reviving starts with a new intent. | Human |
| Any time | `scripts/lock.sh list`; `scripts/instance.sh sync` ends with `check`. | Human |

## 5. Verified behavior (scratch origin, two clones)

Intent posted and pushed; a second intent on an overlapping area warned and allowed; claim upgrading a coarse intent to a hold on exact files; a second feature's hold on a different module of the same service allowed; an intent against a held file warned and allowed; a hold against a held file refused with the holder named; `check` distinguishing `CONFLICT` (held/held, exit 1) from `OVERLAP` (warning). From the first version, still holding: claim and push; conflict against a whole-service claim (and the reverse); extension with a not-yet-existing module file; idempotent re-claim; targeted `check` (held / free); board `check` clean, stale, orphan; dirty-board refusal; bad slug / unresolvable path; a competing push on a *different* file → retry on top of it and succeed; a competing push on the *same* file → fail cleanly naming the holder; two offline claims of one file → `check` reports against origin before the merge, git conflicts on the merge, `check` reports again after both rows are kept.

## Appendix A — Not done

- `bootstrap-specs` (Step 0) does not write `LOCKS.md`; `lock.sh` creates it from the template on the first claim. Keeps Step 0's contract unchanged.
- No lock on `Features/` or `Prompts/` files: they are per feature by construction.
- The OSS SpecHub repo is a separate checkout; this change is ported by hand like every framework change.
