#!/bin/bash
# ---------------------------------------------------------------------------
# stack.sh — run every service, frontend and asset server listed in spechub.conf
#
#   ./scripts/stack.sh start            # start everything, in group order (static → backend → frontend)
#   ./scripts/stack.sh start api web    # start only some services
#   ./scripts/stack.sh start backend    # groups: static | backend | frontend | all
#   ./scripts/stack.sh stop [names...]
#   ./scripts/stack.sh restart [names...]
#   ./scripts/stack.sh status
#   ./scripts/stack.sh logs [names...]  # tail -f
#   ./scripts/stack.sh install [names...]   # run each service's install command
#   ./scripts/stack.sh list
#   ./scripts/stack.sh service-for <repo-dir>   # service name for a repo path (used by dispatch.sh)
#   ./scripts/stack.sh is-running <name>        # prints the pid, exit 0, when the service is running
#   ./scripts/stack.sh repos                    # name|main-checkout|kind for every service
#
#   -w, --worktree <branch>   run code services from their git worktree for
#                             <branch> instead of the main checkout, e.g.
#                               ./scripts/stack.sh start -w feature/site-texts
#                             A service with no worktree for that branch falls
#                             back to its main checkout. Static servers never move.
#                             Same as STACK_WORKTREE=feature/site-texts.
#
# The service table lives in spechub.conf (name|dir|start|port|label|group|install).
# Processes run detached in their own process group; PIDs live in .run/ and
# output in .logs/. Nothing is installed or written outside those two dirs.
# ---------------------------------------------------------------------------
set -u
set -m   # each background job gets its own process group -> clean tree kill

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"
CONF="$WORKSPACE/spechub.conf"
[ -f "$CONF" ] || { echo "spechub.conf not found in $WORKSPACE — run scripts/bootstrap.sh init <repos-root> first (or copy spechub.conf.example)." >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"
ROOT="${REPOS_ROOT:-$WORKSPACE/..}"
RUN_DIR="$WORKSPACE/.run"
LOG_DIR="$WORKSPACE/.logs"
# Set by --worktree/-w or STACK_WORKTREE. Empty = use the main checkouts.
WORKTREE="${STACK_WORKTREE:-}"
mkdir -p "$RUN_DIR" "$LOG_DIR"

# Tool managers often live off PATH in a bare shell.
for p in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/.cargo/bin" "$HOME/go/bin"; do
  case ":$PATH:" in *":$p:"*) ;; *) [ -d "$p" ] && PATH="$p:$PATH" ;; esac
done
export PATH
export BROWSER=none          # keep dev servers from opening browser tabs
export FORCE_COLOR=1

# --- registry (from spechub.conf) -----------------------------------------------
SERVICE_TABLE="$(printf '%s\n' "$SERVICES" | grep -v '^[[:space:]]*#' | grep '|')"
group_names() { printf '%s\n' "$SERVICE_TABLE" | awk -F'|' -v g="$1" '$6==g {print $1}' | tr '\n' ' '; }
STATIC_SERVICES="$(group_names static)"
BACKEND_SERVICES="$(group_names backend)"
FRONTEND_SERVICES="$(group_names frontend)"
START_ORDER="$STATIC_SERVICES $BACKEND_SERVICES $FRONTEND_SERVICES"   # also display order
ALL_SERVICES="$START_ORDER"
[ -n "$(echo "$ALL_SERVICES" | tr -d ' ')" ] || { echo "spechub.conf lists no services (group must be static, backend or frontend)." >&2; exit 1; }

C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'
C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BOLD=$'\033[1m'

meta()  { printf '%s\n' "$SERVICE_TABLE" | grep "^$1|"; }
field() { meta "$1" | cut -d'|' -f"$2"; }
# Main checkout directory, ignoring any --worktree.
svc_base_dir() {
  local d; d="$(field "$1" 2)"; d="${d/#\~/$HOME}"
  case "$d" in /*) echo "$d" ;; *) echo "$ROOT/$d" ;; esac
}
# Where a branch's worktree lives — matches scripts/dispatch.sh:
#   <repo-parent>/<repo-name>-worktrees/<branch with / replaced by ->
svc_worktree_dir() {
  local base; base="$(svc_base_dir "$1")"
  printf '%s/%s-worktrees/%s\n' "$(dirname "$base")" "$(basename "$base")" \
    "$(printf '%s' "$WORKTREE" | tr '/' '-')"
}
# The directory a service actually runs from. Falls back to the main checkout
# when no worktree exists for that branch, so a partial feature still starts.
# Static servers point at data dirs, not repo roots, and never move.
svc_dir() {
  local wt
  if [ -n "$WORKTREE" ] && [ "$(svc_kind "$1")" = code ]; then
    wt="$(svc_worktree_dir "$1")"
    if [ -d "$wt" ]; then echo "$wt"; return; fi
  fi
  svc_base_dir "$1"
}
on_worktree() { [ "$(svc_dir "$1")" != "$(svc_base_dir "$1")" ]; }
svc_cmd()     { field "$1" 3; }
svc_port()    { field "$1" 4; }
svc_label()   { field "$1" 5; }
svc_group()   { field "$1" 6; }
svc_install() { field "$1" 7; }
svc_kind()    { [ "$(svc_group "$1")" = static ] && echo static || echo code; }
pid_file()  { echo "$RUN_DIR/$1.pid"; }
log_file()  { echo "$LOG_DIR/$1.log"; }
in_group()  { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

die() { echo "${C_RED}$*${C_RESET}" >&2; exit 1; }

# expand groups / validate names; no args -> all
resolve() {
  if [ "$#" -eq 0 ]; then echo "$ALL_SERVICES"; return; fi
  local out="" a
  for a in "$@"; do
    case "$a" in
      all)                     out="$out $ALL_SERVICES" ;;
      backend|back|services)   out="$out $BACKEND_SERVICES" ;;
      frontend|front|fronts)   out="$out $FRONTEND_SERVICES" ;;
      static|assets|files)     out="$out $STATIC_SERVICES" ;;
      *)
        if [ -n "$(meta "$a")" ]; then out="$out $a"
        else die "Unknown service '$a'. Try: $ALL_SERVICES (or static|backend|frontend|all)"; fi ;;
    esac
  done
  echo "$out" | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' '
}

running_pid() {           # echoes pid if the recorded process is alive
  local f; f="$(pid_file "$1")"
  [ -f "$f" ] || return 1
  local pid; pid="$(cat "$f" 2>/dev/null)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || { rm -f "$f"; return 1; }
  echo "$pid"
}

port_pid() { lsof -ti "tcp:$1" -sTCP:LISTEN 2>/dev/null | head -1; }

# Announce which services actually moved, and which silently fell back. Silence
# here would be the trap: you would test the main checkout believing otherwise.
worktree_banner() {
  [ -n "$WORKTREE" ] || return 0
  local n on="" off=""
  for n in $1; do
    [ "$(svc_kind "$n")" = code ] || continue
    if on_worktree "$n"; then on="$on $n"; else off="$off $n"; fi
  done
  if [ -n "$on" ]; then
    echo "  ${C_YELLOW}worktree${C_RESET} $WORKTREE ${C_DIM}→${C_RESET}${on}"
  else
    echo "  ${C_RED}✗${C_RESET} no worktree found for '$WORKTREE' on any selected service"
  fi
  [ -n "$off" ] && echo "  ${C_DIM}main checkout (no such worktree) →${off}${C_RESET}"
  return 0
}

# Dependency sanity check before starting: only what the install command implies.
deps_missing() {  # deps_missing <name> <dir> — prints a hint when deps are clearly absent
  local inst; inst="$(svc_install "$1")"
  case "$inst" in
    npm*|yarn*|pnpm*|npx*) [ -d "$2/node_modules" ] || echo "no node_modules" ;;
    pip*|poetry*|uv*)      [ -d "$2/.venv" ] || [ -d "$2/venv" ] || [ -n "${VIRTUAL_ENV:-}" ] || echo "no .venv (or active virtualenv)" ;;
    bundle*)               [ -d "$2/vendor" ] || command -v bundle >/dev/null 2>&1 || echo "bundler not installed" ;;
    composer*)             [ -d "$2/vendor" ] || echo "no vendor/" ;;
  esac
  return 0
}

start_one() {
  local name="$1" dir cmd port pid owner hint
  dir="$(svc_dir "$name")"; cmd="$(svc_cmd "$name")"; port="$(svc_port "$name")"

  if pid="$(running_pid "$name")"; then
    echo "  ${C_YELLOW}•${C_RESET} $name already running (pid $pid)"; return 0
  fi
  if [ ! -d "$dir" ]; then
    echo "  ${C_RED}✗${C_RESET} $name — path not found: $dir"; return 1
  fi
  hint="$(deps_missing "$name" "$dir")"
  if [ -n "$hint" ]; then
    echo "  ${C_RED}✗${C_RESET} $name — $hint; run: $0 install $name"; return 1
  fi
  owner="$(port_pid "$port")"
  if [ -n "$owner" ]; then
    echo "  ${C_RED}✗${C_RESET} $name — port $port already in use by pid $owner"; return 1
  fi

  : > "$(log_file "$name")"
  # shellcheck disable=SC2086  # $cmd is a trusted, space-separated command line
  ( cd "$dir" && set -f && exec $cmd ) >>"$(log_file "$name")" 2>&1 </dev/null &
  pid=$!
  echo "$pid" > "$(pid_file "$name")"
  local wt_note=""
  on_worktree "$name" && wt_note=" · ${C_YELLOW}worktree $WORKTREE${C_RESET}${C_DIM}"
  echo "  ${C_GREEN}▸${C_RESET} $name  ${C_DIM}pid $pid · port $port$wt_note · $(log_file "$name")${C_RESET}"
}

stop_one() {
  local name="$1" pid port owner
  port="$(svc_port "$name")"
  if pid="$(running_pid "$name")"; then
    kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    local i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 0.5; i=$((i+1)); done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
    fi
    rm -f "$(pid_file "$name")"
    echo "  ${C_GREEN}■${C_RESET} $name stopped"
  else
    owner="$(port_pid "$port")"
    if [ -n "$owner" ]; then
      echo "  ${C_YELLOW}•${C_RESET} $name not tracked, but port $port held by pid $owner — leaving it alone"
    else
      echo "  ${C_DIM}·${C_RESET} $name not running"
    fi
  fi
}

cmd_start() {
  local names phase n started_any=0
  names="$(resolve "$@")"
  echo "${C_BOLD}Starting${C_RESET}"
  worktree_banner "$names"
  for phase in "$STATIC_SERVICES" "$BACKEND_SERVICES" "$FRONTEND_SERVICES"; do
    local phase_has=0
    for n in $names; do in_group "$n" "$phase" && phase_has=1; done
    [ "$phase_has" -eq 1 ] || continue
    [ "$started_any" -eq 1 ] && sleep 2   # let the previous tier come up first
    for n in $names; do in_group "$n" "$phase" && start_one "$n"; done
    started_any=1
  done
  echo
  echo "${C_DIM}Compiling takes a few seconds. Follow with: $0 logs${C_RESET}"
}

cmd_stop()    { echo "${C_BOLD}Stopping${C_RESET}"; local n; for n in $(resolve "$@"); do stop_one "$n"; done; }
cmd_restart() { cmd_stop "$@"; echo; cmd_start "$@"; }

cmd_status() {
  worktree_banner "$ALL_SERVICES"
  printf "%-13s %-34s %-6s %-9s %-8s %s\n" SERVICE NAME PORT STATE PID PORT-STATE
  local n pid state port listen
  for n in $ALL_SERVICES; do
    port="$(svc_port "$n")"
    if pid="$(running_pid "$n")"; then state="${C_GREEN}running${C_RESET}"; else pid="-"; state="${C_DIM}stopped${C_RESET}"; fi
    if [ -n "$(port_pid "$port")" ]; then listen="${C_GREEN}listening${C_RESET}"; else listen="${C_DIM}closed${C_RESET}"; fi
    printf "%-13s %-34s %-6s %-20s %-8s %s\n" "$n" "$(svc_label "$n")" "$port" "$state" "$pid" "$listen"
  done
}

cmd_logs() {
  local names files n; names="$(resolve "$@")"; files=""
  for n in $names; do [ -f "$(log_file "$n")" ] && files="$files $(log_file "$n")"; done
  [ -n "$files" ] || die "No logs yet — start something first."
  # shellcheck disable=SC2086
  tail -n 40 -f $files
}

cmd_install() {
  local n dir inst
  for n in $(resolve "$@"); do
    inst="$(svc_install "$n")"
    [ -n "$inst" ] && [ "$inst" != "-" ] || continue
    dir="$(svc_dir "$n")"
    [ -d "$dir" ] || { echo "${C_RED}✗${C_RESET} $n — missing $dir"; continue; }
    echo "${C_BOLD}$inst → $n${C_RESET} ($dir)"
    # shellcheck disable=SC2086
    ( cd "$dir" && set -f && $inst ) || echo "${C_RED}✗${C_RESET} $n install failed"
  done
}

cmd_list() {
  local n
  for n in $ALL_SERVICES; do
    local mark=""; on_worktree "$n" && mark="${C_YELLOW}[wt]${C_RESET} "
    printf "%-13s %-34s http://localhost:%-5s %s\n" "$n" "$(svc_label "$n")" "$(svc_port "$n")" "$mark${C_DIM}$(svc_dir "$n")${C_RESET}"
  done
}

# --- plumbing used by scripts/dispatch.sh --------------------------------------
cmd_service_for() {   # service name whose main checkout is <dir>; exit 1 if none
  local want n
  want="$(cd "$1" 2>/dev/null && pwd -P)" || exit 1
  for n in $ALL_SERVICES; do
    [ "$(svc_kind "$n")" = code ] || continue
    [ "$(cd "$(svc_base_dir "$n")" 2>/dev/null && pwd -P)" = "$want" ] && { echo "$n"; return 0; }
  done
  return 1
}
cmd_is_running() { [ -n "$(meta "$1")" ] || die "Unknown service '$1'"; running_pid "$1"; }   # prints the pid
cmd_repos() { local n; for n in $ALL_SERVICES; do printf '%s|%s|%s\n' "$n" "$(svc_base_dir "$n")" "$(svc_kind "$n")"; done; }

usage() { sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; }

# Pull -w/--worktree out of the arguments wherever it appears, so it composes
# with every subcommand and with service names.
ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -w|--worktree)
      shift; [ "$#" -gt 0 ] || die "--worktree needs a branch name"
      WORKTREE="$1"; shift ;;
    --worktree=*) WORKTREE="${1#*=}"; shift ;;
    -w=*)         WORKTREE="${1#*=}"; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

case "${1:-help}" in
  start)   shift; cmd_start "$@" ;;
  stop)    shift; cmd_stop "$@" ;;
  restart) shift; cmd_restart "$@" ;;
  status|ps) cmd_status ;;
  logs|tail) shift; cmd_logs "$@" ;;
  install) shift; cmd_install "$@" ;;
  list|ls) cmd_list ;;
  service-for) shift; cmd_service_for "${1:?repo dir}" ;;
  is-running)  shift; cmd_is_running "${1:?service name}" ;;
  repos)       cmd_repos ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
