---
name: close-loop
description: Close out an implemented feature or bug fix (WORKFLOW.md Step 4) — record the user's verification of the Applied prompts, merge the feature branches into the base branch and push it, reconcile specs, flip STATUS.md, update CHANGELOG, archive feature file and prompts, sync repo instructions. Use when the user says a feature is verified / works / is accepted and asks to "close the loop", "reconcile", "close out", or "step 4".
context: fork
agent: hub-ops
---

> Runs forked in the `hub-ops` subagent (Standard tier) where the tool supports it, otherwise in a fresh session: the reconciliation reads (specs, prompts, service diffs) stay in this isolated context and the main session receives only the report. Request from the user: **$ARGUMENTS** (feature name / number, which prompts they verified, and any deviations they already know of).

# Close the Loop (Step 4)

Reconcile the spec hub with what was actually built. All sub-steps happen in this single pass — the loop is closed only when the hub reflects reality exactly, every feature branch is merged and gone, the services run from the main checkouts again, and no `<repo>-worktrees/` folder is left on disk.

## 0. Preconditions — record the verification, then gate on it

Verification is human: the user reviews the diff, runs the build and exercises the endpoints/UI against the services the dispatcher left running from the worktrees. What this step does is **record** that verdict, never infer it.

- Run `scripts/dispatch.sh status` for the board.
- For every `Applied` prompt of the feature that the user's request states as verified ("verified", "it works", "accepted", "all prompts of X are verified"), run `scripts/dispatch.sh verify <prompt>` — in the feature's implementation order (the `Prerequisites:` lines). This flips it to `Verified` and records who accepted it. Name every prompt you flipped in the report.
- Any prompt for the feature still `Applied` that the request does **not** cover, or still `Generated`: stop and report which — the user has not verified it. Never flip a prompt the user did not name; never read the run report or the diff to decide for them.
- A rejection ("X is wrong", "the dropdown is broken") is not close-out work: do not merge anything. Record it with `scripts/dispatch.sh verify <prompt> --fail "<reason>"` and stop, telling the user to fix it with the `dispatch-prompts` skill (`resume`).

Deviations come from two places: what the user stated in the request, and each prompt's **Dispatch Run Report** section (the agent summary lists `DEVIATIONS` reported at implementation time). You cannot ask the user mid-run — work from those two sources plus the drift check in step 2. Deviations are absorbed into the spec, not ignored.

**Required reads — nothing more:** `STATUS.md`, the feature file (`FEATURE-{name}.md` or `BUG-{name}.md`), the feature's prompt files, and the affected spec / module file(s) named in the prompts. Do not read `WORKFLOW.md`, `CHANGELOG.md`, `00-architecture-overview.md`, `bootstrap/`, or any `Implemented/` folder.

## 1. Merge the feature branches into the base branch

For each Verified prompt, in the feature's implementation order (the `Prerequisites:` lines):

```bash
scripts/dispatch.sh merge PROMPT-api-x             # one prompt
scripts/dispatch.sh merge --all                    # every Verified prompt
scripts/dispatch.sh merge --all --no-push          # keep the merges local (only if the user asked)
```

With `MERGE_PUSH=1` in `spechub.conf` (the default) each merge also **pushes the base branch to origin**: the script first fetches origin and fast-forwards the local base to it, and refuses to merge when origin is unreachable or the base has diverged — report the reason and stop; the user resolves it. It likewise refuses a prompt that is not `Verified`, a repo whose main checkout is dirty, or a conflicting merge. On success it merges with a `--no-ff` merge commit, stops the service if it runs from the worktree, removes the worktree, deletes the feature branch, restarts the service from the main checkout, pushes, and appends a **Merged** entry (merge commit + implementing commit SHAs + `Pushed`) to the prompt's run report. Those SHAs are the changelog traceability refs (step 5); a bad feature is rolled back with `git revert -m 1 <merge-commit>`, never a force-push. After the last merge it sweeps the affected `<repo>-worktrees/` folders and deletes each root that holds no registered worktree.

**A rejected push is a blocker, not a footnote.** The script exits non-zero with `PUSH FAILED for: <repos>` and the run report says `Pushed | FAILED`; the merge exists locally only. Continue the close-out (the hub must still match the merged code) but put the failed push and the exact `git push` command first in the report.

If a prompt was applied by hand outside the dispatcher (no run report), merge it the same way — the script only needs the header's repo and branch.

**Then reset the workspace and confirm it:**

```bash
scripts/dispatch.sh clean          # every service repo; must end with "All worktree roots are gone."
scripts/stack.sh status            # every running service must show no worktree banner
```

If `clean` reports a root still present, a registered worktree from another in-flight feature lives there — leave it and name it in the report. Never pass `--force` here on your own; only the user decides to drop someone else's worktree.

## 2. Verify the spec against the code (drift check)

Do not reconcile from memory or from the user's description alone.

- For each affected service, resolve the service repo path from the prompt's dispatch-header `Target repo:` line. After step 1 the repo's main checkout is on the base branch and contains the feature.
- Start from `git -C <repo> diff --stat <merge-commit>^1..<merge-commit>` to learn which files changed, then read the diff **per file** (`git diff <merge-commit>^1..<merge-commit> -- <file>`) only for files that carry contracts — schema/entity, DTO, controller/routes, service public surface, components, state slices, i18n keys. Skip lockfiles, snapshots, and formatting-only hunks. Where an `Explore` subagent is available, delegate this and ask it for the contract facts plus the deviation list.
- Confirm the spec's claimed contracts — field names, types, endpoint paths/guards, component names — match what was actually built. Account for every file touched — a contract change in a file the prompt did not name is still a deviation.
- Any mismatch: **reality wins.** Note it as a deviation to absorb into the spec (step 3) and record in the changelog (step 5).
- If a repo path is unreachable, say so and ask the user for the deviations and commit refs instead — do not silently skip the check.

## 3. Reconcile the service spec(s)

- Update the affected spec / module file(s) to match what was actually built — field names, endpoint shapes, component names. Reality wins over the original plan.
- Split specs: edit module files; touch the index File Map only if a module was added, renamed, or removed.
- Remove the feature's `<!-- PENDING: ... -->` markers.
- **Class A bug** (no spec change was cascaded): touch a spec only if the drift check found a deviation; otherwise leave every spec and its `Last updated` line alone.
- Replace each touched spec's `Last updated` line with **one line of at most ~200 characters naming this feature only**, e.g. `> **Last updated:** 2026-09-06 — Site Texts (#69) implemented and closed: \`03-api/site-texts.md\`. History lives in \`CHANGELOG.md\`.` Never keep or add a `Prior (...)` chain. Do NOT append history entries (single-log rule: dated logs live only in `CHANGELOG.md`).

## 4. Flip the status board

- In `STATUS.md`, mark every service cell of the feature row ✅ and move the row from **In Flight** to **Shipped**.
- Run `scripts/status.sh check`. A duplicate number (a claim made offline in another instance of the stack) is reported, not fixed here: name it first in the final report.
- **The Notes cell is one line max** — a short pointer or superseded-decision note. Implementation detail belongs in `CHANGELOG.md` and the archived design doc, never in the board.
- Touch `00-architecture-overview.md` only if system-wide architecture changed (a new service, a new dependency edge, auth or tenancy model); bump its `Last Updated:` if so.

## 5. Update the changelog

- Do **not** open `CHANGELOG.md`. Run:

```bash
scripts/changelog.sh add "<Feature> (#n) implemented and closed across <services>: what shipped; notable deviations. (api@a1b2c3d, web@e4f5a6b)"
```

- A bug entry starts with `Fix:` — e.g. `Fix: Story slug collision (#74) closed in api: …`.
- One entry per feature, **≤ 900 characters** (the script refuses longer ones): what shipped, the deviations that matter, and the traceability refs from step 1's **Merged** entries (implementing commit SHA(s) or PR link(s) per service repo). Rationale stays in the archived feature file; the dispatch trace stays in the archived prompt.

## 6. Regenerate the metrics board

- Do **not** open `METRICS.md` or `metrics/ledger.jsonl`. Run:

```bash
scripts/metrics.sh render
```

- One command, zero reads: it first syncs every hub session transcript into the ledger (this session included, forked subagents and all), then rebuilds the board from that ledger together with the events `dispatch.sh` has been writing all along. Nothing to review, nothing to paste into a spec. If it warns about a missing price row or a stale one, say so in the final report — do not edit `metrics/prices.tsv` from inside this step.

## 7. Archive the feature file

- Move `Features/FEATURE-{name}.md` (or `BUG-{name}.md`) → `Features/Implemented/`, adding this banner at the top:

```markdown
> **ARCHIVED — historical design record. NOT a source of truth.**
> Implemented YYYY-MM-DD. Current state lives in {service-spec}.md.
> Do not edit; this captures the original design reasoning only.
```

## 8. Archive the prompt(s)

- Move each `Prompts/PROMPT-{service}-{feature}.md` → `Prompts/Implemented/`. Keep the **Dispatch Run Report** section intact — it is the implementation trace (sessions, commits, merge).

## 9. Sync repo instructions if conventions changed

- If the feature changed any shared convention (naming, module layout, storage patterns, env conventions): update `CONVENTIONS.md`, update the affected canonical file(s) in `repo-instructions/`, and remind the user to copy them into the service repo(s). The hub copies are canonical.

## 10. Release the spec locks

- Run `scripts/lock.sh release <feature> --no-push` (the feature's kebab name). `--no-push` is deliberate: it drops the row in the working tree only, so the release leaves with the close-out commit and never reaches origin before the reconciled spec does. Never push it separately from here.
- Then `scripts/lock.sh check`: an `OVERLAP` line (a design that was waiting on this feature's files and must now re-validate), an `ORPHAN` line (another feature already archived but still on the board) or a `STALE` line is reported in the final report, not fixed here; a `CONFLICT` line names it first.

## 11. Finish

Report (under 40 lines — it is all the main session receives): prompts flipped to Verified, branches merged (merge commits per repo, pushed to origin or **PUSH FAILED**), workspace reset (services back on main checkouts, worktree roots gone or which remain and why), drift-check result (deviations found), files reconciled, STATUS row flipped, changelog entry (with commit refs), metrics board regenerated (plus any price-row warning it printed), archived files, spec locks released (and what `lock.sh check` reported), and any convention syncs performed. Flag anything the specs still don't capture.

The loop is closed. The next feature's design (Step 1) starts in a **new session** on an Advanced-tier model.
