#!/usr/bin/env bash
# scripts/bootstrap.sh — Step 0: bring an existing (or brand-new) codebase into the spec hub.
#
#   scripts/bootstrap.sh init <repos-root> [--name "<project>"] [--no-install]
#   scripts/bootstrap.sh init <repo-dir> [<repo-dir>...] [--name "<project>"] [--no-install]
#       discover the git repos and, inside each, the services (the repo root when it is an app, or
#       the workspace members of a monorepo — package.json workspaces, pnpm-workspace.yaml, apps/*,
#       packages/*, services/*, Maven <module>s, Gradle includes, Go cmd/*); detect each service's
#       stack (language, framework, start/install commands, port); write spechub.conf; insert the
#       services table into AGENTS.md; install dependencies; write one fact sheet per service.
#   scripts/bootstrap.sh facts [<service>...]     (re)write bootstrap/facts/<service>.md for every service in spechub.conf
#   scripts/bootstrap.sh plan [--manifest]        print the spec plan: number, service, spec file, module count, split?
#                                                 --manifest prints the exact file list each writer must produce
#   scripts/bootstrap.sh services                 refresh the services table in AGENTS.md from spechub.conf
#   scripts/bootstrap.sh install [<service>...]   run each service's install command (same as scripts/stack.sh install)
#
# Fact sheets are MECHANICAL extractions (find/grep/sort only, fixed section order, C-locale sorting):
# the same commit yields the same sheet. The bootstrap-specs skill writes every spec from them, which
# is what makes spec generation repeatable. They live in bootstrap/facts/ and are committed so re-runs
# show up as diffs. Regenerate them; never edit them.
#
# Stack detection is a marker-file table (package.json, pom.xml, build.gradle, pyproject.toml,
# requirements.txt, go.mod, Cargo.toml, *.csproj, Gemfile, composer.json, index.html) plus
# framework fingerprints inside the manifest. Route, model and env-var extraction runs the patterns
# of every supported framework over every source file, so nothing depends on the detection being
# right — a wrong guess only affects the start/install commands, which you fix in spechub.conf.
#
# Compatible with the macOS system bash (3.2). Needs git, find, grep, sed, awk, sort.

set -euo pipefail

HUB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="$HUB_DIR/spechub.conf"
FACTS_DIR="$HUB_DIR/bootstrap/facts"
STACK="$HUB_DIR/scripts/stack.sh"
AGENTS_MD="$HUB_DIR/AGENTS.md"
SPLIT_THRESHOLD="${SPECHUB_SPLIT_THRESHOLD:-8}"   # more source modules than this → split spec (index + directory)
export LC_ALL=C

# Directories never scanned (build output, dependencies, VCS, IDE, caches).
PRUNE_DIRS="node_modules .git dist build out target .next .nuxt .svelte-kit coverage vendor __pycache__ .venv venv .gradle .idea .vscode .cache .turbo .pytest_cache .mypy_cache bin obj tmp log logs storage public/build .dispatch"
SRC_EXT="ts tsx js jsx mjs cjs vue svelte java kt py go rs cs rb php"

log() { printf '[bootstrap] %s\n' "$*" >&2; }
die() { printf '[bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
kebab() { lower "$1" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'; }

prune_args() { local d out=""; for d in $PRUNE_DIRS; do out="$out --exclude-dir=$d"; done; printf '%s' "$out"; }
include_args() { local e out=""; for e in $SRC_EXT; do out="$out --include=*.$e"; done; printf '%s' "$out"; }
find_prune() {  # find_prune <dir> — prints a find(1) expression prefix that skips PRUNE_DIRS
  local d first=1 expr="("
  for d in $PRUNE_DIRS; do
    [ "$first" = 1 ] && first=0 || expr="$expr -o"
    expr="$expr -name $d"
  done
  printf '%s ) -prune -o' "$expr"
}

has() { grep -qE "$1" "$2" 2>/dev/null; }

# ---------------------------------------------------------------------------
# Stack detection
# ---------------------------------------------------------------------------

# detect_port <dir> <default> — first port found in env files, scripts, entry points, app config, Dockerfile.
detect_port() {
  local dir="$1" def="$2" p=""
  p="$(cat "$dir"/.env "$dir"/.env.local "$dir"/.env.development "$dir"/.env.example 2>/dev/null | grep -m1 -oE '^(PORT|SERVER_PORT|APP_PORT)=[0-9]{2,5}' | grep -oE '[0-9]+$' | head -1 || true)"
  [ -z "$p" ] && [ -f "$dir/package.json" ] && p="$(scripts_block "$dir/package.json" | grep -oE '(-p |--port[= ]|PORT=)[0-9]{2,5}' | grep -oE '[0-9]+$' | head -1 || true)"
  [ -z "$p" ] && p="$(set -f; grep -rhoE --include='*.ts' --include='*.js' --include='*.mjs' $(prune_args) 'listen\([^)]*[^0-9][0-9]{4,5}' "$dir" 2>/dev/null | grep -oE '[0-9]{4,5}' | head -1 || true)"
  [ -z "$p" ] && p="$(cat "$dir"/src/main/resources/application*.properties "$dir"/application*.properties 2>/dev/null | grep -m1 -oE '^server\.port\s*=\s*[0-9]+' | grep -oE '[0-9]+$' || true)"
  [ -z "$p" ] && p="$(cat "$dir"/src/main/resources/application*.y*ml "$dir"/application*.y*ml 2>/dev/null | grep -m1 -oE '^\s*port:\s*[0-9]+' | grep -oE '[0-9]+$' || true)"
  [ -z "$p" ] && p="$(grep -m1 -oE '^EXPOSE [0-9]+' "$dir/Dockerfile" 2>/dev/null | grep -oE '[0-9]+$' || true)"
  printf '%s' "${p:-$def}"
}

go_mod_of() {  # nearest go.mod in an ancestor directory (Go monorepos keep one module with cmd/*)
  local d="$1"
  while [ "$d" != "/" ] && [ -n "$d" ]; do [ -f "$d/go.mod" ] && { echo "$d/go.mod"; return; }; d="$(dirname "$d")"; done
  echo ""
}
scripts_block() {  # scripts_block <package.json> — the "scripts" object on one line (works for minified files too)
  tr -d '\n\r' < "$1" | grep -oE '"scripts"[[:space:]]*:[[:space:]]*\{[^}]*\}' | head -1
}
node_script() {  # node_script <package.json> <name> — 0 if the script exists
  scripts_block "$1" | grep -qE "\"$2\"[[:space:]]*:"
}

# detect_stack <dir> — prints  language|framework|group|start|install|port|manifest
detect_stack() {
  local dir="$1" lang="" fw="" group="backend" start="" install="" port="" manifest="" pm="npm" run="npm run"
  if [ -f "$dir/package.json" ]; then
    lang="TypeScript"; [ -f "$dir/tsconfig.json" ] || lang="JavaScript"; manifest="package.json"
    [ -f "$dir/pnpm-lock.yaml" ] && { pm="pnpm"; run="pnpm run"; }
    [ -f "$dir/yarn.lock" ] && { pm="yarn"; run="yarn"; }
    local pj="$dir/package.json"
    if   has '"@nestjs/core"' "$pj"; then fw="NestJS"; port=3000
    elif has '"next"' "$pj"; then fw="Next.js"; group=frontend; port=3000
    elif has '"nuxt"' "$pj"; then fw="Nuxt"; group=frontend; port=3000
    elif has '"@angular/core"' "$pj"; then fw="Angular"; group=frontend; port=4200
    elif has '"react-scripts"' "$pj"; then fw="Create React App"; group=frontend; port=3000
    elif has '"@sveltejs/kit"' "$pj"; then fw="SvelteKit"; group=frontend; port=5173
    elif has '"@remix-run/react"' "$pj"; then fw="Remix"; group=frontend; port=3000
    elif has '"vite"' "$pj" && has '"react"' "$pj"; then fw="React (Vite)"; group=frontend; port=5173
    elif has '"vite"' "$pj" && has '"vue"' "$pj"; then fw="Vue (Vite)"; group=frontend; port=5173
    elif has '"vue"' "$pj"; then fw="Vue"; group=frontend; port=8080
    elif has '"fastify"' "$pj"; then fw="Fastify"; port=3000
    elif has '"express"' "$pj"; then fw="Express"; port=3000
    elif has '"koa"' "$pj"; then fw="Koa"; port=3000
    elif has '"@hapi/hapi"' "$pj"; then fw="Hapi"; port=3000
    elif has '"react"' "$pj"; then fw="React"; group=frontend; port=3000
    else fw="Node.js"; port=3000; fi
    local s
    for s in start:dev dev serve start; do
      if node_script "$pj" "$s"; then start="$run $s"; break; fi
    done
    [ -n "$start" ] || start="$run start"
    install="$pm install"
  elif [ -f "$dir/pom.xml" ]; then
    lang="Java"; manifest="pom.xml"; port=8080
    [ -f "$dir/mvnw" ] && local mvn="./mvnw" || local mvn="mvn"
    if   has 'spring-boot' "$dir/pom.xml"; then fw="Spring Boot"; start="$mvn spring-boot:run"
    elif has 'quarkus' "$dir/pom.xml"; then fw="Quarkus"; start="$mvn quarkus:dev"
    elif has 'micronaut' "$dir/pom.xml"; then fw="Micronaut"; start="$mvn mn:run"
    else fw="Maven"; start="$mvn exec:java"; fi
    install="$mvn -q -DskipTests install"
  elif [ -f "$dir/build.gradle" ] || [ -f "$dir/build.gradle.kts" ]; then
    lang="Java"; [ -f "$dir/build.gradle.kts" ] && lang="Kotlin"; manifest="build.gradle"; port=8080
    [ -f "$dir/gradlew" ] && local gr="./gradlew" || local gr="gradle"
    if has 'org.springframework.boot' "$dir"/build.gradle*; then fw="Spring Boot"; start="$gr bootRun"
    else fw="Gradle"; start="$gr run"; fi
    install="$gr build -x test"
  elif [ -f "$dir/pyproject.toml" ] || [ -f "$dir/requirements.txt" ] || [ -f "$dir/Pipfile" ]; then
    lang="Python"; port=8000
    local m; m="$(cat "$dir"/pyproject.toml "$dir"/requirements.txt "$dir"/Pipfile 2>/dev/null)"
    if [ -f "$dir/pyproject.toml" ]; then manifest="pyproject.toml"; elif [ -f "$dir/requirements.txt" ]; then manifest="requirements.txt"; else manifest="Pipfile"; fi
    if   [ -f "$dir/manage.py" ]; then fw="Django"; start="python manage.py runserver 8000"
    elif printf '%s' "$m" | grep -qi 'fastapi'; then fw="FastAPI"
      if [ -f "$dir/app/main.py" ]; then start="uvicorn app.main:app --reload --port 8000"; else start="uvicorn main:app --reload --port 8000"; fi
    elif printf '%s' "$m" | grep -qi 'flask'; then fw="Flask"; port=5000; start="flask run --port 5000"
    else fw="Python"; start="python main.py"; fi
    if   [ -f "$dir/poetry.lock" ]; then install="poetry install"
    elif [ -f "$dir/uv.lock" ]; then install="uv sync"
    elif [ -f "$dir/Pipfile" ]; then install="pipenv install"
    elif [ -f "$dir/requirements.txt" ]; then install="pip install -r requirements.txt"
    else install="pip install -e ."; fi
  elif [ -f "$dir/go.mod" ] || { [ -f "$dir/main.go" ] && [ -n "$(go_mod_of "$dir")" ]; }; then
    local gomod; gomod="$dir/go.mod"; [ -f "$gomod" ] || gomod="$(go_mod_of "$dir")"
    lang="Go"; manifest="go.mod"; port=8080; start="go run ."; install="go mod download"
    if   has 'gin-gonic/gin' "$gomod"; then fw="Gin"
    elif has 'labstack/echo' "$gomod"; then fw="Echo"
    elif has 'gofiber/fiber' "$gomod"; then fw="Fiber"
    elif has 'go-chi/chi' "$gomod"; then fw="Chi"
    else fw="Go"; fi
  elif [ -f "$dir/Cargo.toml" ]; then
    lang="Rust"; manifest="Cargo.toml"; port=8080; start="cargo run"; install="cargo build"
    if   has 'axum' "$dir/Cargo.toml"; then fw="Axum"
    elif has 'actix-web' "$dir/Cargo.toml"; then fw="Actix Web"
    elif has 'rocket' "$dir/Cargo.toml"; then fw="Rocket"
    else fw="Rust"; fi
  elif ls "$dir"/*.csproj "$dir"/*.sln >/dev/null 2>&1; then
    lang="C#"; manifest="$(ls "$dir"/*.csproj "$dir"/*.sln 2>/dev/null | head -1 | xargs basename)"; port=5000
    start="dotnet run"; install="dotnet restore"
    if cat "$dir"/*.csproj 2>/dev/null | grep -qE 'Microsoft\.NET\.Sdk\.Web|AspNetCore'; then fw="ASP.NET Core"; else fw=".NET"; fi
  elif [ -f "$dir/Gemfile" ]; then
    lang="Ruby"; manifest="Gemfile"; port=3000; install="bundle install"
    if has 'rails' "$dir/Gemfile"; then fw="Rails"; start="bin/rails server -p 3000"
    elif has 'sinatra' "$dir/Gemfile"; then fw="Sinatra"; port=4567; start="bundle exec ruby app.rb"
    else fw="Ruby"; start="bundle exec ruby main.rb"; fi
  elif [ -f "$dir/composer.json" ]; then
    lang="PHP"; manifest="composer.json"; port=8000; install="composer install"
    if has 'laravel/framework' "$dir/composer.json"; then fw="Laravel"; start="php artisan serve --port 8000"
    elif has 'symfony/' "$dir/composer.json"; then fw="Symfony"; start="symfony server:start --port=8000"
    else fw="PHP"; start="php -S localhost:8000 -t public"; fi
  elif [ -f "$dir/index.html" ]; then
    lang="HTML"; fw="Static site"; group=static; manifest="index.html"; port=8080; start="npx serve -l 8080"; install="-"
  else
    return 1
  fi
  port="$(detect_port "$dir" "$port" | tr -d '\n\r ')"
  # Bake the detected port into the start command where the framework takes it as a flag.
  case "$fw" in
    Django) start="python manage.py runserver $port" ;;
    FastAPI) start="$(printf '%s' "$start" | sed -E "s/--port [0-9]+/--port $port/")" ;;
    Flask) start="flask run --port $port" ;;
    Rails) start="bin/rails server -p $port" ;;
    Laravel) start="php artisan serve --port $port" ;;
    "Static site") start="npx serve -l $port" ;;
  esac
  printf '%s|%s|%s|%s|%s|%s|%s\n' "$lang" "$fw" "$group" "$start" "$install" "$port" "$manifest"
}

# ---------------------------------------------------------------------------
# init
# ---------------------------------------------------------------------------

discover_repos() {  # discover_repos <path>... — git repo roots (depth ≤ 3 under a root), excluding the hub and worktrees
  local p
  for p in "$@"; do
    p="$(cd "$p" 2>/dev/null && pwd -P)" || die "Not a directory: $p"
    if [ -e "$p/.git" ]; then printf '%s\n' "$p"; continue; fi
    find "$p" -maxdepth 4 -name .git \( -type d -o -type f \) 2>/dev/null | sed 's#/\.git$##'
  done | grep -v -- '-worktrees/' | grep -v '/node_modules/' | grep -vx "$HUB_DIR" | sort -u
}

# discover_services <git-root> — the runnable units inside one repo, one absolute dir per line.
# A repo that declares workspaces/modules is a container: its members are the services and the root is
# skipped. Otherwise the root itself is the service. Members without a runnable start script (libraries)
# are skipped.
discover_services() {
  local root="$1" members="" pat d m
  if [ -f "$root/package.json" ] && has '"workspaces"' "$root/package.json"; then
    for pat in $(sed -n '/"workspaces"/,/\]/p' "$root/package.json" | grep -oE '"[^"]+"' | tr -d '"' | grep -vE '^(workspaces|packages|nohoist)$'); do
      for d in "$root"/$pat; do [ -d "$d" ] && members="$members
$d"; done
    done
  fi
  if [ -f "$root/pnpm-workspace.yaml" ]; then
    for pat in $(grep -E '^\s*-\s' "$root/pnpm-workspace.yaml" | sed -E "s/^\s*-\s*['\"]?//; s/['\"]?\s*$//" | grep -v '^!'); do
      for d in "$root"/$pat; do [ -d "$d" ] && members="$members
$d"; done
    done
  fi
  if [ -f "$root/pom.xml" ]; then
    for m in $(grep -oE '<module>[^<]+</module>' "$root/pom.xml" | sed -E 's/<[^>]+>//g'); do
      [ -f "$root/$m/pom.xml" ] && members="$members
$root/$m"
    done
  fi
  if ls "$root"/settings.gradle* >/dev/null 2>&1; then
    for m in $(cat "$root"/settings.gradle* | grep -oE "include[[:space:](]+[^)]*" | grep -oE "['\"][^'\"]+['\"]" | tr -d "'\"" | sed 's/^://; s/:/\//g'); do
      [ -d "$root/$m" ] && members="$members
$root/$m"
    done
  fi
  for d in "$root"/apps/* "$root"/packages/* "$root"/services/* "$root"/cmd/*; do
    [ -d "$d" ] || continue
    if [ -f "$d/package.json" ] || [ -f "$d/pom.xml" ] || ls "$d"/build.gradle* >/dev/null 2>&1 || [ -f "$d/pyproject.toml" ] || [ -f "$d/requirements.txt" ] || [ -f "$d/main.go" ] || [ -f "$d/Cargo.toml" ] || ls "$d"/*.csproj >/dev/null 2>&1; then
      members="$members
$d"
    fi
  done
  members="$(printf '%s\n' "$members" | grep . | sort -u)"
  if [ -z "$members" ]; then echo "$root"; return; fi
  # Libraries: a node member without a runnable script is not a service.
  local out=""
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ -f "$d/package.json" ]; then
      local runnable=0 sc
      for sc in start:dev dev serve start; do node_script "$d/package.json" "$sc" && runnable=1; done
      [ "$runnable" = 1 ] || continue
    fi
    out="$out
$d"
  done <<EOF
$members
EOF
  printf '%s\n' "$out" | grep .
  return 0
}

pick_base_branch() {  # pick_base_branch <repo>... — the candidate (dev, develop, main, master) most repos have; ties → that order
  local b r best="" best_n=0 n
  for b in dev develop main master; do
    n=0
    for r in "$@"; do git -C "$r" show-ref --verify --quiet "refs/heads/$b" && n=$((n+1)); done
    [ "$n" -gt "$best_n" ] && { best="$b"; best_n="$n"; }
  done
  echo "${best:-main}"
}

cmd_init() {
  local name="" no_install=0 paths=() a
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name) name="${2:-}"; shift 2 ;;
      --name=*) name="${1#*=}"; shift ;;
      --no-install) no_install=1; shift ;;
      -*) die "Unknown option $1" ;;
      *) paths+=("$1"); shift ;;
    esac
  done
  [ "${#paths[@]}" -gt 0 ] || die "Usage: bootstrap.sh init <repos-root | repo-dir...> [--name \"<project>\"] [--no-install]"
  [ -f "$CONF" ] && die "spechub.conf already exists — delete it to re-run init, or edit it by hand."

  local repos; repos="$(discover_repos "${paths[@]}")"
  [ -n "$repos" ] || die "No git repositories found under: ${paths[*]}"
  local root; root="$(cd "${paths[0]}" && pwd -P)"; [ -e "$root/.git" ] && root="$(dirname "$root")"
  [ -n "$name" ] || name="$(basename "$root")"

  local rows="" r det n rel svc names=" "
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    r="$svc"
    det="$(detect_stack "$r")" || { log "skip $r — no recognised manifest (add it to spechub.conf by hand if it is a service)"; continue; }
    n="$(kebab "$(basename "$r")")"
    # two repos with an apps/api each: prefix the second with its repo name
    case "$names" in *" $n "*) n="$(kebab "$(basename "$(git -C "$r" rev-parse --show-toplevel 2>/dev/null || dirname "$r")")")-$n" ;; esac
    names="$names$n "
    rel="$r"; case "$r" in "$root"/*) rel="${r#$root/}" ;; esac
    # name|dir|start|port|label|group|install|lang|framework
    rows="$rows
$n|$rel|$(printf '%s' "$det" | cut -d'|' -f4)|$(printf '%s' "$det" | cut -d'|' -f6)|$(basename "$r") ($(printf '%s' "$det" | cut -d'|' -f2))|$(printf '%s' "$det" | cut -d'|' -f3)|$(printf '%s' "$det" | cut -d'|' -f5)"
    log "$n → $(printf '%s' "$det" | cut -d'|' -f2) [$(printf '%s' "$det" | cut -d'|' -f3)] port $(printf '%s' "$det" | cut -d'|' -f6)  ($rel)"
  done <<EOF
$(while IFS= read -r r; do [ -n "$r" ] && discover_services "$r"; done <<EOR
$repos
EOR
)
EOF
  [ -n "$(printf '%s' "$rows" | tr -d '\n ')" ] || die "No service detected."
  # Spec order: frontends, then backends, then static — each alphabetical. This order is the spec numbering.
  local ordered
  ordered="$( { printf '%s\n' "$rows" | awk -F'|' '$6=="frontend"' | sort; printf '%s\n' "$rows" | awk -F'|' '$6=="backend"' | sort; printf '%s\n' "$rows" | awk -F'|' '$6=="static"' | sort; } | grep '|' )"
  local base; base="$(pick_base_branch $(printf '%s\n' "$repos" | tr '\n' ' '))"
  local agent=claude c
  for c in claude codex copilot; do command -v "$c" >/dev/null 2>&1 && { agent="$c"; break; }; done
  [ "$agent" = claude ] && ! command -v claude >/dev/null 2>&1 && ls "$HOME"/.vscode/extensions/anthropic.claude-code-*/resources/native-binary/claude >/dev/null 2>&1 && agent=claude

  {
    printf '# spechub.conf — project, repos, and how to run them. Generated by scripts/bootstrap.sh init on %s.\n' "$(date '+%Y-%m-%d')"
    printf '# Plain bash, sourced by every script in scripts/. Edit freely: fix commands, ports, groups; reorder to change spec numbering.\n\n'
    printf 'PROJECT_NAME="%s"\n\n' "$name"
    printf '# Base branch feature branches are cut from and merged back into.\nBASE_BRANCH="%s"\n\n' "$base"
    printf '# Headless coding agent that runs the prompts: claude | codex | copilot (AGENT_BIN overrides the PATH lookup).\nAGENT_CLI="%s"\n#AGENT_BIN=""\n\n' "$agent"
    printf '# Model per tier for that CLI. Prompts name a tier (Light | Standard | Advanced); leave commented for the defaults.\n#MODEL_LIGHT=""\n#MODEL_STANDARD=""\n#MODEL_ADVANCED=""\n\n'
    printf '# Parent directory of the service repos; relative `dir` entries resolve against it.\nREPOS_ROOT="%s"\n\n' "$root"
    printf '# Gitignored files copied from each main checkout into its worktrees (glob patterns).\nWORKTREE_COPY_FILES=".env .env.* application-local.properties"\n\n'
    printf '# Dependency directories linked from the main checkout into worktrees (DISPATCH_DEPS=install reinstalls instead).\nWORKTREE_LINK_DIRS="node_modules .venv vendor"\n\n'
    printf '# name|dir|start command|port|label|group|install command   (group: static | backend | frontend)\n'
    printf '# Order = spec numbering (01-, 02-, …) used by Step 0 (bootstrap-specs).\nSERVICES="\n%s\n"\n' "$ordered"
  } > "$CONF"
  log "wrote spechub.conf ($(printf '%s\n' "$ordered" | wc -l | tr -d ' ') services, base branch '$base')"

  # Port collisions are the most common detection miss — say so now.
  local dup; dup="$(printf '%s\n' "$ordered" | cut -d'|' -f4 | sort | uniq -d | tr '\n' ' ')"
  [ -n "$dup" ] && log "WARNING: several services share port(s) $dup— edit the port column (and start command) in spechub.conf before starting the stack."

  cmd_services
  if [ "$no_install" = 0 ]; then log "installing dependencies (skip with --no-install)"; "$STACK" install || log "WARNING: some installs failed — fix the install command in spechub.conf and re-run: scripts/bootstrap.sh install"; fi
  cmd_facts
  cmd_plan >&2
  cat >&2 <<EOF

[bootstrap] Next:
  1. Review spechub.conf: delete rows that are not services (old copies, scripts, libraries), fix
     commands/ports/groups, reorder the rows (order = spec numbering). A monorepo appears as one row per
     workspace member (dir = repo/apps/x). Then 'scripts/stack.sh start' to check the stack runs.
  2. Open your coding agent in this folder on a Standard-tier model and run the bootstrap-specs skill
     (Claude Code: /bootstrap-specs; other tools: "follow skills/bootstrap-specs/SKILL.md").
     It writes the service specs, the architecture overview, CONVENTIONS.md, STATUS.md and repo-instructions/
     from the fact sheets in bootstrap/facts/ (Step 0 of WORKFLOW.md).
EOF
}

# ---------------------------------------------------------------------------
# services table in AGENTS.md
# ---------------------------------------------------------------------------

load_conf() {
  [ -f "$CONF" ] || die "spechub.conf not found — run init first."
  # shellcheck disable=SC1090
  . "$CONF"
  REPOS_ROOT="${REPOS_ROOT:-$HUB_DIR/..}"
}
conf_services() {  # name|dir|start|port|label|group|install — comment/blank lines removed
  printf '%s\n' "$SERVICES" | grep -v '^[[:space:]]*#' | grep '|'
}
svc_abs_dir() { local d="$1"; d="${d/#\~/$HOME}"; case "$d" in /*) printf '%s' "$d" ;; *) printf '%s/%s' "$REPOS_ROOT" "$d" ;; esac; }

spec_rows() {  # nn|name|dir|label|group|spec-file — spec numbering follows spechub.conf order (static servers get no spec)
  local i=0 line name dir label group
  while IFS='|' read -r name dir _ _ label group _; do
    [ -n "$name" ] || continue
    if [ "$group" = static ]; then printf '%s|%s|%s|%s|%s|%s\n' "--" "$name" "$(svc_abs_dir "$dir")" "$label" "$group" "-"; continue; fi
    i=$((i+1))
    printf '%02d|%s|%s|%s|%s|%02d-%s.md\n' "$i" "$name" "$(svc_abs_dir "$dir")" "$label" "$group" "$i" "$name"
  done < <(conf_services)
}

cmd_services() {
  load_conf
  [ -f "$AGENTS_MD" ] || die "AGENTS.md not found in $HUB_DIR"
  grep -q '<!-- services:start -->' "$AGENTS_MD" || die "AGENTS.md has no <!-- services:start --> marker"
  local table; table="$(
    printf '| Service | Local repo | Group | Spec |\n|---|---|---|---|\n'
    spec_rows | while IFS='|' read -r nn name dir label group spec; do
      printf '| `%s` — %s | `%s` | %s | %s |\n' "$name" "$label" "$dir" "$group" "$( [ "$spec" = "-" ] && echo "— (static server, no spec)" || printf '`%s`' "$spec" )"
    done
  )"
  local tmp; tmp="$(mktemp)"
  TABLE="$table" awk '
    /<!-- services:start -->/ { print; print ENVIRON["TABLE"]; skip=1; next }
    /<!-- services:end -->/   { skip=0 }
    !skip { print }
  ' "$AGENTS_MD" > "$tmp" && mv "$tmp" "$AGENTS_MD"
  log "updated the services table in AGENTS.md"
}

# ---------------------------------------------------------------------------
# facts
# ---------------------------------------------------------------------------

facts_layout() {  # directory tree, depth 3, dirs then files per level, pruned, sorted
  local dir="$1"
  ( cd "$dir" && set -f && find . -maxdepth 3 $(find_prune) -print 2>/dev/null | sed 's#^\./##' | grep -v '^\.$' | sort ) | head -400
}

source_root() {  # the directory whose children are the modules: src/app (Angular), src, app, else the repo root
  local dir="$1"
  if [ -d "$dir/src/app" ] && [ -f "$dir/angular.json" ]; then echo "src/app"
  elif [ -d "$dir/src" ]; then echo "src"
  elif [ -d "$dir/app" ]; then echo "app"
  else echo "."; fi
}

count_src() { ( cd "$1" && set -f && find . $(find_prune) -type f \( $(for e in $SRC_EXT; do printf -- '-name *.%s -o ' "$e"; done) -false \) -print 2>/dev/null | wc -l | tr -d ' ' ); }

# For a frontend, the children of the source root are technical layers (components, hooks, store,
# utils, theme) rather than domains, so a spec split along them produces layer files instead of the
# feature files an implementation prompt needs. When a frontend has a views/screens directory with
# two or more populated subdirectories, that directory is the module root and the remaining children
# of the source root are "shared layers" (documented in 00-core.md / 01-conventions.md, never split
# into their own module files). Every other service keeps the source root as its module root.
VIEW_DIRS="views screens"

module_root() {  # module_root <dir> <group> → path (relative to <dir>) whose children are the modules
  local dir="$1" group="$2" sr v cand d n
  sr="$(source_root "$dir")"
  if [ "$group" = frontend ]; then
    for v in $VIEW_DIRS; do
      cand="$sr/$v"; [ "$sr" = "." ] && cand="$v"
      [ -d "$dir/$cand" ] || continue
      n=0
      for d in "$dir/$cand"/*/; do
        [ -d "$d" ] || continue
        [ "$(count_src "$d")" -gt 0 ] && n=$((n+1))
      done
      if [ "$n" -ge 2 ]; then printf '%s' "$cand"; return 0; fi
    done
  fi
  printf '%s' "$sr"
}

dir_children() {  # dir_children <dir> <relroot> [<skip-relpath>] → "relpath|files" per populated child dir
  local dir="$1" root="$2" skip="${3:-}" pfx d b n
  pfx="$root/"; [ "$root" = "." ] && pfx=""
  [ -d "$dir/$root" ] || return 0
  for d in "$dir/$root"/*/; do
    [ -d "$d" ] || continue
    b="$(basename "$d")"
    case " $PRUNE_DIRS " in *" $b "*) continue ;; esac
    [ -n "$skip" ] && [ "$pfx$b" = "$skip" ] && continue
    n="$(count_src "$d")"
    [ "$n" -gt 0 ] && printf '%s%s|%s\n' "$pfx" "$b" "$n"
  done | sort
  return 0
}

facts_modules() { dir_children "$1" "$2"; }              # facts_modules <dir> <modroot>
facts_layers() {  # facts_layers <dir> <srcroot> <modroot> — empty unless the module root was moved
  [ "$2" = "$3" ] && return 0
  dir_children "$1" "$2" "$3"
}

module_slug() {  # module_slug <module relpath> → the module file's base name (camelCase → kebab)
  basename "$1" | sed -E 's/([a-z0-9])([A-Z])/\1-\2/g' | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

ROUTE_RE='@(Get|Post|Put|Patch|Delete|Head|Options|All|Controller)\(|@(Get|Post|Put|Patch|Delete|Request)Mapping|\b(app|router|route|server|r|g|e|api|fastify|http)\.(get|post|put|patch|delete|route|all|use)\(\s*['"'"'"`/]|@(app|router|bp|api|blueprint)\.(get|post|put|patch|delete|route)\(|\[(HttpGet|HttpPost|HttpPut|HttpPatch|HttpDelete|Route)\b|HandleFunc\(|\.(GET|POST|PUT|PATCH|DELETE)\(\s*"|Route::(get|post|put|patch|delete|resource|apiResource)\(|<Route\b|^\s*(path|route):\s*['"'"'"]'
MODEL_RE='@Schema\(|@Entity\b|@Document\b|@Table\(|@Prop\(|@Column\(|class [A-Za-z0-9_]+\((Base|BaseModel|models\.Model|Document|db\.Model)\)|new (mongoose\.)?Schema\(|sequelize\.define\(|^model [A-Za-z0-9_]+ \{|DbSet<|SchemaFactory\.createForClass|class [A-Za-z0-9_]+ < (ApplicationRecord|ActiveRecord::Base)'
# Env-var extraction is split by evidence class so the spec's table can be a mechanical union with
# no filtering step. ENV_RE_SRC matches only real accessor syntax in source files — including the
# indirect accessors a config layer puts in front of the environment (NestJS `configService.get`,
# Spring `@Value("${...}")`, Viper), because a service that reads everything through one of those
# would otherwise report an empty environment. The old combined
# pattern also carried a bare `${` alternative, which matched every `${CONSTANT}` template literal in
# JS/TS and put local constants (COL_GAP, WIDGET_SCRIPTS) into the sheet as env vars; `${NAME}` is a
# real env reference in yaml/properties/toml/Dockerfile only, so it is matched there and only there.
ENV_RE_SRC='(process\.env\.|process\.env\[.|import\.meta\.env\.|os\.environ\[.|os\.environ\.get\(.|os\.getenv\(.|os\.Getenv\(.|ENV\[.|env\(.|GetEnvironmentVariable\(.|Env\.get\(.|[Cc]onfig([Ss]ervice)?\.get(<[^>]*>)?\(.|cfg\.get(<[^>]*>)?\(.|@Value\(.\$\{|viper\.Get[A-Za-z]*\(.)[A-Z][A-Za-z0-9_]{2,}'
ENV_RE_TMPL='\$\{[A-Z][A-Za-z0-9_]{2,}\}'
ENV_EXCLUDE='^(PATH|HOME|PWD|SHELL|USER|LANG|LC_ALL|TZ)$|_$'   # OS-level, plus bare prefixes (`REACT_APP_`) from docs

facts_routes() {
  local dir="$1"
  ( cd "$dir" && set -f && grep -rInE $(prune_args) $(include_args) -e "$ROUTE_RE" . 2>/dev/null | sed 's#^\./##' | sed -E 's/^([^:]+:[0-9]+:)[[:space:]]+/\1 /' | cut -c1-220 | sort -t: -k1,1 -k2,2n ) | head -600
}
facts_route_files() {  # file-system routing (Next.js pages/app, Nuxt pages, SvelteKit routes, Rails routes.rb, Django urls.py)
  local dir="$1"
  ( cd "$dir" && set -f && find . $(find_prune) -type f \( -path '*/pages/*' -o -path '*/app/*/page.*' -o -path '*/app/page.*' -o -path '*/app/*/route.*' -o -path '*/app/*/layout.*' -o -path '*/routes/*' -o -name routes.rb -o -name urls.py -o -name '*.routes.ts' -o -name '*-routing.module.ts' \) \( -name '*.js' -o -name '*.jsx' -o -name '*.ts' -o -name '*.tsx' -o -name '*.vue' -o -name '*.svelte' -o -name '*.rb' -o -name '*.py' \) -print 2>/dev/null | sed 's#^\./##' | sort ) | head -300
}
facts_model_files() {
  local dir="$1"
  ( cd "$dir" && set -f && find . $(find_prune) -type f \( -name '*.schema.ts' -o -name '*.entity.ts' -o -name '*.model.ts' -o -name '*.model.js' -o -name 'models.py' -o -path '*/models/*.py' -o -name 'schema.prisma' -o -path '*/app/models/*.rb' -o -path '*/models/*.go' -o -path '*/entity/*.java' -o -path '*/entities/*.java' -o -path '*/domain/*.java' -o -path '*/Models/*.cs' -o -path '*/Entities/*.cs' -o -name '*.dto.ts' \) -print 2>/dev/null | sed 's#^\./##' | sort ) | head -300
}
facts_model_decls() {
  local dir="$1"
  ( cd "$dir" && set -f && grep -rInE $(prune_args) $(include_args) --include='*.prisma' -e "$MODEL_RE" . 2>/dev/null | sed 's#^\./##' | sed -E 's/^([^:]+:[0-9]+:)[[:space:]]+/\1 /' | cut -c1-200 | sort -t: -k1,1 -k2,2n ) | head -400
}
facts_env_src() {  # "NAME file:line" for every accessor reference in source, comment-only lines excluded
  # All regex work stays in grep: the macOS system awk has no {n,} interval support, so awk only
  # does string surgery. Line 1 of each pair is a `file:line:` marker, the rest are that line's matches.
  local dir="$1"
  ( cd "$dir" && set -f && grep -rInE $(prune_args) $(include_args) -e "$ENV_RE_SRC" . 2>/dev/null ) \
    | sed 's#^\./##' \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|\*|#|--)' \
    | grep -oE '^[^:]+:[0-9]+:|'"$ENV_RE_SRC" \
    | awk '
        substr($0, length($0), 1) == ":" { loc = substr($0, 1, length($0) - 1); next }
        loc != "" {
          k = length($0)
          while (k > 0 && substr($0, k, 1) ~ /[A-Za-z0-9_]/) k--
          name = substr($0, k + 1)
          if (length(name) > 2) printf "%s %s\n", name, loc
        }' \
    | sort -u | head -400
}
facts_env_tmpl() {  # "NAME file:line" for ${NAME} in config formats where that is an env reference
  local dir="$1"
  ( cd "$dir" && set -f && grep -rIonE $(prune_args) --include='*.yml' --include='*.yaml' --include='*.properties' --include='*.toml' --include='Dockerfile*' -e "$ENV_RE_TMPL" . 2>/dev/null ) \
    | sed 's#^\./##' \
    | sed -E 's/^([^:]+):([0-9]+):\$\{([A-Za-z0-9_]+)\}$/\3 \1:\2/' \
    | grep -E '^[A-Za-z0-9_]+ ' | sort -u | head -200
}
facts_env_dotenv() {  # "NAME file" for every key declared in a committed env sample
  local dir="$1" f
  for f in .env.example .env.sample .env.template; do
    [ -f "$dir/$f" ] || continue
    sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=.*/\1/p' "$dir/$f" | grep -E '^[A-Z]' | sed "s#\$# $f#"
  done | sort -u | head -200
}
facts_env_canonical() {  # the union — the spec's Environment Variables table is exactly this list
  local dir="$1"
  { facts_env_src "$dir"; facts_env_tmpl "$dir"; facts_env_dotenv "$dir"; } \
    | awk '{print $1}' | grep -vE "$ENV_EXCLUDE" | sort -u
}
# §12 makes the writer's read set closed-world: an explicit, ordered, complete file list rather than
# "the files the fact sheet names", which left the writer deciding how deep to go (one run read 2 of
# 28 service files, the next read all 28). Order is: entry points, then by directory, then by role
# (route/controller → model/DTO → service/guard → module wiring → the rest), then by name.
read_rank() {  # read_rank <relpath> → role rank inside its directory
  case "$1" in
    */dto/*|*.dto.*)                                           echo 3 ;;
    *.controller.*|*.resolver.*|*[Rr]outes.*|*.router.*|*.route.*|*-routing.module.*) echo 2 ;;
    *.schema.*|*.entity.*|*.model.*|*models.py)                echo 3 ;;
    *.service.*|*.repository.*|*.guard.*|*.strategy.*|*.interceptor.*|*.filter.*|*.pipe.*|*.middleware.*) echo 4 ;;
    *.module.*)                                                echo 5 ;;
    *)                                                         echo 6 ;;
  esac
}
facts_read_order() {  # facts_read_order <dir>
  local dir="$1" rel dirkey base
  ( cd "$dir" && set -f && find . $(find_prune) -type f \( $(for e in $SRC_EXT; do printf -- '-name *.%s -o ' "$e"; done) -false \) -print 2>/dev/null | sed 's#^\./##' ) \
  | while IFS= read -r rel; do
      case "$rel" in
        *.spec.*|*.test.*|*.stories.*|*.d.ts|*.min.js) continue ;;
        .*|*/.*) continue ;;                      # dotfile configs are listed in §9, not read as source
      esac
      base="$(basename "$rel")"
      dirkey="$(dirname "$rel")"
      case "$base" in
        main.*|index.*|server.*|App.js|App.jsx|App.tsx|app.module.ts|_app.js|_app.tsx|Routes.js|Routes.tsx|Program.cs|manage.py)
          case "$dirkey" in .|src|app|src/app) dirkey="!" ;; esac ;;
      esac
      printf '%s\t%s\t%s\n' "$dirkey" "$(read_rank "$rel")" "$rel"
    done \
  | sort -t"$(printf '\t')" -k1,1 -k2,2n -k3,3 | cut -f3 | head -500
}
facts_deps() {
  local dir="$1"
  if [ -f "$dir/package.json" ]; then
    sed -n '/"dependencies"/,/}/p' "$dir/package.json" | grep -oE '^\s*"[^"]+"' | tr -d ' "' | grep -v '^dependencies$' | sort
    printf -- '--- devDependencies ---\n'
    sed -n '/"devDependencies"/,/}/p' "$dir/package.json" | grep -oE '^\s*"[^"]+"' | tr -d ' "' | grep -v '^devDependencies$' | sort
  elif [ -f "$dir/pom.xml" ]; then grep -oE '<artifactId>[^<]+</artifactId>' "$dir/pom.xml" | sed -E 's/<[^>]+>//g' | sort -u
  elif ls "$dir"/build.gradle* >/dev/null 2>&1; then grep -hoE "(implementation|api|runtimeOnly|compileOnly)[ (]+['\"][^'\"]+['\"]" "$dir"/build.gradle* | sed -E "s/^[a-zA-Z]+[ (]+['\"]//; s/['\"]$//" | sort -u
  elif [ -f "$dir/requirements.txt" ]; then grep -vE '^\s*(#|$|-)' "$dir/requirements.txt" | sed -E 's/[=<>!~;\[ ].*//' | sort -u
  elif [ -f "$dir/pyproject.toml" ]; then sed -n '/dependencies/,/\]/p' "$dir/pyproject.toml" | grep -oE '"[A-Za-z0-9_.-]+' | tr -d '"' | sort -u
  elif [ -f "$dir/go.mod" ]; then sed -n '/require/,/)/p' "$dir/go.mod" | grep -oE '^\s*[a-z0-9./-]+\s' | tr -d ' \t' | sort -u
  elif [ -f "$dir/Cargo.toml" ]; then sed -n '/\[dependencies\]/,/^\[/p' "$dir/Cargo.toml" | grep -oE '^[a-zA-Z0-9_-]+' | sort -u
  elif ls "$dir"/*.csproj >/dev/null 2>&1; then grep -hoE 'PackageReference Include="[^"]+"' "$dir"/*.csproj | sed -E 's/.*="//; s/"$//' | sort -u
  elif [ -f "$dir/Gemfile" ]; then grep -oE "^\s*gem ['\"][^'\"]+" "$dir/Gemfile" | sed -E "s/.*['\"]//" | sort -u
  elif [ -f "$dir/composer.json" ]; then sed -n '/"require"/,/}/p' "$dir/composer.json" | grep -oE '^\s*"[^"]+"' | tr -d ' "' | grep -v '^require$' | sort
  fi
}
facts_config_files() {
  local dir="$1" f
  for f in Dockerfile docker-compose.yml docker-compose.yaml compose.yml .env.example .env.sample tsconfig.json angular.json next.config.js next.config.mjs next.config.ts vite.config.ts vite.config.js nuxt.config.ts svelte.config.js nest-cli.json ormconfig.json prisma/schema.prisma src/main/resources/application.properties src/main/resources/application.yml src/main/resources/application.yaml application.properties settings.py manage.py alembic.ini pytest.ini setup.cfg Makefile Procfile nginx.conf openapi.yaml openapi.json swagger.json .eslintrc.js .eslintrc.json eslint.config.js eslint.config.mjs .prettierrc jest.config.js jest.config.ts vitest.config.ts .github/workflows Jenkinsfile .gitlab-ci.yml serverless.yml k8s helm terraform CLAUDE.md AGENTS.md .github/copilot-instructions.md .cursorrules; do
    [ -e "$dir/$f" ] && printf '%s\n' "$f"
  done
}
facts_ext_counts() {
  ( cd "$1" && set -f && find . $(find_prune) -type f -print 2>/dev/null | sed -nE 's/.*\.([A-Za-z0-9]+)$/\1/p' | sort | uniq -c | sort -k1,1nr -k2,2 | head -15 | awk '{printf "| %s | %s |\n", $2, $1}' )
}
facts_scripts() {  # package.json scripts as a table
  [ -f "$1/package.json" ] || return 0
  scripts_block "$1/package.json" | sed -E 's/^"scripts"[[:space:]]*:[[:space:]]*\{//; s/\}$//' | sed -E 's/",[[:space:]]*"/"\
"/g' | sed -E 's/^[[:space:]]*"([^"]+)"[[:space:]]*:[[:space:]]*"(.*)"[[:space:]]*$/| `\1` | `\2` |/' | sed 's/\\"/"/g'
}
facts_readme() {
  local dir="$1" f
  for f in README.md readme.md README.rst README; do
    [ -f "$dir/$f" ] && { printf '### %s (first 60 lines)\n\n' "$f"; head -60 "$dir/$f" | sed 's/^#/####/'; return; }
  done
  echo "(no README)"
}

write_facts() {  # write_facts <name> <dir> <start> <port> <label> <group> <install>
  local name="$1" dir="$2" start="$3" port="$4" label="$5" group="$6" install="$7"
  [ -d "$dir" ] || { log "skip $name — $dir does not exist"; return 0; }
  local out="$FACTS_DIR/$name.md" det lang fw manifest sha branch remote
  det="$(detect_stack "$dir" 2>/dev/null || echo "?|?|$group|$start|$install|$port|?")"
  lang="$(printf '%s' "$det" | cut -d'|' -f1)"; fw="$(printf '%s' "$det" | cut -d'|' -f2)"; manifest="$(printf '%s' "$det" | cut -d'|' -f7)"
  sha="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo '-')"
  branch="$(git -C "$dir" branch --show-current 2>/dev/null || echo '-')"
  remote="$(git -C "$dir" remote get-url origin 2>/dev/null || echo '-')"
  local groot sub; groot="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "$dir")"
  sub="${dir#$groot/}"; [ "$sub" = "$dir" ] && sub=""
  local sr mr; sr="$(source_root "$dir")"; mr="$(module_root "$dir" "$group")"
  local instr=""; local f
  for f in CLAUDE.md AGENTS.md .github/copilot-instructions.md .cursorrules; do [ -f "$dir/$f" ] && instr="$instr $f"; done
  mkdir -p "$FACTS_DIR"
  {
    printf '# Fact sheet — `%s`\n\n' "$name"
    printf '> Mechanical extraction by `scripts/bootstrap.sh facts` from `%s` @ `%s` (%s). Regenerate, never edit. The bootstrap-specs skill writes the service spec from this sheet plus the files it names.\n\n' "$dir" "$sha" "$branch"
    printf '## 1. Identity\n\n| Field | Value |\n|---|---|\n'
    printf '| Service | `%s` |\n| Label | %s |\n| Group | %s |\n| Directory | `%s` |\n| Git root | `%s` |\n| Path in repo | %s |\n| Remote | `%s` |\n| Branch @ HEAD | `%s` @ `%s` |\n| Start | `%s` |\n| Install | `%s` |\n| Port | %s |\n| Instruction files | %s |\n\n' \
      "$name" "$label" "$group" "$dir" "$groot" "${sub:+\`$sub/\`}${sub:-(repo root)}" "$remote" "$branch" "$sha" "$start" "$install" "$port" "${instr:-none}"
    printf '## 2. Stack\n\n| Field | Value |\n|---|---|\n| Language | %s |\n| Framework | %s |\n| Manifest | `%s` |\n| Source root | `%s` |\n| Source files | %s |\n\n' "$lang" "$fw" "$manifest" "$sr" "$(count_src "$dir")"
    local scripts; scripts="$(facts_scripts "$dir")"
    if [ -n "$scripts" ]; then printf '### Scripts\n\n| Script | Command |\n|---|---|\n%s\n\n' "$scripts"; fi
    printf '## 3. Layout (depth 3)\n\n```text\n%s\n```\n\n' "$(facts_layout "$dir")"
    printf '## 4. Source Modules (children of `%s`)\n\n' "$mr"
    if [ "$mr" != "$sr" ]; then
      printf 'This is a frontend whose `%s` directory holds the routed feature domains, so the modules are its children. The children of the source root `%s` are shared layers (§4b) and are documented in `00-core.md` / `01-conventions.md`, never as module files.\n\n' "$mr" "$sr"
    fi
    printf '| Module | Module file | Source files |\n|---|---|---|\n'
    local mods; mods="$(facts_modules "$dir" "$mr")"
    printf '%s\n' "$mods" | awk -F'|' '
      function slug(b,   i, c, p, out) {          # camelCase → kebab-case, then lowercase
        out = ""
        for (i = 1; i <= length(b); i++) {
          c = substr(b, i, 1)
          if (c ~ /[A-Z]/ && p ~ /[a-z0-9]/) out = out "-"
          out = out tolower(c); p = c
        }
        gsub(/[^a-z0-9]+/, "-", out); sub(/^-+/, "", out); sub(/-+$/, "", out)
        return out
      }
      NF { n = split($1, a, "/"); printf "| `%s` | `%s.md` | %s |\n", $1, slug(a[n]), $2 }'
    printf '\nModule count: %s\n\n' "$(printf '%s\n' "$mods" | grep -c '|' || true)"
    local layers; layers="$(facts_layers "$dir" "$sr" "$mr")"
    if [ -n "$layers" ]; then
      printf '### 4b. Shared layers (children of `%s`, not modules)\n\n| Layer | Source files |\n|---|---|\n' "$sr"
      printf '%s\n' "$layers" | awk -F'|' 'NF {printf "| `%s` | %s |\n", $1, $2}'
      printf '\n'
    fi
    printf '## 5. Routes & Endpoints\n\n### Declarations (file:line: text)\n\n```text\n%s\n```\n\n' "$(facts_routes "$dir")"
    printf '### Route files (file-system routing, route tables)\n\n```text\n%s\n```\n\n' "$(facts_route_files "$dir")"
    printf '## 6. Data Models\n\n### Model files\n\n```text\n%s\n```\n\n### Declarations (file:line: text)\n\n```text\n%s\n```\n\n' "$(facts_model_files "$dir")" "$(facts_model_decls "$dir")"
    printf '## 7. Environment Variables (referenced)\n\n'
    printf '### 7a. Canonical list\n\nThe service spec'"'"'s Environment Variables table has exactly these rows, one each, alphabetical — no additions, no filtering. Evidence for every name is in 7b-7d.\n\n```text\n%s\n```\n\n' "$(facts_env_canonical "$dir")"
    printf '### 7b. Accessor references in source (NAME file:line)\n\n```text\n%s\n```\n\n' "$(facts_env_src "$dir")"
    printf '### 7c. `${NAME}` references in config formats (NAME file:line)\n\n```text\n%s\n```\n\n' "$(facts_env_tmpl "$dir")"
    printf '### 7d. Declared in a committed env sample (NAME file)\n\n```text\n%s\n```\n\n' "$(facts_env_dotenv "$dir")"
    printf 'Excluded from 7a as OS-level: `%s`.\n\n' "$ENV_EXCLUDE"
    printf '## 8. Dependencies\n\n```text\n%s\n```\n\n' "$(facts_deps "$dir")"
    printf '## 9. Config & Infra Files Present\n\n```text\n%s\n```\n\n' "$(facts_config_files "$dir")"
    printf '## 10. File Counts by Extension\n\n| Ext | Files |\n|---|---|\n%s\n\n' "$(facts_ext_counts "$dir")"
    printf '## 11. Existing Docs\n\n%s\n\n' "$(facts_readme "$dir")"
    printf '## 12. Files To Read\n\nThe writer reads exactly this set, in this order, each file once — nothing above it, nothing below it. Entry points first, then by directory, then by role within a directory (route/controller, model/DTO, service/guard, module wiring, the rest), then by name. Tests, type declarations and minified files are excluded. Truncated at 500 entries; if the list is 500 long, say so in Known Issues & Gaps.\n\n```text\n%s\n```\n' "$(facts_read_order "$dir")"
  } > "$out"
  log "facts → ${out#$HUB_DIR/}"
}

cmd_facts() {
  load_conf
  local want=" $* " name dir start port label group install
  while IFS='|' read -r name dir start port label group install; do
    [ -n "$name" ] || continue
    [ "$#" -eq 0 ] || case "$want" in *" $name "*) ;; *) continue ;; esac
    [ "$group" = static ] && continue
    write_facts "$name" "$(svc_abs_dir "$dir")" "$start" "$port" "$label" "$group" "$install"
  done < <(conf_services)
}

# The module file names a writer must produce, from the fact sheet's §4 table. Emitting the list
# (not just the count) is what makes the file set checkable: a writer that folds two modules away
# — one run dropped `common` and `schemas` from a service and with them that service's only field
# tables — now fails the manifest check in the skill instead of shipping a silently shorter spec.
manifest_modules() {  # manifest_modules <service> → module file base names, one per line
  local name="$1" sheet="$FACTS_DIR/$name.md"
  [ -f "$sheet" ] || return 0
  sed -n '/^## 4\. Source Modules/,/^Module count:/p' "$sheet" \
    | sed -nE 's/^\| `[^`]+` \| `([^`]+)\.md` \|.*/\1/p' | sort
}

cmd_plan() {
  load_conf
  local manifest=0
  [ "${1:-}" = "--manifest" ] && manifest=1
  if [ "$manifest" = 0 ]; then
    printf '%-4s %-22s %-28s %-8s %s\n' "NN" "SERVICE" "SPEC FILE" "MODULES" "SHAPE"
  fi
  spec_rows | while IFS='|' read -r nn name dir label group spec; do
    [ "$spec" = "-" ] && continue
    local mods="?" shape="single file" split=0
    if [ -f "$FACTS_DIR/$name.md" ]; then
      mods="$(sed -n 's/^Module count: //p' "$FACTS_DIR/$name.md" | head -1)"
      if [ "${mods:-0}" -gt "$SPLIT_THRESHOLD" ] 2>/dev/null; then
        split=1
        shape="split: index + ${spec%.md}/ (00-core.md, 01-conventions.md, one file per module)"
      fi
    else
      shape="(no fact sheet yet — run: scripts/bootstrap.sh facts)"
    fi
    if [ "$manifest" = 0 ]; then
      printf '%-4s %-22s %-28s %-8s %s\n' "$nn" "$name" "$spec" "$mods" "$shape"
      continue
    fi
    printf '%s (%s, %s)\n' "$name" "$nn" "$([ "$split" = 1 ] && echo split || echo single)"
    printf '  %s\n' "$spec"
    if [ "$split" = 1 ]; then
      printf '  %s/00-core.md\n  %s/01-conventions.md\n' "${spec%.md}" "${spec%.md}"
      manifest_modules "$name" | sed "s#^#  ${spec%.md}/#; s#\$#.md#"
    fi
    printf '  repo-instructions/%s.md\n\n' "$name"
  done
  if [ "$manifest" = 0 ]; then
    printf '\nSplit threshold: more than %s source modules (SPECHUB_SPLIT_THRESHOLD). Numbering follows spechub.conf order.\n' "$SPLIT_THRESHOLD"
    printf 'Exact file list per service: scripts/bootstrap.sh plan --manifest\n'
  fi
}

usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

cmd="${1:-}"; shift || true
case "$cmd" in
  init)     cmd_init "$@" ;;
  facts)    cmd_facts "$@" ;;
  plan)     cmd_plan "$@" ;;
  services) cmd_services ;;
  install)  "$STACK" install "$@" ;;
  *) usage ;;
esac
