# SpecHub

A spec-driven workflow for building software with coding agents. The hub — this folder — is the source of truth for what your system does; the service repos are implementation targets. Every feature goes design → spec → prompt → headless implementation in a git worktree → reconciliation, and the hub is what keeps the agents honest across repos and sessions.

It is stack-agnostic: the scripts detect Node (NestJS, Next.js, React, Angular, Vue, Express, …), Java/Kotlin (Spring Boot, Maven, Gradle), Python (FastAPI, Django, Flask), Go, Rust, .NET, Ruby and PHP repos, and the spec generation runs the same way on all of them. No per-technology connector: detection only decides how to start and install a service; the specs come from a fixed, mechanical fact extraction plus a fixed template.

## What SpecHub is

A **human-gated, agent-executed, spec-driven development framework.**

- **Spec-driven** — the hub's markdown is the source of truth; code is derived from it, never the reverse. A feature enters as a design file, becomes `PENDING` contracts in the service spec, and only then becomes a prompt. After implementation the spec is reconciled against the real diff, so it stays authoritative instead of decaying into documentation.
- **Agent-executed** — agents do the mechanical work at every step: Sonnet writers generate the specs, a Sonnet session cascades and writes the prompts, headless Claude Code sessions implement each prompt in an isolated git worktree, and a forked subagent merges and reconciles. The scripts orchestrate those agents and record every run in the prompt file itself, so a run cannot fail silently.
- **Human-gated** — two gates stay human on purpose. Design is a person working with Opus, and nothing becomes `Verified` until a person has exercised the running services. The scripts never flip that status and never merge an unverified branch.

What sets it apart from other spec-driven approaches: a written determinism contract for generated specs, a one-step-per-session context budget that keeps every hub session small and puts cheap models on the mechanical steps, and one worktree plus one headless session per prompt with the run report written back into the prompt.

## What you get

| Piece | Purpose |
|---|---|
| `scripts/bootstrap.sh` | Discovers your repos, detects their stacks, writes `spechub.conf`, installs dependencies, extracts one deterministic **fact sheet** per service |
| `bootstrap-specs` skill | Writes one spec per service (parallel Sonnet writers), the architecture overview, `CONVENTIONS.md`, `STATUS.md` and the canonical repo instruction files — from the fact sheets only |
| `WORKFLOW.md` + 3 more skills | The feature loop: design (Opus) → `cascade-and-prompt` (Sonnet) → `dispatch-prompts` → `close-loop` |
| `scripts/dispatch.sh` | Runs each prompt as a detached headless Claude Code session in its own worktree, in parallel; records every run in the prompt file; merges verified branches and cleans up |
| `scripts/stack.sh` | Starts/stops every service in `spechub.conf`, from the main checkout or from a feature worktree |
| `scripts/changelog.sh` | The only way the changelog is written — one ≤ 900-char entry per feature |
| `templates/` | The fixed shapes of every document; the determinism contract lives in their headers |

## Requirements

- macOS or Linux, bash 3.2+, git, python3 (used by two helpers), `lsof`
- [Claude Code](https://claude.com/claude-code) CLI (`claude` on PATH, or the VS Code extension — the dispatcher finds its binary)
- The toolchains of your services (node, java, python, …) for `stack.sh` to run them

## Quick start

```bash
git clone https://github.com/GenerosoCantu/SpecHub.git my-platform-specs
cd my-platform-specs
scripts/bootstrap.sh init ~/projects/my-platform --name "My Platform"   # 1. detect repos, write spechub.conf, install, extract facts
$EDITOR spechub.conf                                                    # 2. drop non-services, fix commands/ports, order = spec numbering
scripts/stack.sh start && scripts/stack.sh status                      # 3. check the stack runs from the hub
claude --model sonnet                                                  # 4. in the hub: /bootstrap-specs  → specs, overview, conventions, status, repo-instructions
git add -A && git commit -m "spec hub: bootstrap"                       # 5. commit; copy repo-instructions/{service}.md into each repo as CLAUDE.md
```

Then, for every feature, one session per step:

```
1. claude (Opus)    → design Features/FEATURE-{name}.md            (WORKFLOW.md Step 1)
2. claude (Sonnet)  → /cascade-and-prompt {name}                    spec edits + Prompts/PROMPT-{service}-{name}.md
3. claude           → /dispatch-prompts                            headless sessions in worktrees; services restart from them
   you              → verify by hand → scripts/dispatch.sh verify <prompt>
4. claude           → /close-loop {name}                            merge, reconcile specs, STATUS, CHANGELOG, archive
```

`scripts/dispatch.sh status` is the board at any time. `CLAUDE.md` tells the agent how to route inside the hub; `.github/copilot-instructions.md` points Copilot at the same file.

## How the spec generation stays repeatable

- `bootstrap.sh facts` is pure `find`/`grep`/`sort` in a fixed order with C-locale sorting: the same commit produces the same `bootstrap/facts/{service}.md` byte for byte. The sheets are committed, so re-runs show up as diffs.
- Each spec is written by a writer that reads only its fact sheet and the files the sheet names, in a fixed order, into a fixed template under a written **determinism contract** (headings verbatim, every row traceable, fixed sort orders, identifiers verbatim, two sentences of prose per section, unknowns only in Known Issues & Gaps).
- The split decision (single file vs index + per-module directory) is a number: more than 8 source modules.
- The skill ends by running one writer twice on the smallest service and diffing: tables must match; only wording may differ.

Run it twice on the same commit and you get the same tables and the same file set. Wording drifts; contracts don't.

## Layout

```
spechub.conf                    project, base branch, repos root, service table
CLAUDE.md                       agent routing for this workspace (services table maintained by the script)
WORKFLOW.md                     Steps 0–4, context budget, naming, session strategy
SPEC-GUIDELINES.md              what goes in the overview vs a service spec
00-architecture-overview.md     generated in Step 0
NN-{service}.md [+ NN-{service}/]   one spec per service (split when large)
CONVENTIONS.md  STATUS.md  CHANGELOG.md
Features/  Prompts/  repo-instructions/  templates/  bootstrap/facts/  archive/
scripts/   bootstrap.sh  stack.sh  dispatch.sh  changelog.sh
.claude/   settings.json  agents/{spec-writer,hub-ops}.md  skills/{bootstrap-specs,cascade-and-prompt,dispatch-prompts,close-loop}
```

## Greenfield or brownfield

Both run the same five commands. For a brand-new system, scaffold the empty repos with their frameworks first (the manifests are what detection reads), bootstrap thin specs, and grow them feature by feature. For an existing system, the fact sheets carry every route, model and env var the code references, and the specs describe what is actually there — gaps and all.

## License

MIT — see `LICENSE`.
