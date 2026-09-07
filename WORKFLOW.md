# Feature & Enhancement Workflow

**Last Updated:** 2026-09-07 — initial version

This document describes the end-to-end process for bootstrapping the spec hub and then designing, implementing, and documenting any new feature or enhancement to the platform. Follow it in order — each step is a prerequisite for the next.

---

## Quick Reference

```
0. BOOTSTRAP → Once per project (`scripts/bootstrap.sh init` + `bootstrap-specs` skill): detect the repos, write spechub.conf, extract fact sheets, generate every spec, the overview, CONVENTIONS.md, STATUS.md and repo-instructions/
1. DESIGN    → Create Features/FEATURE-{name}.md
2. CASCADE & PROMPT → One session, one pass (`cascade-and-prompt` skill): 2a update the relevant service spec(s) + STATUS.md row; 2b generate Prompts/PROMPT-{service}-{feature}.md (one per service) from the cascaded spec; the cascade summary comes back with the prompts
3. IMPLEMENT → Dispatch all prompts from the hub (`dispatch-prompts` skill → `scripts/dispatch.sh`): one worktree + headless session per prompt, in parallel; services restart from the worktrees; verify by hand
4. CLOSE     → Merge branches into the base branch (services back on main checkouts, worktree folders deleted), update specs + STATUS.md + CHANGELOG, sync repo instructions, archive feature file & prompts
```

**One step per session, one model per step.** See [Context Budget](#context-budget) — it is part of the process, not advice.

---

## Context Budget

Token spend in this workflow is dominated by the hub sessions in this workspace, not by the dispatched implementation runs: a single hub session that runs design, cascade, prompts, dispatch and close-out can cost several times the tokens of the implementation runs combined, on the most expensive model, because every turn re-reads a context that has grown past a few hundred thousand tokens. These rules keep each session small and put the cheap models on the mechanical steps.

| Rule | Detail |
|---|---|
| **One step per session** | End the session at every step boundary — each skill ends by saying so. Never chain design → cascade → dispatch → close in one session. |
| **Model per step** | Three tiers, mapped to concrete models per agent CLI in `spechub.conf`: **Light** (cheapest), **Standard**, **Advanced** (strongest reasoning). Step 0 bootstrap: Standard (writers forked per service). Step 1 design: Advanced. Step 2 cascade & prompt: Standard — switch the session model before invoking the skill. Step 3 dispatch and Step 4 close-out: Standard, forked into the `hub-ops` subagent where the tool supports it; the main session receives only the report. |
| **Read only what the skill lists** | Each skill names its required reads. Do not open `WORKFLOW.md`, `00-architecture-overview.md`, or unrelated specs "for context". Index files route to module files; never read a whole split spec. |
| **Delegate reconnaissance** | Reading code in a service repo (Step 1 design questions, Step 4 drift check) goes to an `Explore` subagent that returns a summary, not the files. |
| **Size caps** | Feature file ≤ 8 KB (enhancement) / ≤ 15 KB (new module). Prompt ≤ 8 KB / ≤ 12 KB. Changelog entry ≤ 900 characters. Spec `Last updated` line ≤ ~200 characters, naming the latest change only. Module file 50–400 lines. |
| **Copy, don't retype** | Contract tables in a prompt are extracted mechanically from the cascaded spec (`sed -n`/`awk` into the prompt file), never re-authored by the model. |
| **Never read the changelog** | `scripts/changelog.sh add "<entry>"` prepends the entry. `CHANGELOG.md` is not opened in a session. |
| **Search scope** | Exclude `archive/`, `bootstrap/`, `Features/Implemented/`, `Features/Staled/` and `Prompts/Implemented/` from repo-wide greps unless the task is explicitly about history. |

---

## Step 0 — Bootstrap the Hub (once per project)

**Run `scripts/bootstrap.sh init`, then the `bootstrap-specs` skill.**

The hub starts from the code, not from a blank page. The script does the deterministic part; the skill does the transcription.

1. `scripts/bootstrap.sh init <repos-root>` (or a list of repo paths) discovers the git repos, detects each one's stack from its manifest (`package.json`, `pom.xml`, `build.gradle`, `pyproject.toml`, `go.mod`, `Cargo.toml`, `*.csproj`, `Gemfile`, `composer.json`, …), writes `spechub.conf` (project name, base branch, one `name|dir|start|port|label|group|install` row per service), inserts the services table into `CLAUDE.md`, installs dependencies, and writes one **fact sheet** per service to `bootstrap/facts/{service}.md`. Review `spechub.conf` before going on: delete repos that are not services, fix a command or a port, reorder the rows — the order is the spec numbering.
2. A fact sheet is a mechanical extraction — `find`/`grep`/`sort` in a fixed section order: identity, stack, layout, source modules, route declarations, model files and declarations, referenced env vars, dependencies, config files, file counts, README head. The same commit yields the same sheet byte for byte; the sheets are committed so a re-run shows as a diff. Route, model and env-var patterns of every supported framework run over every source file, so detection does not have to be right for the extraction to be complete.
3. `scripts/bootstrap.sh plan` prints the spec plan: number, spec file, module count, and whether the spec is a single file or **split** (index + `NN-{service}/` directory with `00-core.md`, `01-conventions.md`, one file per module) — more than 8 source modules splits (`SPECHUB_SPLIT_THRESHOLD`).
4. In a fresh session on a Standard-tier model, invoke the `bootstrap-specs` skill. It forks one `spec-writer` subagent per service, in parallel; each reads only its fact sheet and the files the sheet names, in a fixed order, and fills `templates/SERVICE-SPEC-TEMPLATE.md` under the **determinism contract** (headings verbatim and in order, every row traceable to the sheet, fixed sort orders, identifiers verbatim, two sentences of prose per section, unresolved items only in Known Issues & Gaps). Each writer also seeds `repo-instructions/{service}.md`. The main session then assembles `00-architecture-overview.md`, `CONVENTIONS.md` and an empty `STATUS.md` from the writers' fixed-format reports, and runs one writer twice on the smallest service to diff the result.
5. Commit. Copy each `repo-instructions/{service}.md` into its repo as the instruction file. From here on the hub is the source of truth; the repos are implementation targets.

**Greenfield projects.** Create the empty repos with their framework scaffolds first (the manifests are what detection reads), run `init`, and let Step 0 write thin specs; every feature then goes through Steps 1–4. A brownfield project runs the same commands on its existing repos.

> **Why fact sheets instead of letting the model read the repos?** Two sessions reading a codebase freely read different files in a different order and write different documents. A fixed extraction, a fixed reading order and a fixed template make the *tables* — the part the prompts are built from — repeatable; only the prose varies, and the template caps the prose.

---

## Step 1 — Design the Feature

**Create `Features/FEATURE-{name}.md`** (`templates/FEATURE-TEMPLATE.md`)

Before touching any spec or writing any code, document the feature in the `Features/` folder. This file is the scratchpad where all design decisions are made before they become commitments.

A feature file should cover:

- **Description** — what the feature does from the user's perspective
- **Scope** — which services are affected (service identifiers from `spechub.conf`)
- **Data model** — field names, types, defaults and indexes for any new or changed schema / entity
- **API shape** — endpoint paths, HTTP methods, guards, request/response shape
- **Frontend contract (when applicable)** — views/routes affected, component/state ownership, loading/empty/error states, responsive behavior expectations
- **Backend contract (when applicable)** — module boundaries, schema/index changes, validation/auth rules, side effects (file writes, events, jobs), and failure semantics
- **Open design decisions** — questions that need an answer before implementation can start (storage strategy, access control rules, edge cases)
- **Implementation order (cross-service features)** — one line declaring the dependency order across services, e.g. `Implementation order: api → web`. This line is carried into every generated prompt so sequencing is never implicit.
- **Outstanding work** — a checklist of things still to build
- **Recommended model tier (per service)** — for each affected service, suggest the tier to implement it with a one-line reason. Default to the cheapest tier that fits; reserve the top tier for genuinely complex work (usually complex UI). Tiers: **Light** for simple/backend-only or config/data changes; **Standard** for standard features with moderate logic or light UI; **Advanced** for complex UI stories. This recommendation carries forward into the generated prompt (Step 2b).

**Keep the file small.** Target ≤ 8 KB for an enhancement and ≤ 15 KB for a new module: contracts and decisions, with the rationale for each decision in a few lines, not an essay. The feature file is re-read in Step 2 and archived forever, so every kilobyte here is paid several times. When the design needs facts from a service repo (how something is wired, what a schema holds today), ask an `Explore` subagent for a summary instead of reading the files into the design session. This is the one step that runs on an Advanced-tier model — end the session when the file is written.

> **Why a separate file?** The service spec files describe the *implemented* state of the system. Mixing in-progress design with settled implementation facts pollutes the specs and makes prompt generation unreliable. The `Features/` file is the safe workspace for thinking; once decisions are final, they graduate into the spec. The feature file is archived to `Features/Implemented/` after implementation.

---

## Step 2 — Cascade & Prompt

**Update the service spec(s), then create `Prompts/PROMPT-{service}-{feature}.md` (one per affected service) — in one session, in that order**

Open a **new agent session** in this workspace, switch to a Standard-tier model (this step is transcription, not design), and use the `cascade-and-prompt` skill (`skills/cascade-and-prompt/`), which encodes this step's required reads, ordering, and prompt structure. Both halves read exactly the same files — `CONVENTIONS.md`, the relevant service spec (index + `00-core.md` + the affected module file(s) for a split spec), not every module — which is why they share a session. They are still two ordered sub-steps — spec on disk first, prompts transcribed from it — but they run in one uninterrupted pass: the session does not stop for a review between them.

### 2a. Cascade into the service specs

Once design decisions are confirmed (the feature file has no open design decisions left), write the feature into the relevant service spec(s) as if it were already implemented. This means adding the module, endpoints, schema, state slice, views, and any file/storage changes in the precise format the rest of that spec uses, each marked `<!-- PENDING: {feature} -->` until Step 4 reconciles it against the built code.

For a split spec: cascade into the relevant **module file(s)**. A new module gets its own file in the directory plus a row in the index file's File Map. Never re-add module content to the index.

Also add a new row for the feature to the `STATUS.md` board (next sequential number; each affected service Pending).

**Cascade summary — record, don't pause.** Note every spec file touched (with the `PENDING` contracts added), any index-table row, the `STATUS.md` row, and every place the cascade adapted the feature file's proposal to an existing spec convention. This summary is the first part of the step's final report, next to the generated prompts; the session continues straight into 2b. The review happens once, on spec and prompts together, before Step 3 is started in its own session — a wrong name found then is fixed in the spec and the affected prompt regenerated (cheap, on the Standard tier). If the user explicitly asks for a checkpoint after the cascade, stop there instead.

> **Why write the spec before the prompt?** The implementation prompt is generated *from* the spec. If the spec is vague or incomplete, the prompt will be too, and the agent will invent conventions. Writing the spec first forces every decision to be explicit — field names, validation rules, access control — which is exactly what the agent needs to produce correct code on the first pass.

### 2b. Generate the implementation prompts

**Re-read the cascaded spec file(s) from disk before writing a prompt.** The prompt is generated *from the spec*, never from the feature file. Where the cascade had to adapt a name or shape to the spec's existing conventions, the spec text is the one the implementing session must receive — transcribing from memory of the feature file is how the two diverge.

Each prompt must be **stateless and self-contained** (`templates/PROMPT-TEMPLATE.md`), and must open with this **dispatch header**:

```markdown
> **Target repo:** {absolute local path}
> **Branch:** feature/{kebab-name}
> **Prerequisites:** {PROMPT-file(s) this one depends on — sets verification and merge order, or "none"}
> **Status:** Generated   <!-- Generated → Applied → Verified -->
> **Recommended model:** {tier} — {one-line reason}
```

The status line makes `Prompts/` a dispatch board: `Generated` (not yet applied), `Applied` (implemented, awaiting human verification), `Verified` (verified in the repo; ready for Step 4). The dispatcher flips `Generated → Applied` automatically in Step 3; a human flips `Applied → Verified` (`scripts/dispatch.sh verify`). The `Recommended model` line is read by the dispatcher and selects the model of the headless session, so it must start with the tier name (`Light`, `Standard`, or `Advanced`); `spechub.conf` maps the tier to a concrete model for the chosen agent CLI.

| Prompt section | What it contains |
|---------------|-----------------|
| Files to study | Existing files in the service repo the agent should read for patterns |
| Files to create | Exact file paths to create or modify |
| Schema contract | Field names, types, defaults, and indexes — no ambiguity |
| Endpoint definitions | Method, path, guard, request body, response shape |
| Pattern references | "Follow the same structure as `{existing module}`" |
| Naming rules | Class/DTO names, state slice name, action types, route strings — verbatim from the spec |
| Build, test, lint | The repo's commands; lint only the changed files |

**Size and copy rules.** A prompt is ≤ 8 KB for an enhancement and ≤ 12 KB for a new module. Its schema, endpoint and naming tables are **copied mechanically** from the cascaded spec file (extract the section with `sed -n` / `awk` into the prompt file), never retyped or paraphrased — that is both cheaper and the only way the prompt cannot drift from the spec. Narrative is limited to the Context paragraph; everything else is tables, file lists, and acceptance criteria.

Additionally, include service-specific detail:

- **Backend prompts must specify** schema/index rules, input validation constraints, auth/guard behavior, endpoint error/status semantics, and required test updates.
- **Frontend prompts must specify** backend prerequisites/dependencies, route/view/component changes, state-management updates, UX states (loading/empty/error/permission), and acceptance criteria.

For cross-service features, generate one prompt per service. The frontend prompt must explicitly declare the backend prompt as a prerequisite (in the dispatch header's `Prerequisites:` line), and the feature file's `Implementation order` line must be reflected across the set of prompts.

**Prerequisites do not gate implementation.** Every prompt is generated from the spec, not from another service's code, so all prompts of a feature are dispatched at the same time in Step 3. The `Prerequisites:` line defines the order in which prompts are *verified* (Step 3) and *merged* (Step 4a): a frontend is verified against its already-verified backend.

> **Why one prompt per service?** Each service repo is a separate Git context. Applying everything in one prompt would require the agent to context-switch between two entirely different codebases in the same session, which degrades quality. Isolated prompts keep the agent focused on one codebase at a time and make the output easier to review.

---

## Step 3 — Implement

**Dispatch the prompts from the hub — one git worktree and one headless session per prompt, all in parallel**

In this workspace, use the `dispatch-prompts` skill (`skills/dispatch-prompts/`), which drives `scripts/dispatch.sh`. Every prompt with `Status: Generated` is dispatched at once — including prompts whose prerequisites are not implemented yet (prerequisites order verification, not implementation).

```bash
scripts/dispatch.sh status                # dispatch board (state + last run per prompt)
scripts/dispatch.sh run --all             # dispatch every Generated prompt in parallel; returns at once
scripts/dispatch.sh wait                  # block until every session has finished; exit 1 if any failed
scripts/dispatch.sh run --all --dry-run   # show the plan, touch nothing
```

What the dispatcher does for each prompt:

1. Reads the dispatch header: target repo, branch, recommended model.
2. In the target repo, creates the branch **from the base branch** (`BASE_BRANCH` in `spechub.conf`) and checks it out in its own git worktree at `<repo>-worktrees/<branch>`, so parallel prompts on the same repo never share a working tree and the repo's main checkout is untouched. Gitignored local files (`WORKTREE_COPY_FILES`) are copied in, dependency directories (`WORKTREE_LINK_DIRS`) are linked from the main checkout, and, for Claude Code, the worktree path is pre-registered as trusted in `~/.claude.json` so the headless session does not die on the trust dialog.
3. Runs a headless coding-agent session in that worktree (`AGENT_CLI` in `spechub.conf`: Claude Code `claude -p`, Codex `codex exec`, or Copilot `copilot -p`) with the prompt file as its input and the model mapped from the header's tier. The sessions run under a **detached supervisor** (own process group, reparented to init): `run` returns immediately, and the agent turn, Bash tool timeout, or terminal that launched it can end without killing the work. `scripts/dispatch.sh wait` blocks until they finish. Tool use is pre-approved for the run (Claude Code: `acceptEdits` plus an allowlist of build, test, lint, git and shell commands for every supported stack, capped at `DISPATCH_MAX_TURNS`; Codex: `--full-auto`; Copilot: `--allow-all-tools`); **pushing is never allowed**. The session follows the repo's own instruction file (`AGENTS.md` / `CLAUDE.md`), implements, builds and tests, lints **only the files it changed**, commits on the branch, and ends with a `DEVIATIONS` section.
4. Flips the header `Status:` to `Applied` and appends a **Dispatch Run Report** to the prompt file: worktree, base commit, session ID, turns/cost, commits, log path, agent summary. A failed run leaves the prompt `Generated` with `Result: ERROR` and a one-line `Diagnosis`; a session that was killed before reporting is recorded as `ABORTED` by the next `wait`/`status`, with its leftover edits stashed in the worktree. **A run cannot fail silently**: the board's LAST RUN column and `wait`'s exit code always say what happened.
5. When every session has finished, puts the applied worktrees on the air through `scripts/stack.sh`: the rest of the stack is started if it is not running, and each affected service is restarted from its worktree (`stack.sh restart <service> -w <branch>`). Nothing has to be switched by hand before verifying. `scripts/dispatch.sh serve <prompt>|--all` repeats this on demand; `--no-serve` or `DISPATCH_SERVE=none` turns it off.

Rules:

- **Launch, then wait.** `run` and `resume` return at once; block with `scripts/dispatch.sh wait` (exit 0 all ok, 1 a run failed or was killed, 2 still running with `--timeout`). A prompt still `Generated` after `wait` has failed — the report entry says why. The `workspace has not been trusted` line in a run's stderr log is harmless (the repo's own settings allow-list is ignored; the dispatcher passes its own).
- **Verified stays human.** The dispatcher never flips `Verified`. With the services already running from the worktrees, review each prompt (diff read, build run, endpoints/UI exercised) in the feature's implementation order, then run `scripts/dispatch.sh verify <prompt>`. Only `Verified` prompts graduate to Step 4.
- **Bug fixes go to the same session.** `scripts/dispatch.sh resume <prompt> "<what to fix>"` continues the recorded session ID in the same worktree, so the model keeps the full implementation in context, then restarts that service from the worktree. For interactive debugging, resume the session inside the worktree with your CLI (`claude --resume <session-id>`, `codex resume <id>`, `copilot --resume <id>`).
- **Never implement in the repo's main checkout.** All work lives on the feature branch in its worktree until Step 4a merges it and deletes it.
- **Fallback: manual session.** A prompt that genuinely needs an interactive session can still be applied by hand — open a session inside the worktree the dispatcher created (or create one: `git worktree add -b <branch> <repo>-worktrees/<branch> <base>`), apply the prompt, commit, and flip `Status:` to `Applied` yourself. Step 4a merges it the same way.

> **Why hub-dispatched instead of a manual session per repo?** One codebase per context and no carry-over between prompts are exactly what a fresh headless process with its working directory in the service worktree provides. Centralizing the trigger adds what cannot be done by hand: every prompt starts at the same time, every run is logged against its prompt, and the session ID is kept so follow-ups land in the same context.

---

## Step 4 — Close the Loop

After the implementation is verified, do all of the following **in a single pass** (open a new session in this workspace and invoke the `close-loop` skill, `skills/close-loop/`, which encodes this checklist and, where the tool supports it, runs as a forked `hub-ops` subagent on the Standard tier — the main session only receives the report):

### 4a. Merge each Verified branch into the base branch
- Run `scripts/dispatch.sh merge --all` (or `merge <prompt>` per prompt, in the feature's implementation order). For each `Verified` prompt it merges the feature branch into the base branch in the target repo with a `--no-ff` merge commit, stops the service if it is running from the worktree, removes the worktree, deletes the feature branch, restarts that service from the main checkout, and appends a **Merged** entry (merge commit + implementing commit SHAs) to the prompt's run report. Pushing is opt-in (`--push`).
- **The worktree folders must be gone when the loop closes.** `merge` ends by sweeping the affected repos' `<repo>-worktrees/` folders; `scripts/dispatch.sh clean` runs the same sweep across every service repo at any time (`--force` also removes registered worktrees); the close-out ends with it and reports any root still present.
- The merge refuses to run if the prompt is not `Verified`, if the repo's main checkout is dirty, or if the merge conflicts — resolve by hand and re-run.
- After this step every affected repo is back on a clean base branch that contains the feature. The implementing SHAs recorded here are the changelog's traceability refs (4d).

### 4b. Update the service spec(s)
- **Verify against the code, not memory.** For each affected service, read the implementation in the service repo itself (the path in the prompt's dispatch-header `Target repo:` line, now on the base branch): the files the prompt named — schema, controller/routes, components — and the full diff of the merge (`git diff <merge>^1..<merge>`). Delegate this reading to an `Explore` subagent where available: it returns the contract facts and the list of deviations, and the service files never enter the hub context. Every file touched must be accounted for: a contract change in a file the prompt did not name is still a deviation. Reality wins: reconcile the spec to the code, and record each deviation for the changelog entry. The prompt's run report also lists the `DEVIATIONS` the implementing session reported.
- For a split spec: reconcile the affected **module file(s)**; update the index File Map only if a module was added, renamed, or removed.
- Update the `Last updated` header at the top of the spec file — **one line of at most ~200 characters naming this feature only**. Never chain `Prior (...)` entries into it, and do **not** append a per-feature log/history entry to the spec; that record belongs only in `CHANGELOG.md` (see the single-log rule below).

### 4c. Update the status board (and overview only if needed)
- In `STATUS.md`, mark every service cell of the feature row ✅ and move it from the **In Flight** section to **Shipped**.
- **Keep the Notes cell to a single line.** The board is a status index, not a record — implementation detail belongs in `CHANGELOG.md` and the archived design doc, never in the Notes column.
- Touch `00-architecture-overview.md` only if the feature changed system-wide architecture (components, communication, tenancy, auth). If touched, bump its `Last Updated:` line.
- **Do not add a log/history entry to the overview or STATUS.md.** The overview describes the *current* system, not its history; the running log lives in `CHANGELOG.md` only.

### 4d. Update the changelog
- Run `scripts/changelog.sh add "<Feature> (#n) implemented and closed across <services>: what shipped; notable deviations. (api@sha, web@sha)"`. The script prepends the dated entry under the header — **never open `CHANGELOG.md`** to do this.
- **One entry per feature, at most 900 characters** (the script refuses longer ones): what shipped, the deviations that matter, the commit refs. Design rationale stays in the archived feature file; the dispatch trace stays in the archived prompt's run report.
- **Include a traceability reference:** the implementing commit SHA(s) or PR link(s) in each affected service repo, e.g. `(api@a1b2c3d, web#124)` — recorded by the merge in 4a. This is what lets you reconstruct, months later, exactly which code a spec change produced.
- Entries older than a quarter are rolled into `archive/CHANGELOG-archive.md` with `scripts/changelog.sh archive <YYYY-MM-DD>` (do it when the file passes ~100 KB).

> **Single-log rule.** `CHANGELOG.md` is the *only* document that accumulates dated log entries — **one per feature, written at close-out**. Design and cascade add no entries; `STATUS.md` carries the in-flight state. All other documents stay clean and describe only their current state:
> - `00-architecture-overview.md` — header carries `Version` + a single `Last Updated:` line, nothing more.
> - Service specs (including split indexes and their module files) — each carries only its own one-line `Last updated` at the top.
> - Never paste a running history block into the overview or a service spec. If you catch one accumulating, fold the entries back into `CHANGELOG.md` and delete the block.

### 4e. Archive the feature design file
- Move `Features/FEATURE-{name}.md` to `Features/Implemented/`. Its *contracts* now live in the service spec, but its *design rationale* (the "why", confirmed/open decisions, alternatives considered) is not captured anywhere else and is worth keeping.
- Add this banner to the top of the archived file so it is never mistaken for a live document:
  ```markdown
  > **ARCHIVED — historical design record. NOT a source of truth.**
  > Implemented YYYY-MM-DD. Current state lives in {service-spec}.md.
  > Do not edit; this captures the original design reasoning only.
  ```

### 4f. Archive the implementation prompt(s)
- Confirm each prompt's dispatch-header `Status:` is `Verified` and its run report has a **Merged** entry, then move each `Prompts/PROMPT-{service}-{feature}.md` to `Prompts/Implemented/`. Keep the run report — it is the implementation trace.

### 4g. Sync repo instruction files if conventions changed
- If the feature changed any shared convention (naming rules, module layout, storage patterns, env conventions), update `CONVENTIONS.md` and the affected canonical repo instruction file(s) in `repo-instructions/`, then copy the updated file into the service repo. The hub copies are canonical; the per-repo instruction files must never drift from them.

> **Why archive instead of delete?** An archived feature file is a *frozen historical record*, not a living document — the banner makes that explicit, which neutralizes the risk of two diverging sources of truth. The service spec remains the only place describing *what currently exists*; the archived file preserves *how the decision was reached*.

> **Why do all of these in one pass?** Steps 4a–4g are all consequences of the same event — the feature being implemented. Doing them in one session ensures they are always consistent with each other. If you update the spec but forget to archive the feature file, the next person to open `Features/` will not know whether that feature is pending or already done.

---

## Naming Conventions

| Artifact | Convention | Example |
|----------|-----------|---------|
| Service identifier | the `name` column of `spechub.conf` | `api`, `web`, `billing` |
| Service spec | `NN-{service}.md` (+ `NN-{service}/` when split) | `02-api.md`, `02-api/orders.md` |
| Fact sheet | `bootstrap/facts/{service}.md` | `bootstrap/facts/api.md` |
| Feature design file | `Features/FEATURE-{kebab-name}.md` | `Features/FEATURE-in-app-notifications.md` |
| Archived feature design file | `Features/Implemented/FEATURE-{kebab-name}.md` | — |
| Staled feature design file | `Features/Staled/FEATURE-{kebab-name}.md` | — |
| Implementation prompt | `Prompts/PROMPT-{service}-{feature}.md` | `Prompts/PROMPT-api-notifications.md` |
| Archived implementation prompt | `Prompts/Implemented/PROMPT-{service}-{feature}.md` | — |
| Feature branch | `feature/{kebab-name}` (unique per prompt) | `feature/notifications` |
| Canonical repo instructions | `repo-instructions/{service}.md` | `repo-instructions/api.md` |

---

## Session Strategy Summary

| Situation | Session | Model |
|-----------|---------|-------|
| Bootstrapping the hub (step 0) | New session; `bootstrap-specs` skill forks one `spec-writer` per service. **End the session when the files are on disk.** | Standard |
| Designing a feature (writing the feature file, step 1) | New session — the feature file is upstream of the spec and the code, so it must not inherit another feature's context. Code reconnaissance via `Explore` subagents. **End the session when the file is written.** | Advanced |
| Cascading into the specs and generating prompts (step 2) | New session — one session for both halves, `cascade-and-prompt` skill. **End the session when the prompts are on disk.** | Standard |
| Dispatching prompts (step 3) | New session; `dispatch-prompts` skill runs forked in a `hub-ops` subagent — the main session gets the report | Standard |
| Implementing any prompt (backend or frontend) | Headless session dispatched from the hub (`scripts/dispatch.sh run`), in its own worktree; all prompts of a feature run in parallel | Per the prompt header (Light by default) |
| Verifying a dispatched prompt | Human, against the services the dispatcher restarted from the worktrees, in implementation order; then `scripts/dispatch.sh verify` | — |
| Fixing a bug in the current implementation | Same session, resumed: `scripts/dispatch.sh resume <prompt> "<fix>"` | Per the prompt header |
| Interactive debugging of a dispatched prompt | Resume the session inside the worktree with your CLI (session ID is in the run report) | Per the prompt header |
| Closing the loop (step 4) | New session; `close-loop` skill runs forked in a `hub-ops` subagent | Standard |
| Answering a question about what was just built | Resume the prompt's session | Per the prompt header |

---

## Staled Features

`Features/Staled/` holds feature designs that are **parked**: not being worked on, not implemented, but not discarded. It is a third lifecycle state alongside pending (`Features/`) and shipped (`Features/Implemented/`).

- **When to stale:** a pending feature is deprioritized indefinitely, superseded by another design, or blocked on a decision that will not be made soon. Move the file to `Features/Staled/` and add a one-line note at top: date staled + reason.
- **Status board:** update the feature's `STATUS.md` row to `⏸ Staled` (or remove the row if it never left design). Remove any `PENDING` markers the feature added to service specs during Cascade — staled designs must not linger in the source of truth.
- **Reviving:** a staled feature must be **re-validated before reuse**. The specs have moved since it was written; re-read the current spec / module file(s) it touches, correct the design against them, then move it back to `Features/` and restore its `STATUS.md` row to Pending. Never generate prompts directly from a staled file.

---

## Enhancements vs. Full Features

The same workflow applies to both. The difference is only in scope:

- **Enhancement** — modifies an existing module (new field, new endpoint, changed validation). Step 1 and the cascade half of Step 2 may be very lightweight (a few lines in the feature file, a targeted spec edit). Generate a focused prompt that references the file being changed.
- **New feature** — new module, new schema, new views. All four steps apply in full.

Do not skip the feature file step for enhancements. Even a small change should be written down before generating a prompt — it forces the decision to be explicit and leaves a record of why the change was made.
