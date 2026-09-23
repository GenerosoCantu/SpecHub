# Workflow Cheatsheet

A one-page view of `WORKFLOW.md` for people: which step, which session, which model. `WORKFLOW.md` has the full rules, and it wins if the two ever disagree.

**Model tiers → Claude Code and GitHub Copilot models.** The defaults in `scripts/dispatch.sh` apply; you can override them in `spechub.conf` (`MODEL_LIGHT` / `MODEL_STANDARD` / `MODEL_ADVANCED`). Switch models in the session with `/model <alias>`.

| Tier | Claude Code alias | Claude Code resolves to | GitHub Copilot model |
|---|---|---|---|
| Light | `haiku` | Claude Haiku 4.5 | `gpt-5-mini` |
| Standard | `sonnet` | Claude Sonnet 5 | `gpt-5` |
| Advanced | `opus` | Claude Opus 5 | `claude-opus-4.1` |

---

## Main steps

| # | Step | How to start it | Session | Model |
|---|---|---|---|---|
| 0 | **Bootstrap** the hub from the repos | `scripts/bootstrap.sh init`, then the `bootstrap-specs` skill | **New.** Forks one `spec-writer` per service. End the session when the files are on disk. Clone the hub next to the service repos, or set `REPOS_ROOT` in the gitignored `spechub.local.conf`. | Standard (`sonnet`) |
| 1 | **Design** the feature → `Features/FEATURE-{name}.md` (a bug in closed work → `Features/BUG-{name}.md`, see [Bugs](#bugs)) | Ask in plain language (no skill). The session first posts `scripts/lock.sh intend {name} <services>` — a notice, blocks nobody, warns you if someone is designing or holding the same area — then designs. Use `Explore` subagents to read the code. | **New.** It must not carry context from another feature. End the session when the file is written. | Advanced (`opus`) |
| 2 | **Cascade & Prompt**: spec edits + `STATUS.md` row, then `Prompts/PROMPT-*.md` | `cascade-and-prompt` skill | **New.** One pass does both halves. End the session when the prompts are on disk. | Standard (`sonnet`) |
| 3 | **Dispatch**: run prompts in worktrees, in parallel | `dispatch-prompts` skill (`scripts/dispatch.sh run --all`, `wait`) | **New.** Forks into `hub-ops`. | Standard (`sonnet`; `hub-ops` is set to `sonnet`) |
| 3′ | *Implementation* (headless, one per prompt) | Started by the dispatcher | Its own headless session per prompt, each in a worktree | The tier in the prompt header (`Recommended model:`) |
| 3″ | **Verify** each prompt, in implementation order | Test by hand against the services running from the worktrees, then `scripts/dispatch.sh verify <prompt>` (or `--fail "<reason>"`) | Human, no agent | — |
| 4 | **Close the loop**: merge, reconcile specs, `STATUS.md`, changelog, metrics, archive | `close-loop` skill | **New.** Forks into `hub-ops`. | Standard (`sonnet`) |

**Before every step, in a terminal (no session, no tokens):** `scripts/instance.sh sync` (it ends by checking the spec locks; `scripts/lock.sh list` shows who holds which spec file). The session hooks add a line to `metrics/ledger.jsonl` when a session ends, after your last commit, and that uncommitted line blocks a plain `git pull`. `sync` commits the ledger by itself, merges origin into the hub, pushes it, and fast-forwards the service repos. It stops on a real conflict and leaves the hub as it was.

---

## In-between tasks

| Task | Session | Model | Notes |
|---|---|---|---|
| **Polish the feature file** right after designing it (you reviewed it and want changes) | **Continue the Step 1 session** | Advanced (`opus`) | The reasoning behind the design is still loaded. This is the right place for design fixes: before cascade. |
| **Polish the feature file** later (next day, or after other features changed the specs) | **New** session | Advanced (`opus`) | Re-read the current spec/module files first. The specs may have moved. |
| **Fix a wrong name or shape** found when reviewing spec + prompts after Step 2 | **Continue the Step 2 session** | Standard (`sonnet`) | Fix the **spec**, then **regenerate** the prompt from it. Do not edit the prompt by hand. |
| **Design change** found after Step 2, while prompts are still `Generated` | **New** Step 1 session to update the feature file, then a **new** Step 2 session to re-cascade and regenerate | Advanced, then Standard | The feature file is upstream. Fix it there and let the cascade carry the change. |
| **"Polish the prompt"** | — (don't) | — | See the note below. |
| **Fix a bug** in a dispatched implementation (prompt still `Applied`, not merged) | **Resume that prompt's session:** `scripts/dispatch.sh resume <prompt> "<fix>"` | The tier in the prompt header | Never start a new run. The session still has the implementation in context. Already merged and closed? Write a `BUG-` file instead (see [Bugs](#bugs)). |
| Interactive debugging of a dispatched prompt | Resume inside the worktree: `claude --resume <session-id>` (the ID is in the run report) | The tier in the prompt header | |
| Question about what was just built | Resume the prompt's session | The tier in the prompt header | |
| Revive a staled feature (`Features/Staled/`) | **New** session | Advanced (`opus`) | The session posts a new `scripts/lock.sh intend` first (staling released the row), checks the design against the current specs, then moves it back to `Features/`. |
| Park (stale) a feature, or abandon a design | — (terminal) | — | Move the file to `Features/Staled/`, flip its `STATUS.md` row to ⏸, drop its `PENDING` markers, `scripts/lock.sh release {name}`. An abandoned design that never reached Step 2 only needs the `release`. |

### About polishing prompts

You're right: polishing a prompt is the wrong layer. A prompt is a **mechanical copy of the cascaded spec** (its tables are copied with `sed`/`awk`, not retyped), and the spec comes from the feature file. If you hand-edit a prompt, the prompt no longer matches the spec, and Step 4 reconciles against the spec. So fix the problem at its source:

- **Design problem** (wrong behavior, missing case, bad contract) → fix the **feature file**, re-cascade, regenerate.
- **Transcription problem** (the prompt doesn't match the spec, or the spec doesn't match the feature file) → fix the **spec**, regenerate the prompt (Standard).
- **Implementation problem** (the prompt is fine but the code is wrong) → `dispatch.sh resume`. The prompt is `Applied` by then and must not change.

Regenerate a prompt only while its status is `Generated`.

---

## Bugs

A bug goes through the same steps, folders, `STATUS.md` board and close-out as a feature. It just uses a smaller file. `WORKFLOW.md` → Bugs has the full rules.

**Bug file, or resume?**

| Where is the broken code? | What to do |
|---|---|
| In a prompt that is still `Applied` (implemented, not merged) | No file. `scripts/dispatch.sh resume <prompt> "<fix>"`, or reject first with `verify <prompt> --fail "<reason>"`. |
| Already merged and closed | `Features/BUG-{kebab-name}.md` from `templates/BUG-TEMPLATE.md`, then the normal steps. |

**Class A or B?** The bug file's `Class:` line decides what the cascade and close-out do.

| Class | Meaning | Step 2 (cascade & prompt) | Step 4 (close) |
|---|---|---|---|
| **A**: code diverges from spec | The spec already says the right thing; the code doesn't do it. | No spec edit. The prompt copies its contracts from the spec section the bug file cites. | Drift check as usual. Touch a spec only if the check finds a deviation. |
| **B**: spec is wrong or silent | The spec describes the buggy behavior, or never covered the case. | Correct the spec with `PENDING` markers, like an enhancement. | Same as a feature. |

- **Not sure which class?** Treat it as B.
- **The fix needs a new field, endpoint or view?** It's not a bug. Write a `FEATURE-` file.

**What's different from a feature**

| Item | Bug |
|---|---|
| Design file | `Features/BUG-{kebab-name}.md`, ≤ 8 KB; archived and staled like a feature file |
| Design session (Step 1) | **New** session. Standard (`sonnet`) is enough for Class A; Advanced (`opus`) when the cause is unknown or the Class B fix is a design decision |
| Prompt | `Prompts/PROMPT-{service}-{bug-name}.md`; must add a regression test that fails before the fix |
| Branch | `fix/{bug-name}` |
| `STATUS.md` row | Next number in the shared sequence; name starts with `🐞 ` |
| Changelog entry | Starts with `Fix:` |

---

## Deviations: where they go

Every implementing session ends with a `DEVIATIONS` section. The dispatcher copies it into the prompt's **Dispatch Run Report**, and the `dispatch-prompts` report shows it verbatim. **You don't need a standalone "deviations prompt".** Handle deviations in two places:

| When | What | Session | Model |
|---|---|---|---|
| **During verification (Step 3″), before `verify`** | Triage each reported deviation. **Unacceptable** (code differs from the contract, or breaks another service): send it back with `dispatch.sh resume <prompt> "<fix>"` or reject with `verify --fail`. **Acceptable** (reality is fine, or better): accept it and write it down for Step 4. **Affects another service's prompt** (for example, the backend renamed a field the frontend uses): resume the *other* prompt's session too, before verifying it. | Human triage; fixes resume the prompt session | The tier in the prompt header |
| **Step 4 (`close-loop`)** | Absorb the accepted deviations into the spec (reality wins), remove `PENDING` markers, list notable deviations in the changelog entry. The skill also runs its own drift check against the merged diff, so it catches deviations nobody reported. | **New** session, forked `hub-ops`. Pass the deviations you already know as arguments: `/close-loop <feature> — deviations: <list>` | Standard (`sonnet`) |

A deviation that means the **design itself** was wrong (not just a name or a shape) is not a close-out item. Close out what was built, then open a new feature/enhancement file for the redesign (Step 1, new session, Advanced).
