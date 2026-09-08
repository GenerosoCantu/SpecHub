# SpecHub

A spec-driven workflow for building software with coding agents. The hub — this folder — is the source of truth for what your system does; the service repos are implementation targets. Every feature goes design → spec → prompt → headless implementation in a git worktree → reconciliation, and the hub is what keeps the agents honest across repos and sessions.

It is **stack-agnostic**: the scripts detect Node (NestJS, Next.js, React, Angular, Vue, Express, …), Java/Kotlin (Spring Boot, Maven, Gradle), Python (FastAPI, Django, Flask), Go, Rust, .NET, Ruby and PHP repos, and the spec generation runs the same way on all of them. No per-technology connector: detection only decides how to start and install a service; the specs come from a fixed, mechanical fact extraction plus a fixed template.

It is **agent-agnostic**: the instructions live in `AGENTS.md`, the workflow steps are Agent Skills (`skills/`, symlinked into `.claude/`, `.github/` and `.codex/`), and the dispatcher runs implementation prompts with Claude Code, OpenAI Codex CLI or GitHub Copilot CLI (`AGENT_CLI` in `spechub.conf`). Models are named by tier — **Light**, **Standard**, **Advanced** — and mapped to concrete models per CLI in the same file.

## What SpecHub is

A **human-gated, agent-executed, spec-driven development framework.**

- **Spec-driven** — the hub's markdown is the source of truth; code is derived from it, never the reverse. A feature enters as a design file, becomes `PENDING` contracts in the service spec, and only then becomes a prompt. After implementation the spec is reconciled against the real diff, so it stays authoritative instead of decaying into documentation.
- **Agent-executed** — agents do the mechanical work at every step: Standard-tier writers generate the specs, a Standard-tier session cascades and writes the prompts, headless coding-agent sessions implement each prompt in an isolated git worktree, and a forked subagent merges and reconciles. The scripts orchestrate those agents and record every run in the prompt file itself, so a run cannot fail silently.
- **Human-gated** — two gates stay human on purpose. Design is a person working with an Advanced-tier model, and nothing becomes `Verified` until a person has exercised the running services. The scripts never flip that status and never merge an unverified branch.

What sets it apart from other spec-driven approaches: a written determinism contract for generated specs, a one-step-per-session context budget that keeps every hub session small and puts cheap models on the mechanical steps, and one worktree plus one headless session per prompt with the run report written back into the prompt.

## What you get

| Piece | Purpose |
|---|---|
| `scripts/bootstrap.sh` | Discovers your repos, detects their stacks and your installed agent CLI, writes `spechub.conf`, installs dependencies, extracts one deterministic **fact sheet** per service |
| `bootstrap-specs` skill | Writes one spec per service (parallel writers), the architecture overview, `CONVENTIONS.md`, `STATUS.md` and the canonical repo instruction files — from the fact sheets only |
| `WORKFLOW.md` + 3 more skills | The feature loop: design (Advanced) → `cascade-and-prompt` (Standard) → `dispatch-prompts` → `close-loop` |
| `scripts/dispatch.sh` | Runs each prompt as a detached headless session of your agent CLI in its own worktree, in parallel; records every run in the prompt file; merges verified branches and cleans up |
| `scripts/stack.sh` | Starts/stops every service in `spechub.conf`, from the main checkout or from a feature worktree |
| `scripts/changelog.sh` | The only way the changelog is written — one ≤ 900-char entry per feature |
| `templates/` | The fixed shapes of every document; the determinism contract lives in their headers |
| `AGENTS.md`, `CLAUDE.md`, `.github/copilot-instructions.md`, `.github/agents/` | One canonical instruction file, with the pointers and agent wrappers each tool expects |

## Supported agents

| Tool | Instructions | Skills | Subagents | Headless dispatch |
|---|---|---|---|---|
| Claude Code | `CLAUDE.md` → `@AGENTS.md` | `.claude/skills` | `.claude/agents/` (`context: fork`) | `claude -p` — exercised end to end |
| OpenAI Codex CLI | `AGENTS.md` | `.codex/skills` | run the skill in a fresh session | `codex exec --full-auto --json` |
| GitHub Copilot | `.github/copilot-instructions.md` → `AGENTS.md` | `.github/skills` | `.github/agents/*.agent.md` | `copilot -p --allow-all-tools` |
| Anything else that reads `AGENTS.md` | `AGENTS.md` | open `skills/<name>/SKILL.md` as a checklist | fresh session | set `AGENT_BIN`, add a `run_<cli>()` case to `run_headless()` in `scripts/dispatch.sh` |

The Claude Code adapter is the one tested end to end. The Codex and Copilot adapters follow those CLIs' documented non-interactive flags; if a flag differs in your version, the whole adapter lives in `scripts/dispatch.sh`: `run_headless()` (one `run_<cli>()` per CLI) and `summarize_run()`.

## Requirements

- macOS or Linux, bash 3.2+, git, `lsof`, python3 (used by `dispatch.sh` and `changelog.sh`)
- One agent CLI on PATH: `claude` ([Claude Code](https://claude.com/claude-code)), `codex` ([Codex CLI](https://github.com/openai/codex)) or `copilot` ([Copilot CLI](https://github.com/github/copilot-cli))
- The toolchains of your services (node, java, python, …) for `stack.sh` to run them

## Workflow at a glance

| Step | In plain terms |
|---|---|
| 0. Bootstrap | Point the hub at your repos once; it detects stacks and writes a spec for every service. |
| 1. Design | You and an agent describe a feature in one file: what should change, and where. |
| 2. Cascade & Prompt | That file is folded into the specs, then turned into implementation prompts per service. |
| 3. Implement | Each prompt is dispatched as its own headless agent session in a fresh git worktree; you check the result by hand. |
| 4. Close | Verified work is merged back, the specs and changelog are updated, and the feature file is archived. |

Steps 1–4 repeat for every feature. See `WORKFLOW.md` for the full detail behind each step.

## Quick start

**Step 0 — once per project:**

```bash
git clone https://github.com/GenerosoCantu/SpecHub.git my-platform-specs
cd my-platform-specs
scripts/bootstrap.sh init ~/projects/my-platform --name "My Platform"   # detect repos + agent CLI, write spechub.conf, install, extract facts
$EDITOR spechub.conf                                                    # drop non-services, fix commands/ports; order = spec numbering
scripts/stack.sh start && scripts/stack.sh status                       # check the stack runs from the hub
<your agent>                                                            # in the hub, Standard tier: run the bootstrap-specs skill
git add -A && git commit -m "spec hub: bootstrap"                       # commit; then copy repo-instructions/{service}.md into each repo (see repo-instructions/README.md)
```

**Steps 1–4 — once per feature, one session per step:**

```
Step  Who                  Run                                  Result
1.    agent (Advanced)     design Features/FEATURE-{name}.md    the feature file (WORKFLOW.md Step 1)
2.    agent (Standard)     cascade-and-prompt {name}            spec edits + Prompts/PROMPT-{service}-{name}.md
3.    agent (Standard)     dispatch-prompts                     headless sessions in worktrees; services restart from them
      you                  scripts/dispatch.sh verify <prompt>  after checking the running services by hand
4.    agent (Standard)     close-loop {name}                    merge, reconcile specs, STATUS, CHANGELOG, archive
```

In Claude Code the skills are slash commands (`/cascade-and-prompt`); in Copilot and Codex they are discovered from the symlinked skill folders; anywhere else, open the skill file and follow it. `scripts/dispatch.sh status` is the board at any time.

## How the spec generation stays repeatable

- `bootstrap.sh facts` is pure `find`/`grep`/`sort` in a fixed order with C-locale sorting: the same commit produces the same `bootstrap/facts/{service}.md` byte for byte. The sheets are committed, so re-runs show up as diffs.
- Each spec is written by a writer that reads only its fact sheet and the files the sheet names, in a fixed order, into a fixed template under a written **determinism contract** (headings verbatim, every row traceable, fixed sort orders, identifiers verbatim, two sentences of prose per section, unknowns only in Known Issues & Gaps).
- The split decision (single file vs index + per-module directory) is a number: more than 8 source modules.
- The skill ends by running one writer twice on the smallest service and diffing: tables must match; only wording may differ.

Run it twice on the same commit and you get the same tables and the same file set. Wording drifts; contracts don't.

## Layout

```
spechub.conf                        project, base branch, agent CLI + model tiers, repos root, service table
spechub.conf.example                annotated example of the above (bootstrap.sh init writes the real one)
AGENTS.md                           agent routing for this workspace (services table maintained by the script)
CLAUDE.md                           pointer to AGENTS.md (Claude Code)
.github/copilot-instructions.md     pointer to AGENTS.md (Copilot)
WORKFLOW.md                         Steps 0–4, context budget, naming, session strategy
SPEC-GUIDELINES.md                  what goes in the overview vs a service spec
CONVENTIONS.md                      shared conventions (generated in Step 0)
STATUS.md                           live feature status board
CHANGELOG.md                        implementation history (written only by scripts/changelog.sh)
00-architecture-overview.md         system map (generated in Step 0)
NN-{service}.md [+ NN-{service}/]   one spec per service (split into a directory when large)
Features/                           pending feature designs (Implemented/ and Staled/ archives inside)
Prompts/                            active implementation prompts (Implemented/ archive inside)
repo-instructions/                  canonical AGENTS.md for each service repo
templates/                          fixed shapes of every document
bootstrap/facts/                    generated fact sheets, one per service
archive/                            rolled changelog entries and old material — not a source of truth
skills/                             bootstrap-specs, cascade-and-prompt, dispatch-prompts, close-loop
                                    (symlinked from .claude/skills, .github/skills, .codex/skills)
scripts/                            bootstrap.sh, stack.sh, dispatch.sh, changelog.sh
.claude/                            settings.json, agents/{spec-writer,hub-ops}.md
.github/agents/                     Copilot wrappers for the same subagents (*.agent.md)
```

## One repo per service, or a monorepo

A service is a directory: a git repo root, or a folder inside a monorepo. `bootstrap.sh init` discovers workspace members (`package.json` workspaces, `pnpm-workspace.yaml`, `apps/*`, `packages/*`, `services/*`, Maven modules, Gradle includes, Go `cmd/*`) and skips libraries without a start script. Worktrees are always made of the git root; a monorepo service runs from the same folder inside the worktree, and its prompt carries a `Service:` header so the dispatcher knows which subtree it owns and which service to restart. Two prompts on the same monorepo get two branches and two worktrees, as with separate repos. pnpm workspaces keep per-package `node_modules`, so set `DISPATCH_DEPS=install` for those.

## Greenfield or brownfield

Both run the same five commands. For a brand-new system, scaffold the empty repos with their frameworks first (the manifests are what detection reads), bootstrap thin specs, and grow them feature by feature. For an existing system, the fact sheets carry every route, model and env var the code references, and the specs describe what is actually there — gaps and all.

## License

MIT — see `LICENSE`.
