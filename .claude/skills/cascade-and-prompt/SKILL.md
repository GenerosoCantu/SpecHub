---
name: cascade-and-prompt
description: Cascade a designed feature into the service specs and generate its stateless implementation prompts in one session (WORKFLOW.md Step 2). Use when the user asks to cascade a feature, generate/create/regenerate PROMPT-{service}-{feature}.md files, or says "step 2", "cascade", or "generate the prompts" for a designed feature.
model: sonnet
---

> **Session rule:** this step runs on **Sonnet** in a fresh session (`/model sonnet` before invoking — the frontmatter pins Sonnet for this turn only). It is transcription, not design. When the prompts are on disk, **end the session**: Step 3 starts a new one.

# Cascade & Prompt (Step 2)

For a feature that has completed Design (Step 1): write its contracts into the service spec(s) (2a), then produce one stateless, self-contained prompt per affected service from those spec edits (2b). Both halves run in this one session, in that order, in one uninterrupted pass — do not stop between them unless the user explicitly asked for a checkpoint after the cascade.

## 1. Required reads — in this order, nothing more

1. `CONVENTIONS.md` — shared conventions every spec edit and prompt inherits
2. `Features/FEATURE-{name}.md` — the feature file (must exist in `Features/`; if it doesn't, stop and run Step 1 first; if it is in `Features/Staled/`, stop — staled designs must be re-validated and moved back before use)
3. For each affected service: its spec. **Single-file spec** (`NN-{service}.md`): read it. **Split spec** (`NN-{service}.md` is an index with a `NN-{service}/` directory): read the index, `NN-{service}/00-core.md`, and **only the module file(s) this feature touches**; read `01-conventions.md` only if env/config, constants or shared shapes are involved.
4. `STATUS.md` — to add (or find) the feature row
5. `spechub.conf` — the `dir` (resolved against `REPOS_ROOT`) of each affected service is the prompt's `Target repo`

Do NOT read every module file, `WORKFLOW.md`, `00-architecture-overview.md`, `CHANGELOG.md`, `bootstrap/`, or unrelated specs. Do not grep `archive/`, `Features/Implemented/` or `Prompts/Implemented/`. These are the same files both halves need — that is why they share a session; do not re-read them between 2a and 2b except as §4 requires.

## 2. Preconditions — verify before touching a spec

- The feature file has no unresolved items under "Open design decisions". If any remain, stop and list them to the user — nothing is cascaded, and no prompt is generated, over an open question.
- Cross-service features: the feature file declares an `Implementation order` line and a `Recommended Claude model` per service.

## 3. Cascade (2a)

Write the feature into the affected spec(s) **as if it were already implemented**, in the exact format the surrounding spec uses — module, endpoints, schema/entity, DTO/class names, state slice, views, file/storage changes. Mark every added or changed contract with a `<!-- PENDING: {feature} -->` marker (Step 4 removes them on reconciliation).

- Split specs: edit the relevant **module file(s)**. A new module gets its own file in the directory (`templates/MODULE-TEMPLATE.md`) plus a row in the index file's File Map. Never add module content to an index file.
- Where the feature file's proposed name or shape conflicts with a convention already in the spec, the spec's convention wins — adapt the contract, and note the change for the report.
- Add the feature's row to `STATUS.md` (next sequential number; each affected service 🔄 Pending).

**Cascade summary — record it, do not pause.** Keep a list of each spec/module file touched and the `PENDING` contracts added, any index-table row, the `STATUS.md` row, and every place the cascade adapted the feature file's proposal to an existing convention. It opens the final report (§6). Then continue straight into §4: the user reviews spec and prompts together before Step 3 starts, and a wrong name found then is fixed in the spec and the affected prompt regenerated.

## 4. Generate the prompts (2b)

**Re-read the cascaded spec/module file(s) from disk first.** Prompts are generated *from the spec text*, never from the feature file or from memory of it. Where the cascade adapted a name or shape, only the spec has the version the implementing session must receive.

File: `Prompts/PROMPT-{service}-{feature}.md`, one per affected service. Service identifiers are the `name` column of `spechub.conf`. Structure: `templates/PROMPT-TEMPLATE.md`.

Every prompt MUST open with the dispatch header:

```markdown
> **Target repo:** {absolute local path}
> **Branch:** feature/{kebab-name}
> **Prerequisites:** {PROMPT-file(s) this one depends on — sets verification and merge order, or "none"}
> **Status:** Generated   <!-- Generated → Applied → Verified -->
> **Recommended model:** {tier} — {one-line reason, carried from the feature file}
```

Header rules the dispatcher (Step 3, `scripts/dispatch.sh`) relies on: `Target repo` is the absolute local path; `Branch` is `feature/{kebab-name}` (unique per prompt — two prompts on the same repo need two branches); `Recommended model` starts with the tier name (`Haiku`, `Sonnet`, or `Opus`) since it selects the session's model. Prerequisites do not block dispatch — all prompts of a feature run in parallel — they order verification and merge, and must reflect the feature file's `Implementation order` line.

Then the body, per WORKFLOW.md Step 2b:

- **Context** — what the feature does, in 2–5 sentences
- **Files to study** — existing repo files to read for patterns (keep it to 3–5)
- **Files to create/modify** — exact paths
- **Schema contract** — field names, types, defaults, indexes, verbatim from the spec
- **Endpoint definitions** — method, path, guard, request/response shape
- **Pattern references** — "follow the same structure as X"
- **Naming rules** — class/DTO names, state slice, route strings, verbatim from the spec
- **Build, test, lint** — the repo's commands; lint only changed files
- Backend prompts: input validation, auth/guard behavior, error/status semantics, required test updates
- Frontend prompts: backend prerequisites, route/view/component changes, state updates, UX states (loading/empty/error/permission), acceptance criteria

**Size and copy rules (WORKFLOW.md → Context Budget):**

- A prompt is **≤ 8 KB** for an enhancement, **≤ 12 KB** for a new module. Check with `wc -c` before finishing; trim narrative, never contracts.
- Schema, endpoint and naming tables are **copied mechanically** from the cascaded spec file — extract the `PENDING` passage with `sed -n '<start>,<end>p' <spec-file> >> <prompt-file>` (or `awk`), then edit around it. Do not retype or paraphrase a table: retyping costs output tokens and is how spec and prompt drift.
- Narrative is limited to the Context paragraph. Everything else is tables, file lists, and acceptance criteria.
- Lint instruction: tell the session to lint only the files it changed (`npx eslint <files>`, `ruff check <files>`, …), never a repo-wide `lint --fix`.

## 5. Quality gate

A prompt is complete only if a brand-new session in the target repo could implement it without asking a question or reading an unnamed file. Re-read each prompt against that bar before finishing. Do not include spec-hub file paths in the prompt body — the implementing session has no access to this workspace. Every contract in the prompt must appear, character for character, in a `PENDING`-marked spec passage written in 2a; if one does not, fix the spec, not the prompt.

## 6. Finish

Report, in this order: the cascade summary from §3 (spec files changed, `PENDING` contracts, index/STATUS rows, convention adaptations), then the generated prompt files with their sizes, and the order in which they must be verified and merged (they are all dispatched together in Step 3 via the `dispatch-prompts` skill). This report is the review point for the whole step.

Then tell the user, in one line: **"Step 2 is done — start a new session for Step 3 (`dispatch-prompts`)."** Do not continue into dispatch in this session.
