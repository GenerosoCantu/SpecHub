# Design — End-to-End Observability & Metrics for SpecHub

> **Status:** **Implemented 2026-09-12** (Phases 1–4; Phase 5 deferred per D5). Design record for a change to the **SpecHub framework itself**, not to the Joornalo platform. Kept as the rationale behind `scripts/metrics.sh`; the code is the current contract, this file is why it is shaped that way. Deviations from the design as proposed are recorded in Appendix B.
> **Scope:** `scripts/`, `metrics/`, `.claude/settings.json`, `AGENTS.md`, `WORKFLOW.md`, `skills/close-loop`.
> **Author:** design session, 2026-09-12.

## 1. Why this is not a `Features/` document

`Features/` holds designs that Step 2 cascades into **service specs** and Step 3 dispatches into **service repos**. This change touches neither: it modifies the hub's own scripts and process documents. Routing it through Steps 1–4 would try to cascade it into `NN-{service}.md` files where it does not belong.

It therefore lives in `design/` — framework self-improvement records, outside every routed namespace, not a source of truth for anything. If the hub grows a real Step 5 ("evolve the framework"), this is the folder it reads.

---

## 2. Problem

Per-run traceability is good: every dispatched session appends a **Dispatch Run Report** entry to its prompt file, and the entry survives archival into `Prompts/Implemented/`. What is missing is the aggregate — throughput, failure patterns, and cost per feature — which is what a team evaluating the framework asks for before adopting it.

### 2.1 What is already captured

The data is largely **already collected and then discarded**. `.dispatch/runs/<run-id>.json` carries, per headless session:

| Field | Example |
|---|---|
| `session_id` | `faed316c-0b9a-4179-9d79-4c70a0a96f7a` |
| `total_cost_usd` | `0.3825` |
| `duration_ms` / `duration_api_ms` | `89944` / `57423` |
| `num_turns` | `16` |
| `usage.{input,output,cache_read,cache_creation}_tokens` | `28 / 4651 / 600785 / 53155` |
| `modelUsage[<model>]` | per-model token + cost split |
| `is_error`, `subtype`, `stop_reason` | `false`, `success`, `end_turn` |

Of these, [`cmd__worker`](../scripts/dispatch.sh#L669) writes only **session id, turns, cost** into the prompt's report table. Duration and every token count are dropped on the floor.

### 2.2 The three structural gaps

1. **The rich data is not durable.** `.dispatch/` is gitignored ([.gitignore:4](../.gitignore#L4)). The JSON dies with the machine; only the prose table survives.
2. **The durable copy is not machine-readable.** Run reports are markdown tables scattered across ~2 files per feature, migrating into `Prompts/Implemented/` at close-out. Aggregating them means parsing prose across an archive directory that [AGENTS.md](../AGENTS.md) explicitly excludes from search.
3. **Two metrics are not captured at all:**
   - **Human verification pass/fail.** [`cmd_verify`](../scripts/dispatch.sh#L854) only writes the *pass*. A failed verification leaves no trace — the human silently runs `resume` instead. Any pass-rate computed today is 100% by construction.
   - **Hub session cost.** [WORKFLOW.md:25](../WORKFLOW.md#L25) states that spend is *dominated* by hub sessions (Steps 1, 2, 4), not by the dispatched runs. Nothing measures them. Cost-per-feature built only from dispatch runs measures the smaller half of the bill and would understate the true figure, in this project's experience, by several times.

### 2.3 The one-line framing

> The work is not "collect more data." It is: give the data that already exists one durable machine-readable home, close the two real gaps, and derive every view from that one home.

---

## 3. Design principles

These constrain every decision below.

| # | Principle | Consequence |
|---|---|---|
| P1 | **Derived, never authoritative.** | `STATUS.md` remains the only feature-state source of truth. If the metrics board disagrees with it, the board is wrong and regenerating fixes it. |
| P2 | **Zero session tokens.** | The metrics files are written by scripts and read by scripts. `METRICS.md` joins `CHANGELOG.md` in the **never open in a session** rule. An observability surface that costs tokens every session defeats the framework's central discipline. |
| P3 | **Rebuildable.** | Every view is a pure function of the ledger. Delete `METRICS.md`, regenerate it, get the same bytes. |
| P4 | **Instrument existing moments.** | No new human rituals. Every emitter fires inside a script that already runs at that moment. The one exception (`verify --fail`) replaces a step that is being skipped silently today. |
| P5 | **Never guess a number.** | Reported costs are recorded as reported. Derived costs are labelled derived. A model with no price row yields `n/a`, never an estimate. |
| P6 | **Agent-agnostic core, best-effort extras.** | Wall-clock duration, result and model work for `claude`, `codex` and `copilot`. Token/cost detail degrades to empty for CLIs that do not report it, and the readers print `n/a` rather than failing. |

---

## 4. Architecture

```
 EMITTERS (already-running scripts)          LEDGER                  READERS
 ─────────────────────────────────           ──────                  ───────
 dispatch.sh __worker    ──┐
 dispatch.sh verify        ├──> metrics/ledger.jsonl ──┬──> metrics.sh report     (terminal)
 dispatch.sh merge         │    (committed,            ├──> metrics.sh render     (METRICS.md)
 SessionEnd hook         ──┘     append-only)          └──> metrics.sh dashboard  (HTML, optional)
 (hub sessions)                        ▲
                                       │
                        metrics.sh backfill (one-off, from Prompts/Implemented/)
```

One writer path, one file, many readers. The ledger is the only new state.

---

## 5. The ledger — `metrics/ledger.jsonl`

Append-only, one JSON object per line, **committed** (unlike `.dispatch/`). Newest last. Never edited by hand, never read by a model.

### 5.1 Common envelope

Every event carries:

| Field | Type | Notes |
|---|---|---|
| `schema` | int | `1`. Bumped only on a breaking field change; readers reject unknown majors loudly. |
| `ts` | string | ISO-8601 UTC, `date -u +%Y-%m-%dT%H:%M:%SZ`. |
| `event` | string | `dispatch_run` \| `dispatch_resume` \| `verify` \| `merge` \| `hub_session`. |
| `feature` | string | The feature slug — the join key for cost-per-feature. See §5.6. |
| `step` | int | WORKFLOW step: `0`–`4`. |

Unknown/underivable values are written as `null`, never omitted and never faked.

### 5.2 `dispatch_run` / `dispatch_resume`

Emitted by [`cmd__worker`](../scripts/dispatch.sh#L669) after `summarize_run`, in the same place the report table is appended.

```json
{"schema":1,"ts":"2026-09-12T13:24:36Z","event":"dispatch_run","step":3,
 "feature":"boolean-template-params",
 "prompt":"PROMPT-joornalo-cms-boolean-template-params",
 "service":"joornalo-cms","repo":"joornalo-cms","branch":"feature/boolean-template-params",
 "agent":"claude","tier":"Standard","model":"claude-sonnet-5",
 "session_id":"faed316c-0b9a-4179-9d79-4c70a0a96f7a","run_id":"PROMPT-joornalo-cms-boolean-template-params-20260912-132306",
 "attempt":1,"result":"ok","turns":16,
 "wall_ms":91210,"duration_ms":89944,"api_ms":57423,
 "tokens":{"in":28,"out":4651,"cache_read":600785,"cache_write_5m":0,"cache_write_1h":53155,"thinking":109},
 "cost_usd":0.38254699999999986,"cost_basis":"reported",
 "commits":2,"diagnosis":null}
```

Notes:

- `result` is `ok` \| `error` \| `aborted`, taken from the same `$result` the report row uses, so the two can never disagree. `aborted` is emitted from [`record_abort`](../scripts/dispatch.sh#L585) so killed sessions appear in the failure rate instead of vanishing.
- `wall_ms` is measured by the worker around `run_headless` (`date +%s` seconds × 1000, or `python3 -c 'import time;print(int(time.time()*1000))'` for millisecond precision — BSD `date` on macOS has no `%N`, so `%s%3N` is not portable here) and is therefore **agent-agnostic**. `duration_ms`/`api_ms` are the agent's own numbers and are `null` for CLIs that do not report them. Averages in the reports use `wall_ms`.
- `tier` is the prompt header's `Recommended model` first word; `model` is what [`model_alias`](../scripts/dispatch.sh#L163) resolved it to. Recording both is what makes "which model was used per step" answerable *and* auditable against the tier policy.
- `attempt` = `1 + (count of dispatch_run|dispatch_resume already in the ledger for this prompt)`. A `grep -c` on write; the ledger is small.
- **Cache writes are split by TTL.** A 5-minute write bills at 1.25x base input, a 1-hour write at 2x — a 60% difference that a single `cache_write` field would silently average away. Measured on this project: dispatch runs and hub sessions alike are **100% 1-hour writes**, i.e. entirely at the expensive multiplier, so the split is not hypothetical. Source: `usage.cache_creation.{ephemeral_5m,ephemeral_1h}_input_tokens`.
- `cost_basis` is `reported` here. See §7.

### 5.3 `verify`

Emitted by `cmd_verify`. **Requires the behavior change in §6.2.**

```json
{"schema":1,"ts":"…","event":"verify","step":3,"feature":"boolean-template-params",
 "prompt":"PROMPT-joornalo-cms-boolean-template-params","service":"joornalo-cms",
 "result":"fail","attempt":1,"by":"Generoso Cantu",
 "reason":"dropdown writes the string \"true\", not a boolean"}
```

`result` is `pass` \| `fail`. `reason` is required on `fail`, `null` on `pass`. `attempt` counts prior `verify` events for the prompt, so "verified on the second look" is visible.

### 5.4 `merge`

Emitted by [`merge_one`](../scripts/dispatch.sh#L888), beside the existing **Merged** report entry.

```json
{"schema":1,"ts":"…","event":"merge","step":4,"feature":"boolean-template-params",
 "prompt":"PROMPT-joornalo-cms-boolean-template-params","service":"joornalo-cms",
 "base":"dev","merge_sha":"a1b2c3d","impl_shas":["e4f5a6b"],"pushed":false,
 "lead_time_ms":6402000}
```

`lead_time_ms` = this `ts` minus the first `dispatch_run` `ts` for the prompt. It is the framework's throughput number: prompt dispatched → merged.

### 5.5 `hub_session`

The gap that makes cost-per-feature honest. Emitted by `metrics.sh session`, invoked from a `SessionEnd` hook (§6.4).

```json
{"schema":1,"ts":"…","event":"hub_session","step":2,
 "feature":"boolean-template-params","skill":"cascade-and-prompt",
 "session_id":"c187273b-…",
 "models":{"claude-opus-5":{"in":144,"out":53317,"cache_read":6345112,"cache_write_5m":0,"cache_write_1h":180290,"messages":72}},
 "subagent_messages":0,"assistant_messages":72,
 "wall_ms":1840000,"cost_usd":6.31,"cost_basis":"derived"}
```

Derivation is mechanical from the transcript (`~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`), whose shape is confirmed: each `"type":"assistant"` line carries `message.model`, a full `message.usage` block, `sessionId`, `timestamp` and `isSidechain`.

- **Per-model totals** — sum `message.usage` grouped by `message.model`. Multi-model sessions (a fork to Haiku, a subagent on Standard) split correctly for free.
- **Subagent spend is included, and marked.** `isSidechain:true` lines are `hub-ops` / `spec-writer` / `Explore` forks. They are real spend in the same session, so they count toward the total; `subagent_messages` records how much of it they were.
- **`step` / `skill`** — from `Skill` **tool_use blocks**, parsed as JSON (`content[].type == "tool_use" and .name == "Skill"` -> `.input.skill`). **Not a line grep.** A `grep` for skill names over the raw transcript produces false positives from tool *output*: a session that merely prints a skill name — as any session inspecting the hub does — tags itself with that skill. This was reproduced during design: a grep-based classifier labelled the design session itself `bootstrap-specs`, purely because a `grep` result printed the string into the transcript. Parse the blocks. A session that invoked no skill is Step 1 (design) if it wrote a `Features/FEATURE-*.md`, else `step: null` (uncategorized — deliberately visible in the report as "unattributed hub time", because that number is itself interesting).
- **`cost_usd`** is `derived` — transcripts carry tokens, not dollars. See §7.

### 5.6 The `feature` join key

One slug, used identically everywhere, derived mechanically in priority order:

1. Prompt filename: `PROMPT-{service}-{feature}.md` → strip `PROMPT-`, strip the longest `spechub.conf` service name that prefixes the remainder. (Exactly the algorithm [`prompt_service`](../scripts/dispatch.sh#L192) already uses, run for the other half of the name.)
2. For `hub_session`: `Features/FEATURE-{slug}.md` / `Prompts/PROMPT-*-{slug}.md` paths appearing in **any** tool input — `Write`/`Edit` `file_path` **and `Bash` `command` strings**. The `Bash` half is not optional: under the auto-mode convention that prefers shell tooling, hub sessions create and edit these files with `cat > … <<EOF` heredocs and `sed`, so a `Write`/`Edit`-only scan finds nothing. Verified on all four Step 1–4 sessions of feature #72: zero matching `Write`/`Edit` paths, 3–26 slug mentions each in `Bash` commands. Ties → most frequently referenced.
3. Otherwise `null`. An unattributed session still counts toward totals; it just does not roll up to a feature.

`STATUS.md` feature **numbers** are deliberately *not* the key — they are assigned by a human in Step 2 and would force every emitter to parse `STATUS.md`. `metrics.sh render` resolves slug → `#n` once, at render time, by matching the archived feature file.

---

## 6. Emitters — exact touch points

### 6.1 `dispatch.sh __worker` — the main instrumentation

[scripts/dispatch.sh:669](../scripts/dispatch.sh#L669), immediately after the existing `append_report` call. The function already holds every value; the only new work is capturing `wall_ms` around `run_headless` and pulling the token block out of the run JSON.

`json_field` handles flat top-level keys only, so `usage.*` and `modelUsage.*` need a nested reader. Rather than extend the sed-based parser, `metrics.sh` gets a small `python3` extractor (`python3` is already a hard dependency — [changelog.sh](../scripts/changelog.sh) uses it), and the worker calls:

```bash
"$HUB_DIR/scripts/metrics.sh" emit dispatch_run \
  --prompt "$file" --run-id "$run_id" --json "$out_json" \
  --agent "$AGENT_CLI" --model "$model" --tier "$tier" \
  --result "$result" --wall-ms "$wall_ms" --commits "$n_commits"
```

Keeping the JSON parsing inside `metrics.sh` means `dispatch.sh` gains roughly 6 lines, not 40, and the per-agent JSON dialects (claude result-object, codex JSONL, copilot plain text) stay in one place next to `summarize_run`'s existing per-agent `case`.

`record_abort` gets the same call with `--result aborted`.

### 6.2 `dispatch.sh verify` — the one behavior change

```
scripts/dispatch.sh verify <prompt>                     Applied → Verified   (emits verify pass)
scripts/dispatch.sh verify <prompt> --fail "<reason>"   stays Applied         (emits verify fail)
```

`--fail` does **not** change the prompt's status — `Applied` is already the correct state for "implemented, not accepted". It appends a **Verification failed** entry to the run report (so the trace stays in the prompt file, where it belongs) and emits the event. The natural next action is unchanged: `dispatch.sh resume <prompt> "<reason>"`.

To make it the path of least resistance rather than a chore, `resume` on an `Applied` prompt that has **no** `verify` event since its last run prints a one-line nudge:

```
[dispatch] note: recording this as a verification failure. Use --no-verify-fail to skip.
```

and emits the `fail` event with the resume message as the reason. This is the design's only nudge; without it the pass-rate stays fictional, because the failure path currently has no button to press.

### 6.3 `dispatch.sh merge` — throughput

One `metrics.sh emit merge` call inside [`merge_one`](../scripts/dispatch.sh#L888), next to the existing `append_report "$file" "Merged"`. Values (`merge_sha`, `impl_shas`, `pushed`, `svc`) are already in scope.

### 6.4 Hub sessions — a `SessionEnd` hook

Added to [.claude/settings.json](../.claude/settings.json):

```json
"hooks": {
  "SessionEnd": [{ "hooks": [{ "type": "command",
    "command": "\"$CLAUDE_PROJECT_DIR/scripts/metrics.sh\" session" }]}]
}
```

The hook payload (session id, transcript path, cwd, reason) arrives on **stdin as JSON** — no environment variable carries the transcript path, so the command takes no arguments and `metrics.sh session` parses stdin. `--transcript <path>` / `--session <id>` override it, so the same command runs standalone for backfill and for agents whose hook surface differs. **The exact `SessionEnd` payload keys must be confirmed against the installed Claude Code version before Phase 4** — the parser should key off `transcript_path` but fall back to locating the newest transcript under `~/.claude/projects/<encoded-cwd>/` if the key is absent.

Design notes:

- **Automatic, not remembered.** Asking the skills to self-report at their end would fail exactly when a session is interrupted — which is precisely the expensive case worth measuring.
- **Idempotent.** Keyed on `session_id`; a re-run replaces rather than appends (the only non-append operation in the design, and it is a same-key overwrite).
- **Fails silently and never blocks.** A hook that errors must not break the session. `metrics.sh session` exits 0 unconditionally and logs to `metrics/.emit.log`.
- **Claude-specific, by construction.** Codex and Copilot hub sessions will not be captured on day one. The report labels hub-session coverage explicitly (`hub sessions captured: 14 (claude only)`) so the gap is visible rather than silently skewing cost-per-feature.

---

## 7. Cost model — reported vs derived

| Source | Cost | Basis |
|---|---|---|
| Dispatch runs (`claude`) | `total_cost_usd`, verbatim | `reported` |
| Dispatch runs (`codex`, `copilot`) | `null` unless the CLI reports one | `reported` / `null` |
| Hub sessions | computed from tokens x price table | `derived` |

Transcripts carry token counts, not dollars, so a hub-session cost must be derived. **The derivation is exact, not an estimate** — validated during design against all three reported per-model costs in `.dispatch/runs/`, to a delta of `$0.00000000`:

```
cost = (in x P_in  +  out x P_out  +  cache_read x P_in x 0.1
        +  cache_write_5m x P_in x 1.25  +  cache_write_1h x P_in x 2.0) / 1e6
```

| Run | Model | Derived | Reported | Delta |
|---|---|---|---|---|
| cms | `claude-sonnet-5` | $0.379343 | $0.379343 | $0.00000000 |
| cms | `claude-haiku-4-5` | $0.003204 | $0.003204 | $0.00000000 |
| public-front | `claude-haiku-4-5` | $0.122510 | $0.122510 | $0.00000000 |

So `derived` marks provenance, not precision: a hub-session figure is as accurate as a dispatch figure, **provided the price table is current**. That proviso is the entire risk, which is why the table is a file the user maintains rather than a constant in the script.

**This validation is a permanent regression test, not a one-off.** `metrics.sh selftest` recomputes every `.dispatch/runs/*.json` and fails if any model's derived cost differs from its reported cost by more than $0.0001. A stale price row, a changed multiplier, or a new TTL tier then surfaces as a failing test the next time anything runs — instead of as silently wrong dollars on the board.

**`metrics/prices.tsv`** — committed, human-maintained, USD per million tokens. Only `in` and `out` are stored; cache rates are multipliers of `in` (0.1x read, 1.25x 5-minute write, 2x 1-hour write) and are applied by the script:

```
# model              in     out     # USD per MTok, from the provider's pricing page.
# Cache rates are derived: read 0.1x in, write 1.25x in (5m TTL), 2.0x in (1h TTL).
claude-opus-5        _      _
claude-sonnet-5      _      _
claude-haiku-4-5     _      _
```

Shipped with `_` placeholders and a pointer, never with baked-in numbers that rot silently. A model with no row still gets full token totals; its cost shows `n/a` and the script warns once naming the model. **It never estimates** (P5).

Every rendered dollar figure carries its basis, e.g. `$14.07 (hub $13.56 derived + dispatch $0.51 reported)`.

## 8. Readers — `scripts/metrics.sh`

```
scripts/metrics.sh emit <event> [flags]        append one event      (called by dispatch.sh; not by humans)
scripts/metrics.sh session [--transcript P]    derive + emit a hub_session  (called by the SessionEnd hook)
scripts/metrics.sh report [--days N] [--feature SLUG] [--json]
                                               terminal summary
scripts/metrics.sh render                      (re)write METRICS.md from the ledger
scripts/metrics.sh backfill [--dry-run]        seed the ledger from Prompts/Implemented/ + .dispatch/runs/
scripts/metrics.sh dashboard [--open]          self-contained HTML from the same ledger
scripts/metrics.sh archive <YYYY-MM-DD>        roll old lines into archive/metrics-ledger-archive.jsonl
```

Shape and conventions mirror [`changelog.sh`](../scripts/changelog.sh) deliberately — `set -euo pipefail`, a `HUB_DIR` resolved from `BASH_SOURCE`, bash for control flow with `python3` heredocs for parsing, usage printed from the header comment.

### 8.1 `METRICS.md` layout

Committed, regenerated, sits beside `STATUS.md`. **Never opened in a session.** Sketch:

```markdown
# Joornalo — SpecHub Metrics

> Generated by `scripts/metrics.sh render` from `metrics/ledger.jsonl`. Do not edit; do not open in a session.
> Window: 2026-06-01 → 2026-09-12 · 38 features · 71 dispatch runs · 46 hub sessions (claude only)

## Health

| Metric | Value | |
|---|---|---|
| First-pass success (dispatched → verified, no resume) | 68% | 26/38 |
| Dispatch run failure rate (error or aborted) | 7% | 5/71 |
| Human verification pass rate (first look) | 74% | 28/38 |
| Median resumes per feature | 0 | p90: 2 |
| Median dispatch → merge lead time | 1h 47m | p90: 9h 12m |
| Median headless session duration | 2m 31s | p90: 11m 04s |

## Cost per feature (last 10 closed)

| # | Feature | Hub (derived) | Dispatch (reported) | Total | Runs | Resumes |
|---|---------|---|---|---|---|---|
| 72 | Boolean Template Params | $3.98 | $0.51 | **$4.49** | 2 | 0 |
| 71 | Section Latest News Block | $6.20 | $1.84 | **$8.04** | 3 | 1 |
| | **median** | $4.60 | $0.92 | **$5.52** | | |

## Model use by step (policy conformance)

| Step | Policy tier | Sessions | Actual models | Off-policy |
|---|---|---|---|---|
| 1 design | Advanced | 12 | claude-opus-5 (12) | 0 |
| 2 cascade & prompt | Standard | 14 | claude-opus-5 (3), claude-sonnet-5 (11) | **3** |
| 3 dispatch | per-prompt tier | 71 | sonnet-5 (58), haiku-4-5 (13) | 0 |

## Failure patterns

| Diagnosis | Count | Last seen |
|---|---|---|
| hit the turn cap before finishing | 3 | 2026-08-30 |
| killed before producing a result | 2 | 2026-07-19 |
```

The **Model use by step** table is the one not requested but worth having: the tier policy in [WORKFLOW.md:30](../WORKFLOW.md#L30) is the framework's main cost lever, and it is currently unenforced and unmeasured. This table shows, for free from data already in the ledger, whether the policy is actually being followed — which is the difference between a documented cost discipline and a real one.

### 8.2a Per-step, per-feature breakdown

Two views answer "where did the money go inside one feature", both from the same ledger:

* **Cost by step** — every step's cost, share, token split (in / out / cache read / cache write) and median duration. Step 3 is deliberately split into the **hub session** that drives the dispatcher and the **headless runs** it launches: they are different money, and conflating them is exactly the error that makes dispatch-only accounting look complete.
* **Per-feature step breakdown** — the matrix: one row per feature, one column per step. Only features whose hub sessions are in the ledger appear; a dispatch-only row would read as though design and cascade were free.
* `scripts/metrics.sh report --feature <slug>` adds a session-by-session listing (step, session id, model, cost, tokens, duration) in chronological order.

Token coverage is marked where it is partial (`†n/m`): runs logged under a previous hub still have their cost, from the report table, but not their token counts. Cost is never the partial half.

### 8.2b Measuring without dollars, and comparing across vendors

Prices change; the ledger should not go stale when they do. Two properties make that work:

**Tokens are the stored truth; dollars are a view.** Every event stores its token counts, and
`render` computes dollars from `metrics/prices.tsv` at render time. Editing a price and re-running
`render` re-prices all of history. Reported dispatch costs are kept *as billed* — that is what was
actually paid — and the board flags the gap when today's table disagrees with what was billed.

**ITE — input-token equivalents — is the price-free unit.**

```
ITE = in + (Pout/Pin)*out + cread_mult*cache_read + 1.25*write_5m + 2.0*write_1h
```

It is the cost formula divided by the input price, so `dollars = ITE x Pin / 1e6` exactly, and
`selftest` asserts that identity for every priced model. It depends on the price **ratios**, never
their level — and those ratios are uniform across the lineup: output is **exactly 5.00x** input for
every current model, cache read 0.1x (0.025x on Claude Fable 5.1). A repricing that preserves the
ratios leaves every usage figure and every relative comparison untouched.

Raw (unweighted) token counts are also reported, but they mislead on their own: cache reads are
~90% of raw tokens here and a tenth of the weight. Raw shows volume; ITE shows effort.

**Cross-vendor comparison is where this stops working**, for three separate reasons:

1. **Different tokenisers.** An Anthropic token and an OpenAI token are not the same unit, so token
   counts are not a common currency across agents.
2. **ITE weights are one vendor's ratios.** Applying Claude's 5x output weight to another vendor's
   usage assumes its pricing shape.
3. **Different harnesses.** Turn counts, what the agent chooses to read, and caching behaviour all
   differ, so even a fair token count would measure different work.

So the board **groups usage by agent and never sums across agents**, and says so in the table. To
compare agents, use what is genuinely common: the outcome metrics — first-pass success rate,
resumes per prompt, verification pass rate, wall-clock duration — and dollars, which are the one
true common denominator across vendors. Cost *per completed feature* is the decision-relevant
number for choosing an agent; raw tokens are not.

Codex token parsing is implemented best-effort and is **unverified** — this hub runs `claude`, so
there was no real Codex log to test against. Copilot's CLI reports no usage at all, so its runs
carry outcomes and duration only. Both degrade to empty rather than to a guess.

### 8.2 Which metrics actually compare two prompts

Raw dollars is the wrong comparator between prompts, because tier dominates it. Feature #72's two prompts, measured:

| | `joornalo-cms` | `joornalo-public-front` |
|---|---|---|
| tier / model | Standard / sonnet-5 | Light / haiku-4.5 |
| **cost (reported)** | **$0.3825** | **$0.1225** |
| turns | 16 | 12 |
| wall clock | 90s | 64s |
| output tokens (work produced) | 4,651 | 3,551 |
| cache-read tokens (context) | 600,785 | 316,574 |
| context re-read per turn | 37.5K | 26.4K |
| cost per turn | $0.0239 | $0.0102 |
| $ per 1K output tokens | $0.082 | $0.035 |

The cms prompt looks 3.1x more expensive, but it produced only 1.3x the output in 1.3x the turns. Most of the gap is the tier, which was a deliberate choice. So the board reports two different families of number, and never conflates them:

**Tier-dependent (budget questions — "what did this cost"):** `cost_usd`, cost per feature, cost per turn. Compare these only *within* a tier, or against the same prompt's history.

**Tier-independent (efficiency questions — "was this prompt any good"):** turns, output tokens, wall clock, **context re-read per turn**, resumes, verification attempts. These compare across any two prompts, because they measure work and friction rather than price.

**The single most actionable metric is context re-read per turn.** Cache-read is **91% / 89%** of all billable tokens in these two runs — the spend is re-reading context, not producing output. It is also the one number a prompt author controls: a tighter prompt with fewer required reads moves it directly. Cost per turn moves when you change model; context re-read per turn moves when you change the *prompt*.

**For quality, cost is a lagging indicator — count friction instead.** `resumes` and `verify` attempts are what separate a prompt that worked from one that merely finished. A prompt needing two resumes cost 3x its headline figure and the headline never says so. `render` therefore reports cost per feature **alongside** resumes and verification attempts, never alone.

### 8.3 Backfill

`Prompts/Implemented/` already holds run reports for every shipped feature; `.dispatch/runs/*.json` holds full detail for anything run on this machine. `backfill` parses both — the JSON where present, the markdown tables where not — and seeds the ledger, marking reconstructed events `"backfilled": true`.

This matters for adoption: the first `render` produces a board with real history instead of one feature, which is the difference between a dashboard someone trusts and one they ignore. Fields the tables never carried (tokens, duration) are `null`, and the readers' coverage line says so.

---

## 9. Integration into the framework

| File | Change |
|---|---|
| [.gitignore](../.gitignore) | unchanged — `metrics/` is committed on purpose; `.dispatch/` stays ignored |
| [AGENTS.md](../AGENTS.md) | File Map: add `metrics/ledger.jsonl`, `metrics/prices.tsv`, `METRICS.md`, `scripts/metrics.sh`, `design/`. Context Budget: extend the "Never open `CHANGELOG.md`" rule to `METRICS.md` and the ledger |
| [WORKFLOW.md](../WORKFLOW.md) | Context Budget table: one row for the metrics rule. Step 3: document `verify --fail`. Step 4: `metrics.sh render` in the close-out checklist |
| [skills/close-loop](../skills/close-loop/SKILL.md) | New step between §5 (changelog) and §6 (archive): run `scripts/metrics.sh render`. One command, zero reads — it must not add a single token of context |
| [skills/dispatch-prompts](../skills/dispatch-prompts/SKILL.md) | Mention `verify --fail` as the counterpart to `verify` |
| [.claude/settings.json](../.claude/settings.json) | The `SessionEnd` hook, plus allow-list entries for `scripts/metrics.sh *` |

Per the standing rule, editing `AGENTS.md` and the templates is a **human step between runs**, never done from inside a workflow step. These edits belong to the implementation of this design, not to any Step 0–4 session.

---

## 10. Non-goals

- **No live or streaming telemetry.** Events are written at completion boundaries. Run progress stays where it is — `dispatch.sh status`.
- **No budget gating or per-feature estimates.** Measure first. Enforcing a cost ceiling before there is a baseline produces false alarms and pressure to under-scope.
- **No external service.** The ledger is a file in the repo. No collector, no daemon, no account.
- **No feature state.** `METRICS.md` never renders 🔄/✅ — that is `STATUS.md`'s job (P1).
- **No retroactive token accounting for hub sessions predating the hook.** Transcripts rotate; the backfill covers dispatch runs only, and the board says so.

---

## 11. Decisions to confirm

| # | Question | Recommendation |
|---|---|---|
| D1 | Is `design/` the right home for framework self-improvement docs? | Yes — outside every routed namespace. Alternative: a top-level `DESIGN-*.md`, which pollutes the `NN-{service}.md` namespace. |
| D2 | Commit the ledger, or keep it local? | **Commit.** A local ledger cannot answer "is this framework working for the team", which is the whole motivation. It is append-only JSONL; conflicts are trivial to resolve (union of lines). |
| D3 | Should `verify --fail` flip the status back to `Generated`? | **No.** `Applied` correctly means "implemented, not accepted". Flipping to `Generated` would let `run` re-dispatch it into a fresh session and lose the resume thread. |
| D4 | Auto-record a verification failure on `resume`? (§6.2) | **Yes, with an opt-out.** Without it the pass rate is fiction. |
| D5 | HTML dashboard in v1? | **No — defer.** `METRICS.md` is greppable, diffable in git, and free to regenerate. Build the HTML only if the markdown board proves insufficient. |
| D6 | Ship `prices.tsv` with real prices? | **No.** Placeholders plus a pointer. Baked-in prices rot silently and produce confidently wrong dollar figures (P5). |

---

## 12. Implementation order

Each phase is independently useful and independently revertable.

**Phase 1 — ledger + backfill.** `metrics.sh` skeleton, schema v1, `emit`, `backfill`, `report`. Touches no existing script.
*Done when:* `backfill` reconstructs every shipped feature from `Prompts/Implemented/`, and `report` prints failure rate and dispatch cost per feature from history alone.

**Phase 2 — dispatch instrumentation.** `__worker` + `record_abort` + `merge_one` emit; `verify --fail`; the `resume` nudge.
*Done when:* a dispatch → verify-fail → resume → verify-pass → merge cycle produces five correct ledger lines, and the run report tables are unchanged apart from the new verification entry.

**Phase 3 — `METRICS.md` + framework wiring.** `render`, the `AGENTS.md`/`WORKFLOW.md` rules, the `close-loop` step.
*Done when:* close-out regenerates the board with no file reads, and `render` twice in a row is a no-op diff (P3).

**Phase 4 — hub session capture.** `metrics.sh session`, the `SessionEnd` hook, `prices.tsv`.
*Done when:* closing a session writes one `hub_session` line attributed to the right step and feature, and cost-per-feature shows both halves with their bases.

**Phase 5 — HTML dashboard.** Only if Phase 3's board proves insufficient (D5).

Phases 1–3 deliver throughput, failure rate, duration and dispatch cost-per-feature. **Phase 4 is what makes cost-per-feature true**, since hub sessions are the larger half of the spend — it is the last phase only because it is the one with an external dependency (the hook contract), not because it is the least important.

---

## Appendix A — Worked example: what feature #72 actually cost

Measured during design from `.dispatch/runs/*.json` and the eight hub transcripts for this workspace. Every dollar figure below is either reported by the CLI or derived by the §7 formula that reproduces reported costs exactly.

**Feature #72 — Boolean Template Params.** Two services, two prompts, no resumes, verified first look.

| Step | Session | Cost | of which: context re-read | cache write | output |
|---|---|---:|---:|---:|---:|
| 1 design | `4b5f1322` | $4.14 | $1.02 | $2.02 | $1.11 |
| 2 cascade & prompt | `c187273b` | $6.31 | $3.17 | $1.80 | $1.33 |
| 3 dispatch (hub side) | `3c877c71` | $2.09 | $0.90 | $0.69 | $0.50 |
| 3 dispatch (**the 2 headless runs**) | — | **$0.51** | $0.15 | $0.28 | $0.06 |
| 4 close-loop | `5be8e939` | $1.02 | $0.48 | $0.39 | $0.16 |
| | | | | | |
| **Hub total** (4 sessions) | | **$13.56** | | | **96.4%** |
| **Dispatch total** (2 runs) | | **$0.51** | | | **3.6%** |
| **FEATURE TOTAL** | | **$14.07** | | | |

### What this establishes

1. **[WORKFLOW.md:25](../WORKFLOW.md#L25) is right, and understated.** It says hub sessions dominate "by several times." The measured ratio is **27x** — the hub is 96.4% of the cost of shipping this feature. **A metrics system that instrumented only the dispatcher would measure 3.6% of the bill and call it cost-per-feature.** This single number is the argument for Phase 4.

2. **Context re-read is 41% of the total feature cost** ($5.72 of $14.07) — the largest single line, larger than output and cache writes combined. The framework's context-budget rules are aimed at exactly this, and are currently unmeasured. The board makes the rule's effect visible.

3. **Step 2 is the most expensive step** ($6.31), not Step 1 design ($4.14) — despite Step 2 running on the cheaper Standard tier by policy. Cause: it re-reads the largest context (6.3M cache-read tokens across 72 messages, ~88K per message). Worth knowing before optimizing the wrong step; exactly the kind of finding the board is for.

4. **Every hub session here ran `claude-opus-5`** — including Steps 2, 3 and 4, which policy assigns to Standard. Four of four hub sessions were off-policy. This is what the §8.1 *Model use by step* table exists to surface, and it was invisible until measured.

**Whole-workspace figure:** 8 hub sessions to date total **$31.52** (all `claude-opus-5`), against **$0.51** of dispatched implementation. The three sessions predating feature #72 ($11.54) are bootstrap and spec-import work.

> **Caveat.** One feature is one data point, and #72 was small — two single-file changes, no resumes, no verification failures. The per-feature total will move with feature size; the *hub-to-dispatch ratio* is the number worth watching across features, and it is the one the board should trend.


---

## Appendix B — Deviations taken during implementation

Five things changed once the design met real data. Each is a case where the proposed rule was wrong, not merely inconvenient.

**1. `prices.tsv` ships filled, not with `_` placeholders (reverses D6).**
D6 refused baked-in prices because they rot silently. `selftest` removes the silence: it recomputes every reported cost from the table and fails on any drift past $0.0001, so a stale row becomes a failing test rather than wrong dollars. Shipping placeholders would have meant the board read `n/a` until someone filled it in by hand — strictly worse, with the rot risk now covered by other means. Each row carries a `verified` date, and `render` flags rows older than 90 days. The caveat that remains, and is printed on the board: `selftest` can only confirm models that appear in dispatch runs, so a hub-only model such as `claude-opus-5` — the largest cost driver — is **not** covered by it.

**2. Hub sessions are backfilled after all (reverses a non-goal in §10).**
§10 ruled out retroactive hub accounting on the assumption that transcripts had rotated away. They had not: all eight sessions for this workspace were on disk, so `backfill` recovers them. This is what makes the historical board show a hub-to-dispatch ratio at all. The non-goal now reads correctly as: no accounting for sessions whose transcripts are *gone*.

**3. Feature attribution needed a third signal, and Step 1 detection needed a fourth.**
§5.6's two rules were both insufficient:
- A skill is invoked *with the feature as its argument* (`Skill(skill="close-loop", args="boolean-template-params")`) — the most direct statement of intent available, and initially ignored. Without it the Step 3 and Step 4 sessions of feature #72 went unattributed, because they drive scripts and never name the prompt file.
- References must be split into reads and writes. A session that merely *reads* a prompt file must not be billed to it — otherwise this very implementation session, which greps the hub constantly, bills itself to whatever feature it last looked at. Writes claim; reads do not. Skill-bearing sessions are exempt, since they are per-feature by construction.
- Inferring "Step 1 design" from touching any feature file was far too loose, for the same reason. Step 1 is now recognised by what it actually does: **write `Features/FEATURE-*.md`**. A session that matches nothing stays unattributed — visible on the board as its own row, which is more useful than a wrong attribution.

**4. Backfill had to read two generations of report table.**
Prompts written before the current `dispatch.sh` record `| Model | sonnet |`; today's record `| Agent / model | claude / sonnet |`. Backfill reads both. The older rows hold a **tier alias**, not a model id, and the real model is not recoverable — so aliases are rendered marked (`sonnet*`) with a footnote rather than guessed into a concrete id, which would have silently corrupted the policy-conformance table.

**5. Report-table timestamps are local, not UTC.**
`dispatch.sh` writes report times with `date` (no `-u`); the ledger is UTC. Stamping the local string with a `Z` put every backfilled run **5 hours before** the hub session that launched it, so runs sorted ahead of their own dispatch. `backfill` now converts local → UTC properly. Caught only by reading a per-feature chronology — the aggregate totals looked fine throughout.

**6. `n/a` had to be distinguished from `$0.00`, and partial totals marked.**
A feature whose hub sessions predate the ledger was initially reported as having cost `$0.00` to design — a confident falsehood. Missing data now renders `n/a`, and any total built from a half-known feature is suffixed `+` and labelled a floor, not a figure.

### What the acceptance checks actually showed

| Check | Result |
|---|---|
| `selftest` — derived vs reported | 3/3 exact, worst delta `$0.00000000` |
| `backfill` from history | 35 run/verify/merge events + 8 hub sessions recovered, 4 features |
| Feature #72 hub cost vs the hand computation | `$13.56` = `$13.56` |
| `render` twice in a row | byte-identical (P3) |
| verify-fail → verify-pass cycle | both recorded, `attempt` increments, status correctly stays `Applied` on fail |
| `resume` nudge | records the rejection, `--no-verify-fail` opts out |
| `session` hook with payload / with nothing | both record; idempotent on re-run (8 sessions stay 8) |
| Emit with an unparseable ledger or missing price row | exits 0, dispatch unaffected |
| Per-feature chronology (Step 1 → 2 → 3 hub → runs → 4) | correct after the timezone fix |
