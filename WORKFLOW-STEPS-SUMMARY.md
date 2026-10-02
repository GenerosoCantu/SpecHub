# SpecHub Workflow — Steps at a Glance

Condensed from [WORKFLOW.md](WORKFLOW.md). Rule: **one step per session, one model per step.**

Tier → model (Claude CLI defaults in `scripts/dispatch.sh`, override in `spechub.conf`): **Light = Haiku · Standard = Sonnet · Advanced = Opus**.

| Step | What it does | Session | Model |
|---|---|---|---|
| **0 — Bootstrap** (once per project) | `scripts/bootstrap.sh init`, then `bootstrap-specs` skill: fact sheets → service specs, overview, CONVENTIONS, STATUS, repo-instructions | New session | Standard (Sonnet) |
| **1 — Design** | `lock.sh intend`, then write `Features/FEATURE-{name}.md` (contracts, decisions, per-service tier) | New session | Advanced (Opus) |
| **1 — Design (bug, Class A)** | Write `Features/BUG-{name}.md` citing the spec it violates | New session | Standard (Sonnet); Advanced if cause unknown / Class B |
| **2a — Cascade** | Claim STATUS row + locks, write the feature into the service spec(s) with `PENDING` markers | New session (shared with 2b) | Standard (Sonnet) |
| **2b — Prompts** | Generate `Prompts/PROMPT-{service}-{feature}.md` from the cascaded spec | Same session as 2a | Standard (Sonnet) |
| **Review spec + prompts** | Check cascade summary and prompts before dispatch | Human decision | — |
| **3 — Dispatch** | `dispatch-prompts` skill: one worktree + headless run per prompt, in parallel | New session (forked `hub-ops`) | Standard (Sonnet) |
| **3 — Implement** (per prompt) | Headless session in the worktree implements the prompt | Headless, auto-spawned | Per prompt header (Light/Haiku by default) |
| **3 — Verify** | Read diff, build, exercise endpoints/UI, in implementation order | Human decision | — |
| **3 — Reject / fix** | `dispatch.sh verify --fail` + `resume "<fix>"` | Resumed implementation session | Per prompt header |
| **4a — Verify + merge** | `dispatch.sh verify` + `merge`: merge to base, push, remove worktrees | New session (`close-loop`, forked `hub-ops`) | Standard (Sonnet) |
| **4b — Reconcile specs** | Drift check against merged code (Explore subagent), remove `PENDING` | Same close-loop session | Standard (Sonnet) |
| **4c — Status board** | Move STATUS row to Shipped | Same close-loop session | Standard (Sonnet) |
| **4d — Changelog** | `changelog.sh add` (≤ 900 chars, with commit SHAs) | Same close-loop session | Standard (Sonnet) |
| **4e — Archive feature file** | Move to `Features/Implemented/` + ARCHIVED banner | Same close-loop session | Standard (Sonnet) |
| **4f — Archive prompts** | Move to `Prompts/Implemented/` | Same close-loop session | Standard (Sonnet) |
| **4g — Sync repo instructions** | Update `CONVENTIONS.md` / `repo-instructions/` and copy them into repos (only if conventions changed) | Same close-loop session | Standard (Sonnet) |
| **4h — Release locks** | `lock.sh release --no-push` | Same close-loop session | Standard (Sonnet) |
| **Stale a feature** | Move to `Features/Staled/`, drop `PENDING` markers, release the lock | Human decision | — |
