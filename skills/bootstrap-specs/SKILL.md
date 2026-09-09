---
name: bootstrap-specs
description: Step 0 — generate the whole spec hub from the fact sheets in bootstrap/facts/ (one spec per service, the architecture overview, CONVENTIONS.md, STATUS.md, repo-instructions/). Use when the user says "bootstrap", "generate the specs", "step 0", "document the repos", or after running scripts/bootstrap.sh init on a new or existing codebase.
---

> **Session rule:** this step runs on a **Standard-tier** model in a fresh session (switch the model before invoking). It is transcription from fact sheets, not design. When the files are on disk, **end the session**: the first feature (Step 1) starts a new one. Request from the user: **$ARGUMENTS** (empty: every service in `spechub.conf`; a list of service ids: only those).

# Bootstrap the Specs (Step 0)

Write the service specs, the architecture overview, the shared conventions, the empty status board and the canonical repo-instruction files from the **fact sheets** that `scripts/bootstrap.sh` extracted mechanically from the repos. The fact sheets are the only input; the source files they name are the only thing read beyond them. That is what makes a second run land on the same tables.

## 0. Required reads — in this order, nothing more

1. `spechub.conf` — project name, base branch, the services table (order = spec numbering)
2. The output of `scripts/bootstrap.sh plan` and `scripts/bootstrap.sh plan --manifest` — number, spec file, shape, and the **exact file list** each writer must produce
3. `SPEC-GUIDELINES.md` — §1 (overview) and §3 (what goes where); §2 is read by the writers
4. `templates/ARCHITECTURE-OVERVIEW-TEMPLATE.md`, `templates/CONVENTIONS-TEMPLATE.md`, `templates/STATUS-TEMPLATE.md`

Do NOT read the fact sheets, the service repos, or `WORKFLOW.md` in this session — the writers read the sheets; you assemble from their reports.

## 1. Preconditions

- `spechub.conf` exists and `bootstrap/facts/{service}.md` exists for every non-static service (`scripts/bootstrap.sh plan` says "no fact sheet yet" otherwise — run `scripts/bootstrap.sh facts`, then continue).
- The fact sheets are current: if `git -C <repo> rev-parse --short HEAD` differs from the `@ sha` in a sheet's header, regenerate that sheet first (`scripts/bootstrap.sh facts <service>`).
- **Brownfield hub:** if a target spec file already exists and the user did not ask to regenerate it, skip that service and say so. Regeneration overwrites; the user's git history is the undo.

## 2. Write the service specs — one `spec-writer` per service, all in parallel

For every service in the plan (skipping static servers), launch a `spec-writer` subagent (Claude Code: Agent tool, `subagent_type: spec-writer`; Copilot: the `spec-writer` custom agent; a tool without subagents: one fresh session per service, given `.claude/agents/spec-writer.md` as its instructions) **all at once so they run concurrently**, with this prompt — identical wording for every service, only the values change:

```
Write the spec for service `{service}` (number {NN}, shape: {single|split}, group: {group}).
Fact sheet: bootstrap/facts/{service}.md — §12 is your complete read set, in order.
Produce exactly these files and no others:
{the service's block from `scripts/bootstrap.sh plan --manifest`, one path per line}
Templates: templates/SERVICE-SPEC-TEMPLATE.md {, templates/SPEC-INDEX-TEMPLATE.md, templates/MODULE-TEMPLATE.md}
Repo instructions target: repo-instructions/{service}.md (template: repo-instructions/_TEMPLATE.md)
Project: {PROJECT_NAME}. Base branch: {BASE_BRANCH}. Today: {YYYY-MM-DD}.
Follow your agent instructions and the template's determinism contract exactly. Report in the fixed format only.
```

Wait for every writer. Each returns the fixed report; keep them — they are the input for §3–§5. If a writer fails, relaunch that one service with the same prompt; do not write its spec yourself.

**Then verify the file set before going on:** `scripts/verify.sh manifest`. It compares what is on disk against `plan --manifest`. A missing module file means the writer folded or dropped a module — relaunch that one writer naming the missing paths; never write the file yourself and never accept the shorter spec. (This is the check that catches the failure mode where a writer decides a directory like `schemas/` "is not a real module" and takes the service's only field tables down with it.)

## 3. Assemble `00-architecture-overview.md`

Fill `templates/ARCHITECTURE-OVERVIEW-TEMPLATE.md` **only from the writer reports and `spechub.conf`**, keeping every heading in order:

- §2 tables: one row per service, in `spechub.conf` order, values from `STACK`, `PURPOSE`, `HOSTING`; static servers from `spechub.conf` go in §2.3.
- §3 diagram: Mermaid `graph LR`, one node per service id in `spechub.conf` order, one edge per `DEPENDS ON` entry, subgraphs by `group`. Follow the template's node/edge rules literally — no layout choices, no extra nodes. Never hand-draw ASCII: a free-form drawing differs on every run and cannot be diffed.
- §4–§6: summarise `AUTH`, `DEPENDS ON` / `CALLED BY` across services in bullets. Tenancy: "Not applicable — single-tenant." unless a report shows tenant resolution.
- §9: one row per spec file written (index rows say "**index**; per-module specs in `NN-{service}/`").
- §10 Cross-Service Mechanisms: collect every `SHARED ARTIFACTS` line from all reports and group them by artifact. An artifact named by **two or more** services becomes one `### 10.x` entry — producer, consumers, the verbatim contract, evidence on both sides. An artifact only one service names is not a mechanism; drop it. "None — no artifact is named by more than one service." when nothing groups. This is the only place the seams between services get written down: each writer saw one repo, so a path template published by one service and read by another is invisible in both specs.
  - **One entry per artifact — never bundle.** Three CDN path templates are three entries, not one "Published CDN artifacts" entry. Grouping by theme is the largest measured source of run-to-run drift: two runs of the same repos produced 13 entries and 8, and the bundled run dropped five real service-to-service seams. If you catch yourself writing a plural thematic title, split it.
  - **Both sides must be evidenced.** `**Evidence:**` has to cite the producing repo *and* the consuming repo. An entry evidenced only from the consumer side means the producer was never opened — go read it, or drop the entry. Both measured runs failed this on at least one entry.
  - **No self-loops.** If Producer and Consumer(s) name the same single service, it is not a mechanism. `Consumer(s): readers of BANNER_CDN_URL` is not a consumer — name the service or drop the entry.
  - `scripts/verify.sh mechanisms` enforces all three; run it before you report.
- §11: every `GAPS` line, grouped Security / Data Integrity / Operational, prefixed with the service id.
- §12: one `Open` row per `AMBIGUITIES` line the writers reported; empty table otherwise.
- §1 Product Summary: from the README heads the writers used, via their `PURPOSE` lines; if nothing describes the product, write `Not documented in the repos — fill in.`

## 4. Write `CONVENTIONS.md`

From `templates/CONVENTIONS-TEMPLATE.md` and the writers' `CONVENTIONS` / `ENV` / `OWNS` lines. A convention goes in only when **two or more services** report the same one (all of them for a single-service project); otherwise it stays in the service spec. Write it as implemented, not as it should be. The Domain Entities table lists every `OWNS` entity with its owning service.

## 5. Write `STATUS.md` and check `AGENTS.md`

- `STATUS.md` from `templates/STATUS-TEMPLATE.md` with the project name and **empty** In Flight / Shipped tables (drop the example row).
- `AGENTS.md`: the services table between `<!-- services:start -->` / `<!-- services:end -->` was written by `scripts/bootstrap.sh`; run `scripts/bootstrap.sh services` if `spechub.conf` changed since. Do not edit `AGENTS.md` otherwise.
- `repo-instructions/`: the writers wrote one file per service. Remind the user to copy each into its repo as `AGENTS.md` (with `CLAUDE.md` containing `@AGENTS.md` and `.github/copilot-instructions.md` pointing at it) — the hub copy is canonical from now on.

## 6. Determinism check (cheap, do it)

Run `scripts/verify.sh all` — five gates, all of which must pass:

| Gate | Checks |
|---|---|
| `manifest` | the file set equals `plan --manifest`; nothing missing, nothing extra |
| `facts` | every spec's Environment Variables table equals its fact sheet §7a |
| `records` | every endpoint/route record carries every key of its type, uses the record type its service's group calls for, and uses the D15 heading shape |
| `headings` | module files use only the closed heading set |
| `mechanisms` | every overview §10 entry has the four keys, names ≥ 2 different services, is evidenced on both sides, and is numbered contiguously |

Fix by relaunching the writer for the affected service with the failures quoted, never by hand-editing the spec — a spec you patch yourself is one the next run will not reproduce.

Then pick the smallest service and run its writer a second time into a scratch path (`/tmp/spechub-check/`, same prompt with the targets changed), and run `scripts/verify.sh diff <original> <scratch>`. It compares the extracted sets — module file names, headings, endpoint rows, env names, entity names, and the §10 **seams** — not the prose, because only the tables have to match.

`seams` is the granularity-independent view of §10: the undirected `{service} <-> {service}` pairs the entries claim exist. Splitting or merging entries leaves it unchanged, and which side is called "Producer" is discarded (two runs disagreed on that for the same seam), so a `seams differ` line means one run genuinely documented a cross-service seam the other dropped. That is a content loss, not a wording difference — fix it by relaunching, not by rewording. The §10 entry titles themselves are deliberately excluded from the `headings` comparison, since their grouping and wording are free.

**Do not edit a template to make a diff go away.** Step 0 that rewrites its own contract makes run N+1 incomparable to run N — two earlier runs each added their own rules to the same template and neither could see the other's. Append what you found to `bootstrap/OBSERVATIONS.md` instead (one line: the rule that did not decide the case, the two readings, which you took, the service). Promoting an observation into a `D` rule is a human step, taken between runs, never inside one.

## 7. Finish

Report (under 40 lines): spec files written with sizes and shape per service; overview / conventions / status written; repo-instruction files written and the copy instruction; the `verify.sh all` and `verify.sh diff` results; every `AMBIGUITIES` line appended to `bootstrap/OBSERVATIONS.md`; every gap the writers flagged that needs a human answer. Suggest the commit: `git add -A && git commit -m "spec hub: bootstrap specs for {PROJECT_NAME}"`.

Then tell the user, in one line: **"Step 0 is done — commit, then start a new session on an Advanced-tier model for the first feature (Step 1, `Features/FEATURE-{name}.md`)."** Do not design anything in this session.
