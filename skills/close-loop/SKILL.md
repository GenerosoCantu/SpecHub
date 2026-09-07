---
name: close-loop
description: Close out an implemented feature (WORKFLOW.md Step 4) — merge Verified feature branches into the base branch, reconcile specs, flip STATUS.md, update CHANGELOG, archive feature file and prompts, sync repo instructions. Use when the user says a feature is implemented/verified and asks to "close the loop", "reconcile", "close out", or "step 4".
context: fork
agent: hub-ops
---

> Runs forked in the `hub-ops` subagent (Standard tier) where the tool supports it, otherwise in a fresh session: the reconciliation reads (specs, prompts, service diffs) stay in this isolated context and the main session receives only the report. Request from the user: **$ARGUMENTS** (feature name / number, and any deviations they already know of).

# Close the Loop (Step 4)

Reconcile the spec hub with what was actually built. All sub-steps happen in this single pass — the loop is closed only when the hub reflects reality exactly, every feature branch is merged and gone, the services run from the main checkouts again, and no `<repo>-worktrees/` folder is left on disk.

## 0. Preconditions

- The implementation has been **human-verified** (build run, endpoints/UI exercised, diff read). If not, stop.
- Every prompt for the feature has dispatch-header `Status: Verified`. If any is still `Generated` or `Applied`, stop and report which. (`scripts/dispatch.sh status` shows the board.)

Deviations come from two places: what the user stated in the request, and each prompt's **Dispatch Run Report** section (the agent summary lists `DEVIATIONS` reported at implementation time). You cannot ask the user mid-run — work from those two sources plus the drift check in step 2. Deviations are absorbed into the spec, not ignored.

**Required reads — nothing more:** `STATUS.md`, the feature file, the feature's prompt files, and the affected spec / module file(s) named in the prompts. Do not read `WORKFLOW.md`, `CHANGELOG.md`, `00-architecture-overview.md`, `bootstrap/`, or any `Implemented/` folder.

## 1. Merge the feature branches into the base branch

For each Verified prompt, in the feature's implementation order (the `Prerequisites:` lines):

```bash
scripts/dispatch.sh merge PROMPT-api-x             # one prompt
scripts/dispatch.sh merge --all                    # every Verified prompt
scripts/dispatch.sh merge --all --push             # also push the base branch (only if the user asked)
```

The script refuses to merge a prompt that is not `Verified`, a repo whose main checkout is dirty, or a conflicting merge — report the reason and stop; the user resolves it. On success it merges with a `--no-ff` merge commit, stops the service if it runs from the worktree, removes the worktree, deletes the feature branch, restarts the service from the main checkout, and appends a **Merged** entry (merge commit + implementing commit SHAs) to the prompt's run report. Those SHAs are the changelog traceability refs (step 5). After the last merge it sweeps the affected `<repo>-worktrees/` folders and deletes each root that holds no registered worktree.

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
- Replace each touched spec's `Last updated` line with **one line of at most ~200 characters naming this feature only**, e.g. `> **Last updated:** 2026-09-06 — Site Texts (#69) implemented and closed: \`03-api/site-texts.md\`. History lives in \`CHANGELOG.md\`.` Never keep or add a `Prior (...)` chain. Do NOT append history entries (single-log rule: dated logs live only in `CHANGELOG.md`).

## 4. Flip the status board

- In `STATUS.md`, mark every service cell of the feature row ✅ and move the row from **In Flight** to **Shipped**.
- **The Notes cell is one line max** — a short pointer or superseded-decision note. Implementation detail belongs in `CHANGELOG.md` and the archived design doc, never in the board.
- Touch `00-architecture-overview.md` only if system-wide architecture changed (a new service, a new dependency edge, auth or tenancy model); bump its `Last Updated:` if so.

## 5. Update the changelog

- Do **not** open `CHANGELOG.md`. Run:

```bash
scripts/changelog.sh add "<Feature> (#n) implemented and closed across <services>: what shipped; notable deviations. (api@a1b2c3d, web@e4f5a6b)"
```

- One entry per feature, **≤ 900 characters** (the script refuses longer ones): what shipped, the deviations that matter, and the traceability refs from step 1's **Merged** entries (implementing commit SHA(s) or PR link(s) per service repo). Rationale stays in the archived feature file; the dispatch trace stays in the archived prompt.

## 6. Archive the feature file

- Move `Features/FEATURE-{name}.md` → `Features/Implemented/`, adding this banner at the top:

```markdown
> **ARCHIVED — historical design record. NOT a source of truth.**
> Implemented YYYY-MM-DD. Current state lives in {service-spec}.md.
> Do not edit; this captures the original design reasoning only.
```

## 7. Archive the prompt(s)

- Move each `Prompts/PROMPT-{service}-{feature}.md` → `Prompts/Implemented/`. Keep the **Dispatch Run Report** section intact — it is the implementation trace (sessions, commits, merge).

## 8. Sync repo instructions if conventions changed

- If the feature changed any shared convention (naming, module layout, storage patterns, env conventions): update `CONVENTIONS.md`, update the affected canonical file(s) in `repo-instructions/`, and remind the user to copy them into the service repo(s). The hub copies are canonical.

## 9. Finish

Report (under 40 lines — it is all the main session receives): branches merged (merge commits per repo, pushed or not), workspace reset (services back on main checkouts, worktree roots gone or which remain and why), drift-check result (deviations found), files reconciled, STATUS row flipped, changelog entry (with commit refs), archived files, and any convention syncs performed. Flag anything the specs still don't capture.

The loop is closed. The next feature's design (Step 1) starts in a **new session** on an Advanced-tier model.
