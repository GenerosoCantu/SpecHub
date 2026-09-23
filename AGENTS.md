# SpecHub — Agent Instructions

> This is the canonical instruction file for every coding agent working in this workspace. Codex, GitHub Copilot and most agents read `AGENTS.md` directly; Claude Code imports it through `CLAUDE.md` (`@AGENTS.md`); `.github/copilot-instructions.md` points here. Edit only this file.

## Purpose

This workspace is a specification and prompt hub, not an application codebase. Treat the markdown documents here as the source of truth for platform behavior, contracts, workflow, and implementation handoff.

Service repositories must not become alternate sources of truth. After implementation, the authoritative state must be reconciled back into this workspace.

## Services

The service repos, their identifiers and their specs. Maintained by `scripts/bootstrap.sh` from `spechub.conf` — do not edit the table by hand (`scripts/bootstrap.sh services` refreshes it). Repo paths are relative to `REPOS_ROOT` (`scripts/stack.sh root` prints the resolved folder), so the table holds for every instance of the stack.

<!-- services:start -->
_No services yet — run `scripts/bootstrap.sh init <repos-root>` (WORKFLOW.md Step 0)._
<!-- services:end -->

## Core Rules

- Always read the relevant spec file(s) before answering questions or generating output.
- Do not invent names, routes, DTOs, schema fields, state slice names, or workflow steps.
- Prefer the exact naming and contracts already written in the specs.
- If a task affects process, prompt generation, feature lifecycle, or spec reconciliation, read `WORKFLOW.md` first.
- If a task affects system-wide behavior, read `00-architecture-overview.md` first.
- For shared conventions (API naming, entities, storage, env vars, logging, code organization), read `CONVENTIONS.md` — do not load the full overview just for conventions.
- For feature status, read `STATUS.md` — do not load the full overview just for status.
- If a task affects a specific service, read that service spec first (see "Split specs" below).
- If the task is ambiguous about which spec applies, identify the relevant spec(s) before producing output.

## Context Budget

Token spend is dominated by sessions in this workspace, not by the dispatched implementation runs (see `WORKFLOW.md` → Context Budget). These rules are mandatory:

- **One workflow step per session.** Bootstrap, design, cascade & prompt, dispatch, and close-out each start a fresh session; the skills end by telling you to stop. Never chain steps in one session.
- **Model per step.** Three tiers — Light, Standard, Advanced — mapped to concrete models in `spechub.conf`. Design on Advanced; bootstrap and cascade & prompt on Standard; dispatch and close-out on Standard, forked into the `hub-ops` subagent where the tool supports it.
- **Read only what the task needs.** When a skill is invoked, it lists its required reads — do not also open `WORKFLOW.md` or `00-architecture-overview.md`. Index files route to module files; never read a whole split spec.
- **Delegate code reading** in service repos to a read-only exploration subagent that returns a summary, when the tool has one.
- **Never edit a template, `SPEC-GUIDELINES.md` or `AGENTS.md` from inside a workflow step.** A step that rewrites its own contract cannot be compared to the previous run. Step 0 appends to `bootstrap/OBSERVATIONS.md`; promoting an observation into a rule is a human step between runs.
- **Never open `CHANGELOG.md`, `METRICS.md` or `metrics/ledger.jsonl`.** Add changelog entries with `scripts/changelog.sh add "<entry>"` (≤ 900 chars, one per feature, at close-out). The metrics files are written and read by `scripts/metrics.sh` — `report` prints the summary, `render` regenerates the board. An observability surface that costs context every session would defeat this budget.
- **Search scope.** Exclude `archive/`, `bootstrap/`, `Features/Implemented/`, `Features/Staled/` and `Prompts/Implemented/` from repo-wide greps unless the task is about history.
- **Size caps.** Feature file ≤ 8 KB / 15 KB; prompt ≤ 8 KB / 12 KB; spec `Last updated` line ≤ ~200 chars naming the latest change only; module file 50–400 lines.

## Skills

The workflow steps are written as skills in `skills/` (Agent Skills format: one `SKILL.md` per skill). `.claude/skills`, `.github/skills` and `.codex/skills` are symlinks to that folder so Claude Code, Copilot and Codex all discover them. A tool that does not discover skills follows the same file as a checklist: open `skills/<name>/SKILL.md` and do what it says.

| Skill | Step | Runs as |
|---|---|---|
| `bootstrap-specs` | 0 | main session, Standard tier; forks one `spec-writer` per service |
| `cascade-and-prompt` | 2 | main session, Standard tier |
| `dispatch-prompts` | 3 | `hub-ops` subagent (Claude Code `context: fork`; Copilot custom agent in `.github/agents/`); otherwise a fresh session |
| `close-loop` | 4 | same as dispatch-prompts |

Subagent definitions live in `.claude/agents/` (canonical) with thin Copilot wrappers in `.github/agents/`.

## Split Specs

A service with many modules has a **split** spec to keep context small:

- `NN-{service}.md` is an **index file**; the content lives in the `NN-{service}/` directory.
- For any module task: read the index, the directory's `00-core.md` (plus `01-conventions.md` when env/config, constants or shared shapes are involved), and only the relevant module file(s).
- Never read every module file. Never re-add module content to the index files.
- New modules get their own file in the directory plus a row in the index File Map.

A service with few modules has a single `NN-{service}.md` — read it whole.

## Required Reads By Task

Use these routing rules every time.

### General questions about the platform
Read:
- `00-architecture-overview.md` (system-wide) or `CONVENTIONS.md` (conventions only)
- The relevant service spec (index + `00-core.md` + module file(s) for a split spec)

### Bootstrapping the hub from the repos (Step 0)
Use the `bootstrap-specs` skill after `scripts/bootstrap.sh init` has written `spechub.conf` and `bootstrap/facts/`. It forks one `spec-writer` subagent per service and assembles the overview, `CONVENTIONS.md`, `STATUS.md` and `repo-instructions/` from their reports.

### Designing a new feature or enhancement (Step 1)
Read:
- `WORKFLOW.md`
- `CONVENTIONS.md` and `STATUS.md`
- The relevant service spec (index + module file(s))

Then create or update `Features/FEATURE-{name}.md` (`templates/FEATURE-TEMPLATE.md`) before proposing implementation prompts. Cross-service features must declare an implementation order (see WORKFLOW.md Step 1).

### Fixing a bug in merged, closed work (Step 1, bug variant)
Read `WORKFLOW.md` → Bugs, then the relevant service spec (index + module file(s)). Create `Features/BUG-{name}.md` (`templates/BUG-TEMPLATE.md`), classed A (code diverges from spec — no spec edit) or B (spec wrong or silent — cascaded like an enhancement). A defect in a prompt that is still `Applied` is not a bug file: resume that prompt (`scripts/dispatch.sh resume`).

### Cascading a designed feature and generating its implementation prompts (Step 2)
Use the `cascade-and-prompt` skill. One session does both halves in order, without stopping between them: 2a cascades the feature file into the affected spec / module file(s) and adds the `STATUS.md` row; 2b re-reads the cascaded spec from disk and generates the prompts from it, including the mandatory dispatch header (target repo, branch, prerequisites, status, model tier). Never generate a prompt before the spec edit is on disk.

### Dispatching implementation prompts (Step 3)
Use the `dispatch-prompts` skill. Human verification has two outcomes and both must be recorded: an accepted prompt is named in the Step 4 request and recorded there (`scripts/dispatch.sh verify <prompt>`, run by the `close-loop` skill before merging — no separate session for it); a rejected prompt is recorded here with `verify <prompt> --fail "<reason>"` (the prompt stays `Applied`; fix it with `resume`, which records the rejection automatically if you skipped `--fail`). It drives `scripts/dispatch.sh`, which runs every `Generated` prompt as a detached headless session of the CLI named in `spechub.conf` (`AGENT_CLI`: claude, codex or copilot) in its own git worktree of the target repo (branch from the base branch), all in parallel (`run` returns at once; `wait` blocks and reports failures), flips the prompt to `Applied`, and restarts the affected services from their worktrees (`scripts/stack.sh`). Verification stays human (`scripts/dispatch.sh verify`); follow-up fixes resume the same session (`scripts/dispatch.sh resume`).

### Implemented feature close-out and spec reconciliation (Step 4)
Use the `close-loop` skill, stating which prompts you verified — it records them (`scripts/dispatch.sh verify`) and stops if a prompt of the feature is left unverified; it never decides verification itself. It encodes the full Step 4 checklist: branch merge into the base branch and push to origin (`scripts/dispatch.sh merge` — the base is fast-forwarded to origin first, services go back to the main checkouts, the worktree folders are deleted; `MERGE_PUSH` in `spechub.conf`, `--no-push` per merge; a failed push is reported first, and rollback is a revert of the merge commit), spec reconciliation, `STATUS.md` flip, changelog entry, metrics board regeneration (`scripts/metrics.sh render`), feature/prompt archival, and repo-instructions sync check.

### Reviewing or editing an existing prompt file
Read:
- `WORKFLOW.md` Step 2b only (the dispatch header and prompt structure)
- The relevant service spec (index + module file(s))
- The target prompt file

## File Map

- `spechub.conf`: project name, base branch, agent CLI and model tiers, repos root, and the service table (`name|dir|start|port|label|group|install`) every script reads
- `spechub.local.conf`: gitignored per-checkout overrides read by every script — `REPOS_ROOT` (when the repos do not sit next to the hub; `SPECHUB_REPOS_ROOT` in the environment does the same), `PORT_OFFSET` (every service port shifted by it, so several instances of the stack run on one machine) and extra `SERVICES` rows such as an instance's own `mongod`
- `AGENTS.md`: this file — agent routing for the workspace (`CLAUDE.md` and `.github/copilot-instructions.md` point here)
- `00-architecture-overview.md`: system map and shared architectural decisions
- `CONVENTIONS.md`: shared conventions (API naming, entities, storage, env vars, logging, code org)
- `STATUS.md`: live feature status board — flipped to complete in Step 4
- `METRICS.md`: generated observability board (throughput, failure rate, per-step and per-feature usage in price-free units, API-list value per feature — dollars at list prices as a cross-model unit, not an invoice: the plan is flat-fee — and model-tier conformance) — regenerated by `scripts/metrics.sh render` at close-out; never opened in a session
- `metrics/ledger.jsonl`: append-only event ledger behind it (one line per dispatch run, verification, merge and hub session) — **token counts are the stored truth, dollars are derived at render time**, so re-pricing `metrics/prices.tsv` re-prices all of history without touching the usage figures
- `WORKFLOW.md`: authoritative process for Bootstrap → Design → Cascade & Prompt → Implement → Close
- `SPEC-GUIDELINES.md`: what goes in the overview vs a service spec; the checklist Step 0 generates against
- `CHANGELOG.md`: implementation history (the only document that accumulates dated log entries) — written by `scripts/changelog.sh add`, never opened in a session; older entries in `archive/CHANGELOG-archive.md`
- `NN-{service}.md`: one spec per service (index + `NN-{service}/` directory when split) — see the Services table above
- `bootstrap/facts/`: mechanical fact sheets per service (`scripts/bootstrap.sh facts`) — the input of Step 0; excluded from searches. §4 is the module list (and §4b the shared layers a frontend does not split on), §7a the canonical env-var list, §12 the writer's complete read set
- `bootstrap/OBSERVATIONS.md`: append-only log of template rules that did not decide a case — Step 0 writes here instead of editing a template, so one run's contract stays comparable to the next
- `Features/`: pending feature (`FEATURE-*.md`) and bug (`BUG-*.md`) design documents only
- `Features/Implemented/`: archived design docs for completed features (frozen historical records)
- `Features/Staled/`: parked feature designs — not active, not implemented (see WORKFLOW.md "Staled Features")
- `Prompts/`: active implementation prompts (each carries a repo/branch/prereq/status header)
- `Prompts/Implemented/`: prompts for completed work
- `repo-instructions/`: canonical copies of each service repo's instruction file (`AGENTS.md`) — seeded in Step 0, synced in Step 4 when conventions change
- `templates/`: fill-in templates (architecture overview, conventions, status board, service spec, spec index, module file, feature file, bug file, prompt)
- `skills/`: workspace skills — `bootstrap-specs` (Step 0), `cascade-and-prompt` (Step 2), `dispatch-prompts` (Step 3), `close-loop` (Step 4); symlinked from `.claude/`, `.github/` and `.codex/`
- `.claude/agents/`, `.github/agents/`: `spec-writer` (Step 0 per-service writer) and `hub-ops` (the subagent Steps 3 and 4 fork into)
- `scripts/bootstrap.sh`: Step 0 — discovers repos, detects stacks, writes `spechub.conf`, installs dependencies, writes fact sheets, prints the spec plan (`plan --manifest` prints the exact file list each writer must produce)
- `scripts/verify.sh`: Step 0 determinism gates — `manifest` (the file set matches the plan), `facts` (env tables match fact sheet §7a), `records` (every endpoint/route record carries every key of its type), `headings` (module files use only the closed set), `mechanisms` (every overview §10 cross-service entry has its four keys, names two or more different services, and is evidenced on both sides), `portable` (no tracked hub file outside `archive/`, the frozen history folders and `metrics/` holds a machine-specific path, and `spechub.conf` keeps `REPOS_ROOT` relative), `all` (those six), `diff <a> <b>` (two generated trees compared by extracted sets, not prose — including the §10 seam set, which is grouping-independent)
- `scripts/test-portable.sh`: end-to-end proof of the no-machine-paths rule — runs `bootstrap.sh init` in a throw-away layout under `mktemp` and checks the relative `REPOS_ROOT`, the fact-sheet paths, both override paths (`SPECHUB_REPOS_ROOT`, `spechub.local.conf`), the gitignored files, `verify.sh portable` and that an `instance.sh clone` resolves its own root; run by a human after touching the scripts, never from a workflow step
- `scripts/stack.sh`: starts/stops every service listed in `spechub.conf` (`-w <branch>` runs them from a git worktree), each with `PORT` set to its port plus `PORT_OFFSET`; the dispatcher drives it
- `scripts/instance.sh`: creates another instance of the whole stack under a new root (`init <new-root> <offset>` — clones the hub and repos, copies the gitignored env files and static data with ports shifted, gives it its own `mongod` with a copy of the databases) and brings an instance up to date (`pull [--rebase]` — fast-forwards the hub and every service repo from origin, reinstalls changed dependencies, lists the services to restart) or synchronizes it both ways (`sync` — commits the hub's `metrics/ledger.jsonl` the session hooks left uncommitted, merges origin into the hub and pushes it, then does `pull` for the service repos); run by a human, never from a workflow step. Instances meet only through origin: run `sync` before starting a workflow step
- `scripts/dispatch.sh`: Step 3/4 dispatcher — runs prompts as detached headless sessions in per-prompt worktrees (`run`, `wait`), restarts the services from those worktrees (`serve`), resumes them, marks them verified, merges them (`merge`), deletes the worktree folders (`clean`), and reinstalls dependencies whose manifests changed (`deps`, used by `instance.sh pull`)
- `scripts/status.sh`: `STATUS.md` feature numbers — `claim` (Step 2a, before any spec edit) takes the next free number and adds the In Flight row as its own commit pushed to origin, so two instances of the stack never take the same number; `next` prints it; `check` fails on a duplicate (run at close-out)
- `scripts/changelog.sh`: prepends a changelog entry (`add`) or rolls old entries into the archive (`archive`)
- `scripts/metrics.sh`: the observability ledger and its views — `emit` records dispatch events (called by `dispatch.sh`, never by hand); `session`/`sync` record hub sessions from the Claude Code transcripts, forked subagents included (called by the `SessionStart`/`SessionEnd` hooks and by every `report`/`render`, so a session the hooks missed is counted by the next one); `report` prints a terminal summary, `render` regenerates `METRICS.md`, `backfill` seeds history, `selftest` proves the derived cost formula against every reported cost, `archive` rolls old lines out
- `.gitattributes`: `metrics/ledger.jsonl` and `CHANGELOG.md` merge with `merge=union`, so two instances' lines never conflict (`metrics.py` drops any line a union merge doubles)
- `archive/`: not a source of truth — rolled changelog entries, old spec headers, samples; excluded from searches
- `.dispatch/`, `.run/`, `.logs/`: gitignored run logs and pids written by the scripts

## Output Expectations

- Keep answers and generated artifacts aligned with the current documented contracts.
- When asked to create prompts, include only the information needed for a service-repo implementation session.
- When asked to update specs after implementation, reflect the actual built state rather than the original plan if they differ.
- If required information is missing from the specs, say so and identify which document must be updated first.

## Session Guidance

- One workflow step per session; end the session at each step boundary (see Context Budget above).
- Bootstrap (Step 0) and cascade + prompt generation (Step 2) each happen in a fresh session in this workspace, on the Standard tier.
- Service implementation (Step 3) is dispatched from this workspace (`dispatch-prompts` skill): each prompt runs as its own headless session inside a git worktree of the target repo, all prompts in parallel. Do not implement in a service repo's main checkout.
- Bug fixes or follow-up corrections for the same in-progress implementation resume that prompt's session (`scripts/dispatch.sh resume`), never a new run.
- Post-implementation close-out (Step 4) happens in a fresh session back in this workspace (the `close-loop` skill).

For detailed workflow rules, feature-file structure, prompt structure, and close-out behavior, use `WORKFLOW.md` as the authoritative reference rather than duplicating those details here.
