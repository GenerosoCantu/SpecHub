#!/usr/bin/env bash
# scripts/dispatch.sh — WORKFLOW.md Step 3 dispatcher.
#
# Runs implementation prompts from the spec hub as headless coding-agent sessions (Claude Code,
# Codex CLI or GitHub Copilot CLI — AGENT_CLI in spechub.conf), each inside its own git worktree
# of the target service repo, all in parallel.
#
#   scripts/dispatch.sh status                       the board: every active prompt, its state and its last run
#   scripts/dispatch.sh run <prompt> [<prompt>...]   dispatch one or more Generated prompts (parallel, detached)
#   scripts/dispatch.sh run --all                    dispatch every Generated prompt in Prompts/
#   scripts/dispatch.sh resume <prompt> "<message>"  continue a prompt's session (bug fixes, follow-ups; detached)
#   scripts/dispatch.sh wait [--timeout <s>]         block until no session runs; exit 0 ok / 1 failed / 2 still running
#   scripts/dispatch.sh verify <prompt>              human gate: flip Applied → Verified
#   scripts/dispatch.sh serve <prompt>|--all         (re)start the stack with each prompt's service on its worktree
#   scripts/dispatch.sh merge <prompt> [--push]      Step 4: merge branch into the base branch, remove worktree, delete
#                                                    branch, move the service back to the main checkout
#   scripts/dispatch.sh merge --all [--push]         merge every Verified prompt
#   scripts/dispatch.sh clean [--force]              delete every <repo>-worktrees/ leftover (registered ones need --force)
#
# <prompt> is a file name in Prompts/ (with or without .md) or a path to a prompt file.
# Add --dry-run to `run` to print the plan without touching any repo.
# Add --wait to `run`/`resume` to block until the sessions finish (same as running `wait` after).
# Add --no-serve to `run`/`resume` to skip the automatic service restart.
#
# `run` and `resume` return immediately: the sessions run under a detached supervisor (own process
# group, reparented to init), so the terminal or agent that launched them can go away. Every session
# ends with a Run/Resume entry in its prompt's report — Result ok, ERROR (with a Diagnosis row), or
# ABORTED when the process was killed — and `.dispatch/active/` tracks what is still running.
#
# Services are run through scripts/stack.sh (table in spechub.conf): after `run`/`resume` the affected
# services are restarted from their worktrees (-w <branch>) so verification needs no manual switch;
# `merge` stops a service running from the worktree and restarts it from the main checkout.
#
# Environment overrides (spechub.conf supplies AGENT_CLI, MODEL_*, BASE_BRANCH, WORKTREE_COPY_FILES, WORKTREE_LINK_DIRS):
#   DISPATCH_AGENT_CLI         claude | codex | copilot — which headless CLI runs the prompts (default: AGENT_CLI, else claude)
#   DISPATCH_AGENT_BIN         path to that CLI (default: found on PATH; for claude also the VS Code extension binary)
#   DISPATCH_BASE_BRANCH       base branch for feature branches (default: BASE_BRANCH from spechub.conf, else main)
#   DISPATCH_PERMISSION_MODE   claude only: permission mode for headless sessions (default: acceptEdits)
#   DISPATCH_ALLOWED_TOOLS     claude only: comma-separated pre-approved tools (see DEFAULT_ALLOWED_TOOLS); codex runs
#                              with --full-auto, copilot with --allow-all-tools
#   DISPATCH_WORKTREE_ROOT     where worktrees go (default: <repo-parent>/<repo-name>-worktrees)
#   DISPATCH_DEPS              link | install | none — how a fresh worktree gets its dependencies (default: link:
#                              symlink WORKTREE_LINK_DIRS from the main checkout; install: run the service's
#                              install command from spechub.conf inside the worktree)
#   DISPATCH_COPY_FILES        gitignored files copied into a fresh worktree (default: WORKTREE_COPY_FILES)
#   DISPATCH_TRUST             1 | 0 — claude only: pre-register each worktree as trusted in ~/.claude.json (default: 1);
#                              without it the headless session dies on the trust dialog
#   DISPATCH_SERVE             stack | affected | none — after run/resume: bring up the whole stack with the
#                              affected services on their worktrees, only restart the affected ones, or nothing (default: stack)
#   DISPATCH_MAX_TURNS         claude only: cap on agent turns per run (default: 150; set to 0 for unlimited)
#   DISPATCH_RUNS_DIR          where run logs go (default: <hub>/.dispatch/runs, gitignored)
#   DISPATCH_PROMPTS_DIR       where the prompt files live (default: <hub>/Prompts; used by the self-test)
#
# The prompt header's "Recommended model" names a TIER (Light | Standard | Advanced); spechub.conf maps
# each tier to a concrete model for the chosen CLI (MODEL_LIGHT, MODEL_STANDARD, MODEL_ADVANCED).
# The claude adapter is the one exercised end to end; the codex and copilot adapters follow those CLIs'
# documented non-interactive flags — if your CLI version differs, the whole adapter is run_headless()
# and summarize_run() below.
#
# Compatible with the macOS system bash (3.2).

set -euo pipefail

HUB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="$HUB_DIR/spechub.conf"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"
PROMPTS_DIR="${DISPATCH_PROMPTS_DIR:-$HUB_DIR/Prompts}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
RUNS_DIR="${DISPATCH_RUNS_DIR:-$HUB_DIR/.dispatch/runs}"
ACTIVE_DIR="$(dirname "$RUNS_DIR")/active"
BASE_BRANCH="${DISPATCH_BASE_BRANCH:-${BASE_BRANCH:-main}}"
PERMISSION_MODE="${DISPATCH_PERMISSION_MODE:-acceptEdits}"
DEPS_MODE="${DISPATCH_DEPS:-link}"
MAX_TURNS="${DISPATCH_MAX_TURNS:-150}"
[ "$MAX_TURNS" = "0" ] && MAX_TURNS=""
COPY_FILES="${DISPATCH_COPY_FILES:-${WORKTREE_COPY_FILES:-.env .env.*}}"
LINK_DIRS="${WORKTREE_LINK_DIRS:-node_modules .venv vendor}"
TRUST="${DISPATCH_TRUST:-1}"
SERVE="${DISPATCH_SERVE:-stack}"
STACK="$HUB_DIR/scripts/stack.sh"
PROJECT="${PROJECT_NAME:-the project}"
AGENT_CLI="${DISPATCH_AGENT_CLI:-${AGENT_CLI:-claude}}"
case "$AGENT_CLI" in claude|codex|copilot) ;; *) printf '[dispatch] ERROR: AGENT_CLI must be claude, codex or copilot (got %s)\n' "$AGENT_CLI" >&2; exit 1 ;; esac
# Tier → model. Defaults per CLI; override in spechub.conf (MODEL_LIGHT / MODEL_STANDARD / MODEL_ADVANCED).
case "$AGENT_CLI" in
  claude)  D_LIGHT=haiku;        D_STANDARD=sonnet;   D_ADVANCED=opus ;;
  codex)   D_LIGHT=gpt-5-mini;   D_STANDARD=gpt-5;    D_ADVANCED=gpt-5 ;;
  copilot) D_LIGHT=gpt-5-mini;   D_STANDARD=gpt-5;    D_ADVANCED=claude-opus-4.1 ;;
esac
MODEL_LIGHT="${MODEL_LIGHT:-$D_LIGHT}"; MODEL_STANDARD="${MODEL_STANDARD:-$D_STANDARD}"; MODEL_ADVANCED="${MODEL_ADVANCED:-$D_ADVANCED}"

# Pre-approved tools for the headless implementation session. Edits are covered by
# the permission mode; this list is what Bash is allowed to run without a human.
# Build/test/lint tools of every supported stack are listed; git is limited to local operations (no push).
DEFAULT_ALLOWED_TOOLS="Read,Edit,Write,MultiEdit,Glob,Grep,LS,\
Bash(npm *),Bash(npx *),Bash(node *),Bash(node_modules/.bin/*),Bash(yarn *),Bash(pnpm *),Bash(ng *),Bash(tsc *),\
Bash(mvn *),Bash(./mvnw *),Bash(gradle *),Bash(./gradlew *),Bash(java *),\
Bash(python *),Bash(python3 *),Bash(pip *),Bash(pip3 *),Bash(pytest *),Bash(poetry *),Bash(uv *),Bash(ruff *),Bash(black *),Bash(mypy *),\
Bash(go *),Bash(gofmt *),Bash(cargo *),Bash(rustfmt *),Bash(dotnet *),Bash(make *),\
Bash(bundle *),Bash(rails *),Bash(bin/rails *),Bash(rspec *),Bash(rubocop *),Bash(php *),Bash(composer *),\
Bash(git status*),Bash(git diff*),Bash(git log*),Bash(git show*),Bash(git add *),Bash(git commit *),Bash(git branch*),Bash(git stash*),Bash(git restore *),\
Bash(ls *),Bash(cat *),Bash(head *),Bash(tail *),Bash(grep *),Bash(rg *),Bash(find *),Bash(mkdir *),Bash(cp *),Bash(mv *),Bash(rm *),Bash(wc *),Bash(sed *),Bash(awk *),Bash(diff *),Bash(tree *),Bash(pwd),Bash(echo *),Bash(printf *),\
Bash(for *),Bash(while *),Bash(if *),Bash(test *),Bash(xargs *),Bash(sort *),Bash(uniq *),Bash(cut *),Bash(jq *),Bash(true),Bash(touch *)"
ALLOWED_TOOLS="${DISPATCH_ALLOWED_TOOLS:-$DEFAULT_ALLOWED_TOOLS}"

DRY_RUN=0
PUSH=0
FORCE=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { printf '[dispatch] %s\n' "$*" >&2; }
die()  { printf '[dispatch] ERROR: %s\n' "$*" >&2; exit 1; }
now()  { date '+%Y-%m-%d %H:%M'; }
stamp(){ date '+%Y%m%d-%H%M%S'; }

find_agent() {  # path of the headless CLI selected by AGENT_CLI
  local bin="${DISPATCH_AGENT_BIN:-${AGENT_BIN:-}}"
  if [ -n "$bin" ]; then
    [ -x "$bin" ] || die "agent binary is not executable: $bin"
    echo "$bin"; return
  fi
  if command -v "$AGENT_CLI" >/dev/null 2>&1; then command -v "$AGENT_CLI"; return; fi
  if [ "$AGENT_CLI" = claude ]; then
    local candidate
    candidate="$(ls -d "$HOME"/.vscode/extensions/anthropic.claude-code-*/resources/native-binary/claude 2>/dev/null | sort -V | tail -1 || true)"
    [ -n "$candidate" ] && [ -x "$candidate" ] && { echo "$candidate"; return; }
  fi
  case "$AGENT_CLI" in
    claude)  die "claude CLI not found. Install it (npm i -g @anthropic-ai/claude-code) or set AGENT_BIN in spechub.conf." ;;
    codex)   die "codex CLI not found. Install it (npm i -g @openai/codex) or set AGENT_BIN in spechub.conf." ;;
    copilot) die "copilot CLI not found. Install it (npm i -g @github/copilot) or set AGENT_BIN in spechub.conf." ;;
  esac
}

# Resolve a prompt argument (name, name.md, or path) to an absolute file path.
resolve_prompt() {
  local arg="$1" p
  if [ -f "$arg" ]; then p="$arg"
  elif [ -f "$PROMPTS_DIR/$arg" ]; then p="$PROMPTS_DIR/$arg"
  elif [ -f "$PROMPTS_DIR/$arg.md" ]; then p="$PROMPTS_DIR/$arg.md"
  else die "Prompt not found: $arg (looked in $PROMPTS_DIR)"; fi
  cd "$(dirname "$p")" && printf '%s/%s\n' "$(pwd)" "$(basename "$p")"
}

# Read a dispatch-header field: strips the "> **Label:**" prefix, backticks, and surrounding whitespace.
header_field() {
  local file="$1" label="$2"
  grep -m1 -E "^> \*\*${label}:\*\*" "$file" 2>/dev/null \
    | sed -E "s/^> \*\*${label}:\*\*[[:space:]]*//; s/<!--.*-->//; s/\`//g; s/[[:space:]]+$//" || true
}

prompt_status() { header_field "$1" "Status" | awk '{print $1}'; }

# "Standard — reason" → the concrete model for that tier. Accepts Light|Standard|Advanced (and the
# legacy Claude names haiku|sonnet|opus). Falls back to Standard when unrecognized.
model_alias() {
  local raw first
  raw="$(header_field "$1" "Recommended model")"
  first="$(printf '%s' "$raw" | awk '{print tolower($1)}')"
  case "$first" in
    light|small|haiku)       echo "$MODEL_LIGHT" ;;
    standard|medium|sonnet)  echo "$MODEL_STANDARD" ;;
    advanced|large|opus)     echo "$MODEL_ADVANCED" ;;
    *) log "Unrecognized model tier '$raw' — defaulting to Standard ($MODEL_STANDARD)"; echo "$MODEL_STANDARD" ;;
  esac
}

# "/path/to/repo" or "`/path`" — expand ~ and require the directory to be a git repo.
repo_path() {
  local raw; raw="$(header_field "$1" "Target repo")"
  raw="${raw/#\~/$HOME}"
  [ -n "$raw" ] || die "No 'Target repo' in dispatch header: $1"
  [ -d "$raw/.git" ] || die "Target repo is not a git repository: $raw"
  echo "$raw"
}

branch_name() {
  local b; b="$(header_field "$1" "Branch" | awk '{print $1}')"
  [ -n "$b" ] || die "No 'Branch' in dispatch header: $1"
  echo "$b"
}

worktree_path() {
  local repo="$1" branch="$2" root
  root="${DISPATCH_WORKTREE_ROOT:-$(dirname "$repo")/$(basename "$repo")-worktrees}"
  printf '%s/%s\n' "$root" "$(printf '%s' "$branch" | tr '/' '-')"
}

set_status() {
  local file="$1" new="$2" tmp
  tmp="$(mktemp)"
  sed -E "s/^(> \*\*Status:\*\*)[[:space:]]*[A-Za-z]+/\1 ${new}/" "$file" > "$tmp" && mv "$tmp" "$file"
}

json_field() {  # json_field <file> <key>  — string or number value of a top-level key
  local file="$1" key="$2"
  tr -d '\n' < "$file" \
    | sed -E "s/.*\"${key}\":[[:space:]]*(\"([^\"\\\\]|\\\\.)*\"|[-0-9.eE+]+|true|false|null).*/\1/" \
    | sed -E 's/^"//; s/"$//'
}

append_report() {  # append_report <prompt-file> <kind> <fields-markdown-table-rows>
  local file="$1" kind="$2" rows="$3"
  if ! grep -q '^## Dispatch Run Report' "$file"; then
    printf '\n---\n\n## Dispatch Run Report\n\nAppended automatically by `scripts/dispatch.sh`. Newest entry last. Do not edit by hand.\n' >> "$file"
  fi
  printf '\n### %s — %s\n\n| Field | Value |\n|---|---|\n%s\n' "$kind" "$(now)" "$rows" >> "$file"
}

# ---------------------------------------------------------------------------
# Worktree lifecycle
# ---------------------------------------------------------------------------

ensure_base_branch() {  # warn (don't mutate) if local base is behind origin
  local repo="$1"
  git -C "$repo" show-ref --verify --quiet "refs/heads/$BASE_BRANCH" \
    || die "Base branch '$BASE_BRANCH' does not exist in $repo (set BASE_BRANCH in spechub.conf)"
  if git -C "$repo" fetch --quiet origin "$BASE_BRANCH" 2>/dev/null; then
    local behind
    behind="$(git -C "$repo" rev-list --count "$BASE_BRANCH..origin/$BASE_BRANCH" 2>/dev/null || echo 0)"
    [ "$behind" = "0" ] || log "WARNING: $(basename "$repo") local '$BASE_BRANCH' is $behind commit(s) behind origin/$BASE_BRANCH — worktrees branch from the LOCAL base."
  else
    log "WARNING: could not fetch origin/$BASE_BRANCH for $(basename "$repo") — using local '$BASE_BRANCH' as is."
  fi
}

setup_worktree() {  # setup_worktree <repo> <branch> <worktree>
  local repo="$1" branch="$2" wt="$3"
  if [ -d "$wt" ]; then
    log "Worktree already exists, reusing: $wt"
    if [ -n "$(git -C "$wt" status --porcelain)" ]; then
      git -C "$wt" stash push -u -q -m "dispatch: leftovers found before run $(stamp)" \
        && log "WARNING: $wt had uncommitted changes (an earlier run was killed?) — stashed them so the session starts clean"
    fi
  else
    mkdir -p "$(dirname "$wt")"
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
      log "Branch $branch exists — attaching a worktree to it"
      git -C "$repo" worktree add --quiet "$wt" "$branch"
    else
      git -C "$repo" worktree add --quiet -b "$branch" "$wt" "$BASE_BRANCH"
    fi
  fi

  # Gitignored local files (env, local config) are needed for builds, tests and dev servers.
  local pat f rel
  for pat in $COPY_FILES; do
    for f in "$repo"/$pat; do
      [ -f "$f" ] || continue
      rel="${f#$repo/}"
      [ -e "$wt/$rel" ] && continue
      mkdir -p "$(dirname "$wt/$rel")" && cp "$f" "$wt/$rel"
    done
  done

  [ "$TRUST" = "1" ] && [ "$AGENT_CLI" = claude ] && ensure_trust "$wt" "$repo"

  case "$DEPS_MODE" in
    link)
      local d
      for d in $LINK_DIRS; do
        if [ -d "$repo/$d" ] && [ ! -e "$wt/$d" ]; then ln -s "$repo/$d" "$wt/$d"; fi
      done ;;
    install)
      local svc; svc="$(service_for_repo "$repo")"
      if [ -n "$svc" ]; then log "Installing dependencies in $wt"; "$STACK" install "$svc" -w "$branch" >&2 || log "WARNING: install failed in $wt"
      else log "WARNING: $repo is not a service in spechub.conf — cannot run its install command; install by hand in $wt"; fi ;;
    none) ;;
    *) die "DISPATCH_DEPS must be link, install, or none" ;;
  esac
}

# Claude Code only: a worktree is a new project path; without a trust entry the headless
# session exits immediately ("workspace has not been trusted"). Add the entry if missing.
ensure_trust() {  # ensure_trust <path>... — the worktree and its main repo (project settings are keyed on the latter)
  local cfg="$HOME/.claude.json"
  [ -f "$cfg" ] || return 0
  command -v python3 >/dev/null 2>&1 || { log "WARNING: python3 not found — cannot pre-register trust for $*"; return 0; }
  python3 - "$cfg" "$@" <<'PY' || log "WARNING: could not update $cfg — trust the worktree by hand if the run's log says the workspace is not trusted"
import json, os, sys, tempfile
cfg, paths = sys.argv[1], sys.argv[2:]
with open(cfg) as fh: data = json.load(fh)
projects = data.setdefault("projects", {})
changed = []
for p in paths:
    entry = projects.setdefault(p, {})
    if entry.get("hasTrustDialogAccepted") is True: continue
    entry["hasTrustDialogAccepted"] = True; changed.append(p)
if changed:
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(cfg), prefix=".claude.json.")
    with os.fdopen(fd, "w") as fh: json.dump(data, fh, indent=2)
    os.replace(tmp, cfg)
    for p in changed: print(f"[dispatch] trust registered for {p}", file=sys.stderr)
PY
}

remove_worktree() {  # remove_worktree <repo> <worktree> — unregister, delete the directory, drop the root when empty
  local repo="$1" wt="$2"
  if git -C "$repo" worktree list --porcelain | grep -qx "worktree $wt"; then
    git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
  fi
  [ -e "$wt" ] && rm -rf "$wt"
  git -C "$repo" worktree prune
  prune_worktree_root "$repo" "$(dirname "$wt")"
}

prune_worktree_root() {  # prune_worktree_root <repo> <root> — delete the root once no registered worktree lives in it
  local repo="$1" root="$2"
  [ -d "$root" ] || return 0
  git -C "$repo" worktree list --porcelain | grep -q "^worktree $root/" && return 0
  case "$root" in
    *-worktrees) rm -rf "$root"; log "Removed $root" ;;
    *) rmdir "$root" 2>/dev/null || log "WARNING: $root is not empty and not a *-worktrees dir — left in place" ;;
  esac
}

# ---------------------------------------------------------------------------
# Services (scripts/stack.sh)
# ---------------------------------------------------------------------------

service_for_repo() { [ -x "$STACK" ] && [ -f "$CONF" ] && "$STACK" service-for "$1" 2>/dev/null || true; }

service_cwd() {  # service_cwd <service> — working directory of the running service, or empty
  local pid; pid="$("$STACK" is-running "$1" 2>/dev/null)" || return 0
  [ -n "$pid" ] || return 0
  lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1
}

# serve_pairs "<repo>|<branch>" ... — restart each affected service from its worktree; with
# SERVE=stack also bring up everything else (already-running services are left alone).
serve_pairs() {
  [ "$SERVE" = "none" ] && return 0
  [ -x "$STACK" ] && [ -f "$CONF" ] || { log "WARNING: scripts/stack.sh or spechub.conf not found — start the services by hand"; return 0; }
  local pair svc affected=""
  for pair in "$@"; do
    svc="$(service_for_repo "${pair%%|*}")"
    [ -n "$svc" ] && affected="$affected $svc"
  done
  if [ "$SERVE" = "stack" ]; then
    local others="" name
    while IFS='|' read -r name _ _; do
      case " $affected " in *" $name "*) ;; *) others="$others $name" ;; esac
    done < <("$STACK" repos)
    # shellcheck disable=SC2086
    "$STACK" start $others >&2 || true
  fi
  for pair in "$@"; do
    svc="$(service_for_repo "${pair%%|*}")"
    [ -n "$svc" ] || { log "WARNING: no stack.sh service for ${pair%%|*} — run it by hand"; continue; }
    log "Restarting $svc from worktree ${pair#*|}"
    "$STACK" restart "$svc" -w "${pair#*|}" >&2 || log "WARNING: could not restart $svc"
  done
  [ -n "$affected" ] && log "Services on worktrees:$affected — 'scripts/stack.sh status' for the board, 'scripts/stack.sh logs' to follow."
  return 0
}

# ---------------------------------------------------------------------------
# Headless session
# ---------------------------------------------------------------------------

system_preamble() {  # system_preamble <prompt-name> <repo> <branch> <worktree>
  cat <<EOF
You are executing an implementation prompt dispatched from the $PROJECT spec hub (prompt: $1).
Working directory: $4 — a git worktree of $2 on branch '$3', based on '$BASE_BRANCH'.
Rules:
- The repo's instruction file (AGENTS.md / CLAUDE.md) in this directory is already in your context; follow it. Do not re-read it.
- Never switch branches, never modify files outside this directory, never push.
- Read only the files the prompt names plus what you must touch; do not survey the repo.
- Before finishing: build, run the tests, and lint/format ONLY the files you changed (run the repo's linter on those file paths) — never a repo-wide lint or format that rewrites untouched files. Fix what breaks.
- When done, stage and commit ALL work with a conventional commit message that references "$1". Leave the tree clean.
- If anything in the prompt cannot be implemented as written, implement the rest and end your final message with a section titled "DEVIATIONS" listing each one and why. If there are none, end with "DEVIATIONS: none".
EOF
}

run_headless() {  # run_headless <worktree> <model> <log-json> <log-txt> [--resume <sid>] -- <prompt-text-file> <system-preamble>
  local wt="$1" model="$2" out_json="$3" out_txt="$4"; shift 4
  local sid=""
  if [ "${1:-}" = "--resume" ]; then sid="$2"; shift 2; fi
  [ "${1:-}" = "--" ] && shift
  local prompt_text_file="$1" preamble="$2"
  local bin; bin="$(find_agent)"
  case "$AGENT_CLI" in
    claude) run_claude "$wt" "$bin" "$model" "$out_json" "$out_txt" "$sid" "$prompt_text_file" "$preamble" ;;
    codex)  run_codex  "$wt" "$bin" "$model" "$out_json" "$out_txt" "$sid" "$prompt_text_file" "$preamble" ;;
    copilot) run_copilot "$wt" "$bin" "$model" "$out_json" "$out_txt" "$sid" "$prompt_text_file" "$preamble" ;;
  esac
}

# --- adapter: Claude Code ---------------------------------------------------------
run_claude() {  # <wt> <bin> <model> <out_json> <out_txt> <sid|""> <prompt-file> <preamble>
  local wt="$1" bin="$2" model="$3" out_json="$4" out_txt="$5" sid="$6" prompt_file="$7" preamble="$8"
  local extra=()
  [ -n "$MAX_TURNS" ] && extra+=(--max-turns "$MAX_TURNS")
  [ -n "$sid" ] && extra+=(--resume "$sid")
  # CLAUDECODE is set when this script runs from inside a Claude Code session; the nested
  # headless session must not inherit it.
  (
    cd "$wt"
    env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
      "$bin" -p \
        --model "$model" \
        --permission-mode "$PERMISSION_MODE" \
        --allowedTools "$ALLOWED_TOOLS" \
        --append-system-prompt "$preamble" \
        --output-format json \
        "${extra[@]+"${extra[@]}"}" \
        < "$prompt_file" > "$out_json" 2> "$out_txt"
  )
}

# --- adapter: OpenAI Codex CLI ----------------------------------------------------
# `codex exec` runs non-interactively; --full-auto = workspace-write sandbox with auto-approval;
# --json emits JSONL events (thread.started carries the thread id used by `codex exec resume`).
# Codex has no system-prompt flag: the session rules are prepended to the prompt text.
run_codex() {
  local wt="$1" bin="$2" model="$3" out_json="$4" out_txt="$5" sid="$6" prompt_file="$7" preamble="$8"
  local combined; combined="$(mktemp)"
  { printf '## Session rules (from the dispatcher)\n\n%s\n\n---\n\n' "$preamble"; cat "$prompt_file"; } > "$combined"
  (
    cd "$wt"
    if [ -n "$sid" ]; then
      "$bin" exec resume --json --full-auto --skip-git-repo-check "$sid" - < "$prompt_file" > "$out_json" 2> "$out_txt"
    else
      "$bin" exec --json --full-auto --skip-git-repo-check --model "$model" - < "$combined" > "$out_json" 2> "$out_txt"
    fi
  ); local rc=$?
  rm -f "$combined"; return $rc
}

# --- adapter: GitHub Copilot CLI --------------------------------------------------
# `copilot -p` runs one prompt non-interactively; --allow-all-tools approves tool use; --resume continues
# a session. No system-prompt flag: the session rules are prepended to the prompt text.
run_copilot() {
  local wt="$1" bin="$2" model="$3" out_json="$4" out_txt="$5" sid="$6" prompt_file="$7" preamble="$8"
  local text
  if [ -n "$sid" ]; then text="$(cat "$prompt_file")"
  else text="$(printf '## Session rules (from the dispatcher)\n\n%s\n\n---\n\n' "$preamble"; cat "$prompt_file")"; fi
  local extra=()
  [ -n "$sid" ] && extra+=(--resume "$sid")
  (
    cd "$wt"
    "$bin" -p "$text" --model "$model" --allow-all-tools --no-color "${extra[@]+"${extra[@]}"}" > "$out_json" 2> "$out_txt"
  )
}

summarize_run() {  # summarize_run <out_json> -> sets RUN_SID RUN_COST RUN_TURNS RUN_ERR RUN_RESULT_TAIL
  local f="$1"
  RUN_SID=""; RUN_COST=""; RUN_TURNS=""; RUN_ERR="false"; RUN_RESULT_TAIL=""
  case "$AGENT_CLI" in
    claude)
      RUN_SID="$(json_field "$f" session_id)"
      RUN_COST="$(json_field "$f" total_cost_usd)"
      RUN_TURNS="$(json_field "$f" num_turns)"
      RUN_ERR="$(json_field "$f" is_error)"
      RUN_RESULT_TAIL="$(json_field "$f" result | sed -E 's/\\n/ /g; s/\\"/"/g' | tail -c 400)" ;;
    codex)   # JSONL: thread.started {thread_id}, item.completed {item:{type:agent_message,text}}, turn.completed {usage}
      RUN_SID="$(grep -o '"thread_id":"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/.*:"//; s/"$//' || true)"
      RUN_RESULT_TAIL="$(grep '"agent_message"' "$f" 2>/dev/null | tail -1 | sed -E 's/.*"text":"//; s/"\}.*$//; s/\\n/ /g; s/\\"/"/g' | tail -c 400 || true)"
      RUN_TURNS="$(grep -c '"turn.completed"' "$f" 2>/dev/null || true)"
      grep -q '"turn.failed"\|"type":"error"' "$f" 2>/dev/null && RUN_ERR="true" ;;
    copilot) # plain text; the session id, when printed, is a UUID near the word "session"
      RUN_SID="$(grep -ioE 'session[^0-9a-f]{0,20}[0-9a-f-]{36}' "$f" 2>/dev/null | grep -oE '[0-9a-f-]{36}' | head -1 || true)"
      RUN_RESULT_TAIL="$(tr -d '\r' < "$f" | grep -v '^[[:space:]]*$' | tail -c 400 | tr '\n' ' ')" ;;
  esac
  [ -s "$f" ] || RUN_ERR="true"
  [ -n "$RUN_SID" ] || RUN_SID="(none)"
  [ "$AGENT_CLI" = claude ] && [ "$RUN_SID" = "(none)" ] && RUN_ERR="true"
  return 0
}

# ---------------------------------------------------------------------------
# Board
# ---------------------------------------------------------------------------

cmd_status() {
  printf '%-52s %-10s %-30s %-8s %s\n' "PROMPT" "STATUS" "BRANCH" "WORKTREE" "LAST RUN"
  local f found=0
  for f in "$PROMPTS_DIR"/PROMPT-*.md; do
    [ -f "$f" ] || continue
    found=1
    local repo="" branch="" wt="—"
    branch="$(header_field "$f" "Branch" | awk '{print $1}')"
    repo="$(header_field "$f" "Target repo")"; repo="${repo/#\~/$HOME}"
    if [ -n "$repo" ] && [ -n "$branch" ]; then
      local p; p="$(worktree_path "$repo" "$branch")"
      [ -d "$p" ] && wt="present" || wt="absent"
    fi
    printf '%-52s %-10s %-30s %-8s %s\n' "$(basename "$f")" "$(prompt_status "$f")" "$branch" "$wt" "$(last_run "$f")"
  done
  [ "$found" = "1" ] || echo "(no active prompts in Prompts/)"
}

# ---------------------------------------------------------------------------
# Run bookkeeping — every headless session is detached from the caller and tracked
# through .dispatch/active/<prompt>.active so a kill never goes unnoticed.
# ---------------------------------------------------------------------------

active_file() { printf '%s/%s.active\n' "$ACTIVE_DIR" "$(basename "$1" .md)"; }
active_field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }
alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

write_active() {  # write_active <prompt-file> <pid> <run_id> <kind>
  mkdir -p "$ACTIVE_DIR"
  printf 'pid=%s\nrun_id=%s\nkind=%s\nstarted=%s\nstarted_epoch=%s\n' "$2" "$3" "$4" "$(now)" "$(date +%s)" > "$(active_file "$1")"
}

last_result() {  # last Result row of the prompt's run report, or empty
  grep -E '^\| Result \|' "$1" 2>/dev/null | tail -1 | sed -E 's/^\| Result \| //; s/ \|$//' || true
}

last_run() {  # last_run <prompt-file> — one-line state for the board
  local af; af="$(active_file "$1")"
  if [ -f "$af" ]; then
    local pid; pid="$(active_field "$af" pid)"
    if alive "$pid"; then
      local since=$(( $(date +%s) - $(active_field "$af" started_epoch) ))
      printf 'RUNNING %dm%02ds (%s, pid %s)\n' $((since/60)) $((since%60)) "$(active_field "$af" kind)" "$pid"; return
    fi
    echo "KILLED — no result (run 'scripts/dispatch.sh wait' to record it)"; return
  fi
  local r; r="$(last_result "$1")"
  [ -n "$r" ] && printf '%s\n' "$r" | cut -c1-60 || echo "—"
}

# Explain a failed run in one line from what the process left behind.
diagnose() {  # diagnose <rc> <out_json> <out_txt>
  local rc="$1" json="$2" txt="$3" note=""
  grep -q "not been trusted" "$txt" 2>/dev/null && note=" (the settings.json warning in the log is harmless: the repo's own allow-list is ignored, the dispatcher passes its own)"
  if [ ! -s "$json" ]; then
    local other; other="$(grep -v "not been trusted" "$txt" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -1)"
    if [ -n "$other" ]; then echo "$AGENT_CLI exited $rc without a result: $other$note"
    else echo "$AGENT_CLI was killed before producing a result (exit $rc) — the process that launched it ended, or it was stopped by hand$note"; fi
    return
  fi
  local sub; sub="$(json_field "$json" subtype)"
  case "$sub" in
    *max_turns*) echo "hit the turn cap (DISPATCH_MAX_TURNS=${MAX_TURNS:-unlimited}) before finishing — resume it$note" ;;
    *) echo "$AGENT_CLI reported an error (exit $rc${sub:+, subtype $sub}): $(grep -v '^[[:space:]]*$' "$txt" 2>/dev/null | tail -1 | head -c 200)$note" ;;
  esac
}

# A worker that died without reporting: record it so the board never shows a phantom.
record_abort() {  # record_abort <prompt-file> <run_id> <kind> <why>
  local file="$1" run_id="$2" kind="$3" why="$4"
  grep -q "$run_id" "$file" 2>/dev/null && return 0     # the worker already wrote its own entry
  local repo branch wt stashed="no"
  repo="$(repo_path "$file")"; branch="$(branch_name "$file")"; wt="$(worktree_path "$repo" "$branch")"
  if [ -d "$wt" ] && [ -n "$(git -C "$wt" status --porcelain)" ]; then
    git -C "$wt" stash push -u -q -m "dispatch: leftovers of aborted $run_id" && stashed="yes (git stash in the worktree)"
  fi
  append_report "$file" "$( [ "$kind" = resume ] && echo Resume || echo Run )" \
"| Result | ABORTED — $why |
| Diagnosis | the session never returned; check the CLI's own session store (claude: ~/.claude/projects/, codex: ~/.codex/sessions/) |
| Leftover changes stashed | $stashed |
| Log | \`.dispatch/runs/$run_id.json\` |"
  log "✖ $(basename "$file" .md) ABORTED — $why"
}

# Sweep .dispatch/active: report every worker whose process is gone but that never reported.
reap_dead() {
  local af
  for af in "$ACTIVE_DIR"/*.active; do
    [ -f "$af" ] || continue
    local pid; pid="$(active_field "$af" pid)"
    alive "$pid" && continue
    local name; name="$(basename "$af" .active)"
    local file="$PROMPTS_DIR/$name.md"
    [ -f "$file" ] && record_abort "$file" "$(active_field "$af" run_id)" "$(active_field "$af" kind)" "process killed before it could report"
    rm -f "$af"
  done
}

any_running() {
  local af
  for af in "$ACTIVE_DIR"/*.active; do
    [ -f "$af" ] || continue
    alive "$(active_field "$af" pid)" && return 0
  done
  return 1
}

# launch_detached <log-file> -- <cmd> [args...] — own process group, reparented to init, so the
# caller (an agent's Bash tool, a closed terminal) can go away without taking the run with it.
launch_detached() {
  local logf="$1"; shift; [ "${1:-}" = "--" ] && shift
  local pidf; pidf="$(mktemp)"
  ( set -m; nohup "$@" </dev/null >>"$logf" 2>&1 & echo $! > "$pidf" )
  cat "$pidf"; rm -f "$pidf"
}

# ---------------------------------------------------------------------------
# Workers (internal entry points, always detached)
# ---------------------------------------------------------------------------

# __worker <kind> <prompt-file> <run_id> [message-file] — one headless session, one report entry.
cmd__worker() {
  local kind="$1" file="$2" run_id="$3" msg_file="${4:-}"
  local name model repo branch wt out_json out_txt
  name="$(basename "$file" .md)"; model="$(model_alias "$file")"
  repo="$(repo_path "$file")"; branch="$(branch_name "$file")"; wt="$(worktree_path "$repo" "$branch")"
  mkdir -p "$RUNS_DIR"
  out_json="$RUNS_DIR/$run_id.json"; out_txt="$RUNS_DIR/$run_id.stderr.log"
  write_active "$file" "$$" "$run_id" "$kind"
  # A polite kill still leaves a record; SIGKILL is caught later by reap_dead.
  trap 'record_abort "$file" "$run_id" "$kind" "worker received a termination signal"; rm -f "$(active_file "$file")"; exit 143' TERM INT HUP

  local preamble; preamble="$(system_preamble "$name" "$repo" "$branch" "$wt")"
  local rc=0 base_sha; base_sha="$(git -C "$repo" rev-parse --short "$BASE_BRANCH")"
  if [ "$kind" = "resume" ]; then
    local sid; sid="$(grep -E '^\| Session ID \|' "$file" | tail -1 | sed -E 's/.*`([^`]+)`.*/\1/' || true)"
    log "↻ resuming $name (session $sid)"
    run_headless "$wt" "$model" "$out_json" "$out_txt" --resume "$sid" -- "$msg_file" "$preamble" || rc=$?
  else
    log "▶ $name → $wt ($AGENT_CLI, model: $model)"
    run_headless "$wt" "$model" "$out_json" "$out_txt" -- "$file" "$preamble" || rc=$?
  fi
  trap - TERM INT HUP

  # Safety net: the agent is told to commit; if it left changes behind, commit them so nothing is lost.
  if [ -n "$(git -C "$wt" status --porcelain)" ]; then
    git -C "$wt" add -A && git -C "$wt" commit --quiet -m "chore: uncommitted work from dispatch $kind of $name" || true
    log "Committed leftover changes in $wt"
  fi

  summarize_run "$out_json"
  local commits; commits="$(git -C "$wt" log --oneline "$BASE_BRANCH..HEAD" | sed 's/|/\\|/g; s/^/`/; s/$/`/' | paste -sd ' ' - )"
  [ -n "$commits" ] || commits="(none)"
  local result="ok" diag=""
  if [ "$rc" != "0" ] || [ "$RUN_ERR" = "true" ]; then
    result="ERROR (exit $rc)"; diag="$(diagnose "$rc" "$out_json" "$out_txt" | sed 's/|/\\|/g')"
  fi
  local summary; summary="$(printf '%s' "$RUN_RESULT_TAIL" | sed 's/|/\\|/g')"

  if [ "$kind" = "resume" ]; then
    append_report "$file" "Resume" \
"| Message | $(head -c 200 "$msg_file" | tr '\n' ' ' | sed 's/|/\\|/g') |
| Session ID | \`$RUN_SID\` |
| Turns / cost | ${RUN_TURNS:-?} / \$${RUN_COST:-?} |
| Result | $result |$( [ -n "$diag" ] && printf '\n| Diagnosis | %s |' "$diag" )
| Commits (all on branch) | $commits |
| Log | \`${out_json#$HUB_DIR/}\` |
| Agent summary | $summary |"
  else
    append_report "$file" "Run" \
"| Worktree | \`$wt\` |
| Branch | \`$branch\` (base \`$BASE_BRANCH@$base_sha\`) |
| Agent / model | $AGENT_CLI / $model |
| Session ID | \`$RUN_SID\` |
| Turns / cost | ${RUN_TURNS:-?} / \$${RUN_COST:-?} |
| Result | $result |$( [ -n "$diag" ] && printf '\n| Diagnosis | %s |' "$diag" )
| Commits | $commits |
| Log | \`${out_json#$HUB_DIR/}\` |
| Agent summary | $summary |"
  fi

  rm -f "$(active_file "$file")"
  if [ "$result" = "ok" ]; then
    [ "$kind" = "run" ] && set_status "$file" "Applied"
    log "✔ $name $( [ "$kind" = run ] && echo Applied || echo resumed ) — session $RUN_SID, ${RUN_TURNS:-?} turns, \$${RUN_COST:-?}"
    return 0
  fi
  log "✖ $name failed — $diag"
  return 1
}

# __batch <kind> <message-file-or-'-'> <prompt-file>... — runs the workers in parallel, waits for
# every one, then puts the applied worktrees on the air. Detached from whoever called run/resume.
cmd__batch() {
  local kind="$1" msg_file="$2"; shift 2
  local files=("$@") pids=() ids=() f run_id
  set -m   # each worker in its own process group: a signal to the batch never fans out to the sessions
  for f in "${files[@]}"; do
    run_id="$(basename "$f" .md)$( [ "$kind" = resume ] && echo -resume )-$(stamp)"
    bash "$SELF" __worker "$kind" "$f" "$run_id" "$msg_file" &
    pids+=($!); ids+=("$run_id")
    sleep 1   # distinct run_id stamps
  done
  local i failed=0 ok_pairs=() rc
  for i in "${!pids[@]}"; do
    rc=0; wait "${pids[$i]}" || rc=$?
    f="${files[$i]}"
    if [ "$rc" = "0" ]; then
      ok_pairs+=("$(repo_path "$f")|$(branch_name "$f")")
    else
      failed=$((failed+1))
      record_abort "$f" "${ids[$i]}" "$kind" "worker exited $rc without reporting"   # no-op if it did report
      rm -f "$(active_file "$f")"
    fi
  done
  [ "$kind" = "resume" ] && rm -f "$msg_file"
  if [ "${#ok_pairs[@]}" -gt 0 ]; then
    [ "$kind" = "resume" ] && [ "$SERVE" = "stack" ] && SERVE=affected   # a resume only bounces its own service
    serve_pairs "${ok_pairs[@]}"
  fi
  log "BATCH DONE — ${#files[@]} prompt(s), $failed failed."
  [ "$failed" = "0" ]
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_run() {
  local files=() all=0 a do_wait=0
  for a in "$@"; do
    case "$a" in
      --all) all=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --no-serve) SERVE=none ;;
      --wait) do_wait=1 ;;
      *) files+=("$(resolve_prompt "$a")") ;;
    esac
  done
  if [ "$all" = "1" ]; then
    local f
    for f in "$PROMPTS_DIR"/PROMPT-*.md; do
      [ -f "$f" ] && [ "$(prompt_status "$f")" = "Generated" ] && files+=("$f")
    done
  fi
  [ "${#files[@]}" -gt 0 ] || die "Nothing to dispatch (no Generated prompts given or found)."
  reap_dead

  # Phase 1 (sequential): validate + set up worktrees. Git operations on one repo must not overlap.
  local f seen_repos=""
  for f in "${files[@]}"; do
    local st; st="$(prompt_status "$f")"
    [ "$st" = "Generated" ] || die "$(basename "$f") has Status '$st' — only Generated prompts can be dispatched (use 'resume' for Applied ones)."
    [ -f "$(active_file "$f")" ] && die "$(basename "$f") already has a running session ($(last_run "$f")) — wait for it."
    local repo branch wt model
    repo="$(repo_path "$f")"; branch="$(branch_name "$f")"; wt="$(worktree_path "$repo" "$branch")"; model="$(model_alias "$f")"
    if [ "$DRY_RUN" = "1" ]; then
      local perms
      case "$AGENT_CLI" in claude) perms="$PERMISSION_MODE + allowedTools" ;; codex) perms="--full-auto" ;; copilot) perms="--allow-all-tools" ;; esac
      printf 'DRY RUN  %s\n  repo:     %s\n  branch:   %s (from %s)\n  worktree: %s\n  agent:    %s\n  model:    %s\n  perms:    %s\n' \
        "$(basename "$f")" "$repo" "$branch" "$BASE_BRANCH" "$wt" "$AGENT_CLI" "$model" "$perms"
      continue
    fi
    case "$seen_repos" in *"|$repo|"*) ;; *) ensure_base_branch "$repo"; seen_repos="$seen_repos|$repo|" ;; esac
    setup_worktree "$repo" "$branch" "$wt"
  done
  [ "$DRY_RUN" = "1" ] && { log "Dry run — nothing was changed. $AGENT_CLI: $(find_agent)"; return 0; }
  find_agent >/dev/null

  # Phase 2: hand the batch to a detached supervisor; the sessions no longer depend on this process.
  mkdir -p "$RUNS_DIR"
  local batch_log="$RUNS_DIR/batch-$(stamp).log"
  local pid; pid="$(launch_detached "$batch_log" -- env DISPATCH_SERVE="$SERVE" "$SELF" __batch run - "${files[@]}")"
  log "Dispatched ${#files[@]} prompt(s) in the background (supervisor pid $pid, log ${batch_log#$HUB_DIR/})."
  log "Follow with 'scripts/dispatch.sh status'; block until finished with 'scripts/dispatch.sh wait'."
  [ "$do_wait" = "1" ] && { sleep 3; cmd_wait; }
  return 0
}

cmd_resume() {
  local do_wait=0 args=() a
  for a in "$@"; do
    case "$a" in --no-serve) SERVE=none ;; --wait) do_wait=1 ;; *) args+=("$a") ;; esac
  done
  set -- "${args[@]+"${args[@]}"}"
  local file; file="$(resolve_prompt "${1:-}")"; shift || true
  local message="${*:-}"
  [ -n "$message" ] || die "Usage: dispatch.sh resume <prompt> \"<message>\" [--wait] [--no-serve]"
  reap_dead
  local sid; sid="$(grep -E '^\| Session ID \|' "$file" | tail -1 | sed -E 's/.*`([^`]+)`.*/\1/' || true)"
  [ -n "$sid" ] && [ "$sid" != "(none)" ] || die "No session ID recorded in $(basename "$file") — dispatch it with 'run' first (for a CLI that exposes no session id, open an interactive session in the worktree instead)."
  [ -f "$(active_file "$file")" ] && die "$(basename "$file") already has a running session ($(last_run "$file")) — wait for it."
  local repo branch wt
  repo="$(repo_path "$file")"; branch="$(branch_name "$file")"; wt="$(worktree_path "$repo" "$branch")"
  [ -d "$wt" ] || die "Worktree missing: $wt (was it merged already?)"
  [ "$TRUST" = "1" ] && [ "$AGENT_CLI" = claude ] && ensure_trust "$wt" "$repo"
  find_agent >/dev/null
  mkdir -p "$RUNS_DIR"
  local msg_file; msg_file="$RUNS_DIR/$(basename "$file" .md)-resume-$(stamp).message"; printf '%s\n' "$message" > "$msg_file"
  local batch_log="$RUNS_DIR/batch-$(stamp).log"
  local pid; pid="$(launch_detached "$batch_log" -- env DISPATCH_SERVE="$SERVE" "$SELF" __batch resume "$msg_file" "$file")"
  log "Resume of $(basename "$file" .md) launched in the background (supervisor pid $pid). 'scripts/dispatch.sh wait' blocks until it finishes."
  [ "$do_wait" = "1" ] && { sleep 3; cmd_wait; }
  return 0
}

# wait [--timeout <seconds>] — block until no session is running, record any that were killed,
# print the board. Exit 0: every last run ok; 1: a run failed or was killed; 2: still running (timeout).
cmd_wait() {
  local timeout=0 prev=""
  while [ "$#" -gt 0 ]; do
    case "$1" in --timeout) timeout="${2:-0}"; shift 2 ;; --timeout=*) timeout="${1#*=}"; shift ;; *) die "Usage: dispatch.sh wait [--timeout <seconds>]" ;; esac
  done
  local start; start="$(date +%s)"
  while any_running; do
    if [ "$timeout" != "0" ] && [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
      log "Still running after ${timeout}s:"; cmd_status >&2; return 2
    fi
    local cur; cur="$(ls "$ACTIVE_DIR" 2>/dev/null | tr '\n' ' ')"
    [ "$cur" != "$prev" ] && { log "running: $cur"; prev="$cur"; }
    sleep 10
  done
  reap_dead
  cmd_status
  local f bad=0 r
  for f in "$PROMPTS_DIR"/PROMPT-*.md; do
    [ -f "$f" ] || continue
    r="$(last_result "$f")"
    case "$r" in ""|ok) ;; *) bad=$((bad+1)); log "FAILED: $(basename "$f") — $r" ;; esac
  done
  [ "$bad" = "0" ] && { log "All runs finished ok."; return 0; }
  log "$bad prompt(s) need attention — read the Diagnosis row of their last run report entry."
  return 1
}

cmd_verify() {
  local file; file="$(resolve_prompt "${1:-}")"
  local st; st="$(prompt_status "$file")"
  [ "$st" = "Applied" ] || die "$(basename "$file") is '$st' — only Applied prompts can be marked Verified."
  set_status "$file" "Verified"
  append_report "$file" "Verified" "| Verified by | $(git -C "$HUB_DIR" config user.name 2>/dev/null || whoami) |"
  log "✔ $(basename "$file") → Verified"
}

# serve <prompt>|--all — (re)start the stack with each Applied/Verified prompt's service on its worktree.
cmd_serve() {
  local files=() all=0 a
  for a in "$@"; do
    case "$a" in --all) all=1 ;; *) files+=("$(resolve_prompt "$a")") ;; esac
  done
  if [ "$all" = "1" ]; then
    local f
    for f in "$PROMPTS_DIR"/PROMPT-*.md; do
      [ -f "$f" ] || continue
      case "$(prompt_status "$f")" in Applied|Verified) files+=("$f") ;; esac
    done
  fi
  [ "${#files[@]}" -gt 0 ] || die "Nothing to serve (no Applied/Verified prompts given or found)."
  [ "$SERVE" = "none" ] && SERVE=stack
  local pairs=() f wt
  for f in "${files[@]}"; do
    wt="$(worktree_path "$(repo_path "$f")" "$(branch_name "$f")")"
    [ -d "$wt" ] || { log "WARNING: $(basename "$f" .md) has no worktree ($wt) — skipped"; continue; }
    pairs+=("$(repo_path "$f")|$(branch_name "$f")")
  done
  [ "${#pairs[@]}" -gt 0 ] || die "No worktree present for the given prompt(s)."
  serve_pairs "${pairs[@]}"
}

merge_one() {  # merge_one <prompt-file>
  local file="$1" name repo branch wt
  name="$(basename "$file" .md)"
  [ "$(prompt_status "$file")" = "Verified" ] || die "$name is not Verified — refusing to merge."
  repo="$(repo_path "$file")"; branch="$(branch_name "$file")"; wt="$(worktree_path "$repo" "$branch")"
  git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" || die "Branch $branch not found in $repo"

  [ -z "$(git -C "$repo" status --porcelain)" ] || die "$(basename "$repo") main checkout is dirty — commit or stash before merging."
  [ -d "$wt" ] && { [ -z "$(git -C "$wt" status --porcelain)" ] || die "Worktree $wt has uncommitted changes."; }

  local cur; cur="$(git -C "$repo" branch --show-current)"
  [ "$cur" = "$BASE_BRANCH" ] || { log "Checking out $BASE_BRANCH in $(basename "$repo") (was $cur)"; git -C "$repo" checkout --quiet "$BASE_BRANCH"; }

  log "Merging $branch → $BASE_BRANCH in $(basename "$repo")"
  if ! git -C "$repo" merge --no-ff --no-edit -m "merge: $branch ($name)" "$branch"; then
    git -C "$repo" merge --abort || true
    die "Merge conflict for $branch in $repo. Resolve by hand (or 'resume' the prompt after rebasing), then re-run merge."
  fi
  local merge_sha; merge_sha="$(git -C "$repo" rev-parse --short HEAD)"
  local impl_shas; impl_shas="$(git -C "$repo" log --oneline --no-merges "$BASE_BRANCH^1..$branch" | awk '{print $1}' | paste -sd ',' -)"

  # If the service is running from this worktree, stop it before the directory disappears.
  local svc="" restart=0
  svc="$(service_for_repo "$repo")"
  if [ -n "$svc" ] && [ "$(service_cwd "$svc")" = "$wt" ]; then
    log "Stopping $svc (running from the worktree)"; "$STACK" stop "$svc" >&2 || true; restart=1
  fi
  remove_worktree "$repo" "$wt"
  git -C "$repo" branch -d "$branch"
  if [ "$restart" = "1" ] && [ "$SERVE" != "none" ]; then
    log "Starting $svc from the main checkout"; "$STACK" start "$svc" >&2 || log "WARNING: could not start $svc"
  fi

  local pushed="no"
  if [ "$PUSH" = "1" ]; then git -C "$repo" push origin "$BASE_BRANCH" && pushed="yes"; fi

  append_report "$file" "Merged" \
"| Into | \`$BASE_BRANCH\` @ \`$merge_sha\` (merge commit) |
| Implementing commits | \`$impl_shas\` |
| Branch deleted / worktree removed | yes / yes |
| Service | ${svc:-—}$( [ "$restart" = "1" ] && printf ' restarted from main checkout' ) |
| Pushed | $pushed |"
  log "✔ $name merged into $BASE_BRANCH @ $merge_sha — implementing commits: $impl_shas"
}

cmd_merge() {
  local files=() all=0 a
  for a in "$@"; do
    case "$a" in
      --all) all=1 ;;
      --push) PUSH=1 ;;
      *) files+=("$(resolve_prompt "$a")") ;;
    esac
  done
  if [ "$all" = "1" ]; then
    local f
    for f in "$PROMPTS_DIR"/PROMPT-*.md; do
      [ -f "$f" ] && [ "$(prompt_status "$f")" = "Verified" ] && files+=("$f")
    done
  fi
  [ "${#files[@]}" -gt 0 ] || die "Nothing to merge (no Verified prompts given or found)."
  local f repos=""
  for f in "${files[@]}"; do
    merge_one "$f"   # sequential: merges into the same base must not overlap
    repos="$repos $(repo_path "$f")"
  done
  # shellcheck disable=SC2086
  clean_repos $repos   # leftovers (build output, .DS_Store, unregistered dirs) go with the worktree root
}

# clean_repos <repo>... — delete every unregistered entry under <repo>-worktrees/ and the root itself once
# it holds no registered worktree. Registered worktrees are kept unless FORCE=1.
clean_repos() {
  local repo root entry kept=0
  for repo in "$@"; do
    root="$(dirname "$(worktree_path "$repo" x)")"
    git -C "$repo" worktree prune 2>/dev/null || true
    [ -d "$root" ] || continue
    for entry in "$root"/* "$root"/.[!.]*; do
      [ -e "$entry" ] || continue
      if git -C "$repo" worktree list --porcelain | grep -qx "worktree $entry"; then
        if [ "$FORCE" = "1" ]; then
          local svc; svc="$(service_for_repo "$repo")"
          [ -n "$svc" ] && [ "$(service_cwd "$svc")" = "$entry" ] && { "$STACK" stop "$svc" >&2 || true; }
          remove_worktree "$repo" "$entry"; log "Removed registered worktree $entry (--force)"
        else
          log "Keeping registered worktree $entry (pass --force to remove it)"; kept=$((kept+1))
        fi
      else
        rm -rf "$entry"; log "Removed leftover $entry"
      fi
    done
    prune_worktree_root "$repo" "$root"
  done
  return 0
}

cmd_clean() {  # clean [--force] — every code-service repo known to stack.sh plus every Target repo in Prompts/
  local a repos="" f r
  for a in "$@"; do case "$a" in --force) FORCE=1 ;; *) die "Usage: dispatch.sh clean [--force]" ;; esac; done
  if [ -x "$STACK" ] && [ -f "$CONF" ]; then
    while IFS='|' read -r _ r kind; do [ "$kind" = code ] && [ -d "$r/.git" ] && repos="$repos $r"; done < <("$STACK" repos)
  fi
  for f in "$PROMPTS_DIR"/PROMPT-*.md; do
    [ -f "$f" ] || continue
    r="$(header_field "$f" "Target repo")"; r="${r/#\~/$HOME}"
    [ -d "$r/.git" ] && case " $repos " in *" $r "*) ;; *) repos="$repos $r" ;; esac
  done
  [ -n "$repos" ] || die "No repos to clean."
  # shellcheck disable=SC2086
  clean_repos $repos
  local left="" d
  for r in $repos; do d="$(dirname "$(worktree_path "$r" x)")"; [ -d "$d" ] && left="$left $d"; done
  if [ -n "$left" ]; then log "Worktree roots still present (registered worktrees inside):$left"; else log "All worktree roots are gone."; fi
}

# ---------------------------------------------------------------------------

usage() { sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

cmd="${1:-}"; shift || true
case "$cmd" in
  status) cmd_status ;;
  run)    cmd_run "$@" ;;
  resume) cmd_resume "$@" ;;
  wait)   cmd_wait "$@" ;;
  __worker) cmd__worker "$@" ;;
  __batch)  cmd__batch "$@" ;;
  verify) cmd_verify "$@" ;;
  serve)  cmd_serve "$@" ;;
  merge)  cmd_merge "$@" ;;
  clean)  cmd_clean "$@" ;;
  *) usage ;;
esac
