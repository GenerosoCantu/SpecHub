# SpecHub Steps — Quick Summary

**Last Updated:** 2026-09-30

One-page cheat sheet for the workflow. Authoritative detail stays in `WORKFLOW.md` (process) and `AGENTS.md` (routing); the tier → model mapping lives in `spechub.conf` (`MODEL_LIGHT` / `MODEL_STANDARD` / `MODEL_ADVANCED`).

**Legend** — *New session*: start a fresh session in the hub and end it when the step's files are on disk (one step per session). *Head decision*: no session — the human decides or runs a script.

| Step | What it does | New session or head decision | Model |
|---|---|---|---|
| **0 — Bootstrap** (`bootstrap-specs`) | Once per project: `scripts/bootstrap.sh init` detects repos and writes `spechub.conf` + fact sheets; the skill forks one `spec-writer` per service and assembles the specs, overview, `CONVENTIONS.md`, `STATUS.md`, `repo-instructions/`. | New session (forks one `spec-writer` per service) | Standard |
| **1 — Design** | `scripts/lock.sh intend` first, then write `Features/FEATURE-{name}.md` (or `BUG-{name}.md`). No spec or code edits. Code recon via `Explore` subagents. | New session — must not inherit another feature's context | **Advanced** |
| **2 — Cascade & Prompt** (`cascade-and-prompt`) | One pass, no stop between halves: 2a `scripts/status.sh claim` + `lock.sh claim`, cascade the feature into the spec / module files and add the `STATUS.md` row; 2b re-read the cascaded spec from disk and generate `Prompts/PROMPT-{service}-{feature}.md`. | New session | Standard |
| **3 — Dispatch** (`dispatch-prompts`) | Runs every `Generated` prompt via `scripts/dispatch.sh run` — one worktree + detached headless session per prompt, all in parallel — flips them to `Applied` and restarts the affected services from the worktrees. Rejections are recorded (`verify --fail`) and fixed with `resume` here. | New session, forked into the `hub-ops` subagent (main session only gets the report) | Standard |
| **3.5 — Implementation runs** | Each prompt implemented headlessly inside its own worktree of the target repo. Not a hub session; never run in a repo's main checkout. | Dispatched automatically by Step 3 | Per the prompt header (Light by default) |
| **3.9 — Verification** | Exercise the restarted services in implementation order. Accepted → name the prompt in the Step 4 request. Rejected → back to a Step 3 session (`verify --fail` + `resume`). | **Head decision** — human only; no skill decides it | — |
| **4 — Close the Loop** (`close-loop`) | Records the verifications, merges each branch into the base branch and pushes, reconciles the specs to the built state, flips `STATUS.md`, adds the changelog entry, re-renders metrics, archives feature file + prompts, syncs repo instructions, releases the locks. | New session naming the verified prompts, forked into `hub-ops` | Standard |

## Off-cycle actions

| Action | New session or head decision | Model |
|---|---|---|
| Fix / follow-up on an in-flight prompt (`dispatch.sh resume`) | Same dispatched session, resumed — never a new run | Per the prompt header |
| Interactive debugging inside a worktree | Head decision — resume that session with your CLI (session ID is in the run report) | Per the prompt header |
| Question about what was just built | Resume the prompt's session | Per the prompt header |
| Staling or reviving a feature design | Head decision to stale; a revival starts a new Step 1 session (fresh `lock.sh intend`, re-validate against current specs) | Advanced (on revival) |
| Instance sync / stack ops (`instance.sh`, `stack.sh`, `test-portable.sh`) | Head decision — run by a human, never from a workflow step | — |
| Promoting a `bootstrap/OBSERVATIONS.md` entry into a template rule | Head decision between runs — a workflow step never edits its own contract | — |
