---
name: dispatch-prompts
description: Dispatch generated implementation prompts from the spec hub (WORKFLOW.md Step 3) — runs each PROMPT-{service}-{feature}.md as a headless coding-agent session in its own git worktree of the target repo, all in parallel, via scripts/dispatch.sh. Use when the user says "dispatch", "implement the prompts", "run the prompts", "step 3", asks to resume or fix a dispatched prompt, or asks to mark a prompt verified.
context: fork
agent: hub-ops
---

> Runs forked in the `hub-ops` subagent (Standard tier) where the tool supports it, so the orchestration never enters the main session's context; otherwise run it in a fresh session. Request from the user: **$ARGUMENTS** (if empty: dispatch every `Generated` prompt).

# Dispatch Implementation Prompts (Step 3)

Run every `Generated` prompt as its own headless session inside a git worktree of its target repo, in parallel, from this workspace. The hub stays the only place that triggers implementation; each prompt still gets a fresh, isolated context in the service codebase.

## 0. Required reads — nothing more

1. The dispatch header (first ~8 lines) of each prompt in `Prompts/` you are about to dispatch

Do NOT read `WORKFLOW.md`, service specs, feature files, or the prompt bodies — the headless session reads the prompt; you only orchestrate.

## 1. Preconditions

- The prompt(s) exist in `Prompts/` with `Status: Generated`. Check with `scripts/dispatch.sh status`.
- Each header names a `Target repo:` path that exists locally and a `Branch:`.
- **Prerequisites do not gate dispatch.** All prompts of a feature go out together, even when a prerequisite prompt is not implemented yet. Prerequisites only order verification and merge.
- Never dispatch a prompt whose Status is `Applied` or `Verified` — use `resume` for follow-ups on an `Applied` prompt.

## 2. Dispatch

`run` returns immediately: the sessions run under a detached supervisor that survives the end of this agent's turn, the Bash tool's timeout, or a closed terminal. **Never launch it with `run_in_background`** (a background Bash task dies with the agent that started it — that is how runs get lost). Then block on `wait` in the foreground:

```bash
scripts/dispatch.sh status                       # the board, with a LAST RUN column
scripts/dispatch.sh run --all                    # every Generated prompt, in parallel — returns at once
scripts/dispatch.sh run PROMPT-api-x PROMPT-web-x   # a subset
scripts/dispatch.sh run --all --dry-run          # plan only, touches nothing
scripts/dispatch.sh wait --timeout 540           # block; exit 0 all ok, 1 a run failed/was killed, 2 still running
```

Call `wait --timeout 540` with the Bash tool's `timeout` set to 600000 and **repeat it while it exits 2**. Runs take minutes to tens of minutes. Tell the user which prompts are running after the first call.

For each prompt the script: creates `feature/...` from the base branch (`BASE_BRANCH` in `spechub.conf`) in its own worktree (`<repo>-worktrees/<branch>`), copies gitignored local files (`WORKTREE_COPY_FILES`), links dependency dirs (`WORKTREE_LINK_DIRS`), for Claude Code pre-registers the worktree as trusted in `~/.claude.json`, runs the headless CLI named by `AGENT_CLI` there with the model mapped from the header's **Recommended model** tier and tool use pre-approved, then flips the header to `Applied` and appends a **Dispatch Run Report** section to the prompt file. Logs land in `.dispatch/runs/` (gitignored).

When all sessions have finished, the script restarts every applied prompt's service from its worktree through `scripts/stack.sh` (and starts the rest of the stack if it is down), so the user can verify without switching anything by hand. `scripts/dispatch.sh serve --all` repeats that on demand (e.g. after the user stopped the stack).

Optional knobs (environment variables): `DISPATCH_AGENT_CLI` / `DISPATCH_AGENT_BIN` (override `spechub.conf`), `DISPATCH_ALLOWED_TOOLS` (Claude Code), `DISPATCH_DEPS=install` (run the service's install command instead of linking), `DISPATCH_MAX_TURNS`, `DISPATCH_SERVE=affected|none` (restart only the affected services, or nothing). Only change them when the user asks or a run failed because of them.

## 3. When `wait` returns

A run cannot fail silently: every session ends with a **Run** entry in its prompt file whose `Result` is `ok`, `ERROR (exit n)` with a `Diagnosis` row, or `ABORTED` (the process was killed; leftover edits are stashed in the worktree). `wait` prints `FAILED:` lines and exits 1 for any of the latter two; a prompt that is still `Generated` after `wait` has failed, whatever the log looks like.

For each prompt, read only its **Dispatch Run Report** section (the last table in the file) — not the JSON log. Report to the user, per prompt:

- Result (`ok` / error), agent and model, turns and cost where the CLI reports them
- Branch, worktree path, commits made
- The agent summary line — surface any `DEVIATIONS` verbatim; they must reach Step 4
- Session ID (needed for `resume`)
- Which services are now running from worktrees (the script's `[dispatch] Services on worktrees:` line), with their URLs from `scripts/stack.sh list`

If a run failed, the prompt is left `Generated`; quote its `Diagnosis` row to the user. The common causes are a Bash command outside the allowlist (extend `DISPATCH_ALLOWED_TOOLS` and re-run), a spec gap the agent could not resolve (fix the spec/prompt first; do not patch the prompt body with hub paths), the turn cap (`resume` it), or `ABORTED` — someone or something killed the process; re-run it. With Claude Code, the line `Ignoring 1 permissions.allow entry ... workspace has not been trusted` in a `.stderr.log` is **harmless** (it appears on successful runs too): the repo's own allow-list is ignored, the dispatcher passes its own. Do not report it as the cause of anything.

## 4. Follow-ups go to the same session

Bug fixes, missed edge cases, review comments: never open a new run for them.

```bash
scripts/dispatch.sh resume PROMPT-api-x "The DTO must reject empty slugs; add the validator and a test."
scripts/dispatch.sh wait --timeout 540           # same loop as after run
```

This resumes the recorded session ID inside the same worktree (detached, like `run`), so the model keeps the full implementation in context, appends a **Resume** entry to the report, and restarts that service from the worktree (dev servers serve stale modules after a resume otherwise). For interactive debugging the user can resume the session inside the worktree with their CLI (`claude --resume <id>`, `codex resume <id>`, `copilot --resume <id>`).

## 5. Verification is human — never automate it

The script never flips `Verified`, and neither do you. The services are already running from the worktrees; only after the user says they have reviewed the diff, run the build, and exercised the endpoints/UI (in the feature's implementation order) do you run:

```bash
scripts/dispatch.sh verify PROMPT-api-x
```

Merging into the base branch is Step 4 (`close-loop` skill → `scripts/dispatch.sh merge`), not part of this skill.

## 6. Finish

Report: which prompts were dispatched, their states on the board, commits and deviations per prompt, which services run from which worktree, and what the user must verify next (with the implementation order from the prompts' `Prerequisites:` lines). Keep the report under 40 lines — it is all the main session receives.

Verification is human and Step 4 (`close-loop`) starts in a **new session**; do not proceed into either.
