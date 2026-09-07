#!/usr/bin/env bash
# scripts/bootstrap.sh — Step 0: bring an existing (or brand-new) codebase into the spec hub.
#
#   scripts/bootstrap.sh init <repos-root> [--name "<project>"] [--no-install]
#   scripts/bootstrap.sh init <repo-dir> [<repo-dir>...] [--name "<project>"] [--no-install]
#       discover the git repos, detect each one's stack (language, framework, start/install
#       commands, port), write spechub.conf, insert the services table into CLAUDE.md, install
#       dependencies, and write one fact sheet per service (see `facts`).
#   scripts/bootstrap.sh facts [<service>...]     (re)write bootstrap/facts/<service>.md for every service in spechub.conf
#   scripts/bootstrap.sh plan                     print the spec plan: number, service, spec file, module count, split?
#   scripts/bootstrap.sh services                 refresh the services table in CLAUDE.md from spechub.conf
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
CLAUDE_MD="$HUB_DIR/CLAUDE.md"
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
  p="$(cat "$dir"/.env "$dir"/.env.local "$dir"/.env.development "$dir"/.env.example 2>/dev/null | grep -m1 -oE '^(PORT|SERVER_PORT|APP_PORT)=[0-9]{2,5}' | grep -oE '[0-9]+$' || true)"
  [ -z "$p" ] && [ -f "$dir/package.json" ] && p="$(sed -n '/"scripts"/,/}/p' "$dir/package.json" | grep -m1 -oE '(-p |--port[= ]|PORT=)[0-9]{2,5}' | grep -oE '[0-9]+$' || true)"
  [ -z "$p" ] && p="$(set -f; grep -rhoE --include='*.ts' --include='*.js' --include='*.mjs' $(prune_args) 'listen\([^)]*[^0-9][0-9]{4,5}' "$dir" 2>/dev/null | grep -oE '[0-9]{4,5}' | head -1 || true)"
  [ -z "$p" ] && p="$(cat "$dir"/src/main/resources/application*.properties "$dir"/application*.properties 2>/dev/null | grep -m1 -oE '^server\.port\s*=\s*[0-9]+' | grep -oE '[0-9]+$' || true)"
  [ -z "$p" ] && p="$(cat "$dir"/src/main/resources/application*.y*ml "$dir"/application*.y*ml 2>/dev/null | grep -m1 -oE '^\s*port:\s*[0-9]+' | grep -oE '[0-9]+$' || true)"
  [ -z "$p" ] && p="$(grep -m1 -oE '^EXPOSE [0-9]+' "$dir/Dockerfile" 2>/dev/null | grep -oE '[0-9]+$' || true)"
  printf '%s' "${p:-$def}"
}

node_script() {  # node_script <package.json> <name> — 0 if the script exists
  grep -qE "^\s*\"$2\"\s*:" <(sed -n '/"scripts"/,/}/p' "$1")
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
  elif [ -f "$dir/go.mod" ]; then
    lang="Go"; manifest="go.mod"; port=8080; start="go run ."; install="go mod download"
    if   has 'gin-gonic/gin' "$dir/go.mod"; then fw="Gin"
    elif has 'labstack/echo' "$dir/go.mod"; then fw="Echo"
    elif has 'gofiber/fiber' "$dir/go.mod"; then fw="Fiber"
    elif has 'go-chi/chi' "$dir/go.mod"; then fw="Chi"
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
  port="$(detect_port "$dir" "$port")"
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

  local rows="" r det n rel
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    det="$(detect_stack "$r")" || { log "skip $r — no recognised manifest (add it to spechub.conf by hand if it is a service)"; continue; }
    n="$(kebab "$(basename "$r")")"
    rel="$r"; case "$r" in "$root"/*) rel="${r#$root/}" ;; esac
    # name|dir|start|port|label|group|install|lang|framework
    rows="$rows
$n|$rel|$(printf '%s' "$det" | cut -d'|' -f4)|$(printf '%s' "$det" | cut -d'|' -f6)|$(basename "$r") ($(printf '%s' "$det" | cut -d'|' -f2))|$(printf '%s' "$det" | cut -d'|' -f3)|$(printf '%s' "$det" | cut -d'|' -f5)"
    log "$n → $(printf '%s' "$det" | cut -d'|' -f2) [$(printf '%s' "$det" | cut -d'|' -f3)] port $(printf '%s' "$det" | cut -d'|' -f6)"
  done <<EOF
$repos
EOF
  [ -n "$(printf '%s' "$rows" | tr -d '\n ')" ] || die "No service detected."
  # Spec order: frontends, then backends, then static — each alphabetical. This order is the spec numbering.
  local ordered
  ordered="$( { printf '%s\n' "$rows" | awk -F'|' '$6=="frontend"' | sort; printf '%s\n' "$rows" | awk -F'|' '$6=="backend"' | sort; printf '%s\n' "$rows" | awk -F'|' '$6=="static"' | sort; } | grep '|' )"
  local base; base="$(pick_base_branch $(printf '%s\n' "$repos" | tr '\n' ' '))"

  {
    printf '# spechub.conf — project, repos, and how to run them. Generated by scripts/bootstrap.sh init on %s.\n' "$(date '+%Y-%m-%d')"
    printf '# Plain bash, sourced by every script in scripts/. Edit freely: fix commands, ports, groups; reorder to change spec numbering.\n\n'
    printf 'PROJECT_NAME="%s"\n\n' "$name"
    printf '# Base branch feature branches are cut from and merged back into.\nBASE_BRANCH="%s"\n\n' "$base"
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
  1. Review spechub.conf: delete repos that are not services (old copies, scripts), fix commands/ports/groups,
     reorder the rows (order = spec numbering). Then 'scripts/stack.sh start' to check the stack runs.
  2. Open Claude Code in this folder on Sonnet and run:  /bootstrap-specs
     It writes the service specs, the architecture overview, CONVENTIONS.md, STATUS.md and repo-instructions/
     from the fact sheets in bootstrap/facts/ (Step 0 of WORKFLOW.md).
EOF
}

# ---------------------------------------------------------------------------
# services table in CLAUDE.md
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
  [ -f "$CLAUDE_MD" ] || die "CLAUDE.md not found in $HUB_DIR"
  grep -q '<!-- services:start -->' "$CLAUDE_MD" || die "CLAUDE.md has no <!-- services:start --> marker"
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
  ' "$CLAUDE_MD" > "$tmp" && mv "$tmp" "$CLAUDE_MD"
  log "updated the services table in CLAUDE.md"
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

facts_modules() {  # facts_modules <dir> → "name|files" for each immediate child of the source root (dirs only)
  local dir="$1" sr; sr="$(source_root "$dir")"
  local d
  for d in "$dir/$sr"/*/; do
    [ -d "$d" ] || continue
    local b; b="$(basename "$d")"
    case " $PRUNE_DIRS " in *" $b "*) continue ;; esac
    local n; n="$(count_src "$d")"
    if [ "$n" -gt 0 ]; then printf '%s|%s\n' "${sr#./}/$b" "$n" | sed 's#^/##'; fi
  done | sort
  return 0
}

ROUTE_RE='@(Get|Post|Put|Patch|Delete|Head|Options|All|Controller)\(|@(Get|Post|Put|Patch|Delete|Request)Mapping|\b(app|router|route|server|r|g|e|api|fastify|http)\.(get|post|put|patch|delete|route|all|use)\(\s*['"'"'"`/]|@(app|router|bp|api|blueprint)\.(get|post|put|patch|delete|route)\(|\[(HttpGet|HttpPost|HttpPut|HttpPatch|HttpDelete|Route)\b|HandleFunc\(|\.(GET|POST|PUT|PATCH|DELETE)\(\s*"|Route::(get|post|put|patch|delete|resource|apiResource)\(|<Route\b|^\s*(path|route):\s*['"'"'"]'
MODEL_RE='@Schema\(|@Entity\b|@Document\b|@Table\(|@Prop\(|@Column\(|class [A-Za-z0-9_]+\((Base|BaseModel|models\.Model|Document|db\.Model)\)|new (mongoose\.)?Schema\(|sequelize\.define\(|^model [A-Za-z0-9_]+ \{|DbSet<|SchemaFactory\.createForClass|class [A-Za-z0-9_]+ < (ApplicationRecord|ActiveRecord::Base)'
ENV_RE='(process\.env\.|process\.env\[.|import\.meta\.env\.|os\.environ\[.|os\.environ\.get\(.|os\.getenv\(.|os\.Getenv\(.|ENV\[.|env\(.|GetEnvironmentVariable\(.|\$\{|Env\.get\(.)[A-Z][A-Z0-9_]{2,}'

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
facts_env() {
  local dir="$1"
  {
    ( cd "$dir" && set -f && grep -rIohE $(prune_args) $(include_args) --include='*.yml' --include='*.yaml' --include='*.properties' --include='*.toml' -e "$ENV_RE" . 2>/dev/null | grep -oE '[A-Z][A-Z0-9_]{2,}$' )
    cat "$dir"/.env.example "$dir"/.env.sample "$dir"/.env.template 2>/dev/null | grep -oE '^[A-Z][A-Z0-9_]+' || true
  } | grep -vE '^(PATH|HOME|NODE_ENV|TZ|JSON)$' | sort -u | head -200
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
  sed -n '/"scripts"/,/}/p' "$1/package.json" | grep -E '^[[:space:]]*"[^"]+"[[:space:]]*:[[:space:]]*"' | sed -E 's/^[[:space:]]*"([^"]+)"[[:space:]]*:[[:space:]]*"(.*)",?[[:space:]]*$/| `\1` | `\2` |/' | sed 's/\\"/"/g'
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
  local sr; sr="$(source_root "$dir")"
  local instr=""; local f
  for f in CLAUDE.md AGENTS.md .github/copilot-instructions.md .cursorrules; do [ -f "$dir/$f" ] && instr="$instr $f"; done
  mkdir -p "$FACTS_DIR"
  {
    printf '# Fact sheet — `%s`\n\n' "$name"
    printf '> Mechanical extraction by `scripts/bootstrap.sh facts` from `%s` @ `%s` (%s). Regenerate, never edit. The bootstrap-specs skill writes the service spec from this sheet plus the files it names.\n\n' "$dir" "$sha" "$branch"
    printf '## 1. Identity\n\n| Field | Value |\n|---|---|\n'
    printf '| Service | `%s` |\n| Label | %s |\n| Group | %s |\n| Repo | `%s` |\n| Remote | `%s` |\n| Branch @ HEAD | `%s` @ `%s` |\n| Start | `%s` |\n| Install | `%s` |\n| Port | %s |\n| Instruction files | %s |\n\n' \
      "$name" "$label" "$group" "$dir" "$remote" "$branch" "$sha" "$start" "$install" "$port" "${instr:-none}"
    printf '## 2. Stack\n\n| Field | Value |\n|---|---|\n| Language | %s |\n| Framework | %s |\n| Manifest | `%s` |\n| Source root | `%s` |\n| Source files | %s |\n\n' "$lang" "$fw" "$manifest" "$sr" "$(count_src "$dir")"
    local scripts; scripts="$(facts_scripts "$dir")"
    if [ -n "$scripts" ]; then printf '### Scripts\n\n| Script | Command |\n|---|---|\n%s\n\n' "$scripts"; fi
    printf '## 3. Layout (depth 3)\n\n```text\n%s\n```\n\n' "$(facts_layout "$dir")"
    printf '## 4. Source Modules (children of `%s`)\n\n| Module | Source files |\n|---|---|\n' "$sr"
    local mods; mods="$(facts_modules "$dir")"
    printf '%s\n' "$mods" | awk -F'|' 'NF {printf "| `%s` | %s |\n", $1, $2}'
    printf '\nModule count: %s\n\n' "$(printf '%s\n' "$mods" | grep -c '|' || true)"
    printf '## 5. Routes & Endpoints\n\n### Declarations (file:line: text)\n\n```text\n%s\n```\n\n' "$(facts_routes "$dir")"
    printf '### Route files (file-system routing, route tables)\n\n```text\n%s\n```\n\n' "$(facts_route_files "$dir")"
    printf '## 6. Data Models\n\n### Model files\n\n```text\n%s\n```\n\n### Declarations (file:line: text)\n\n```text\n%s\n```\n\n' "$(facts_model_files "$dir")" "$(facts_model_decls "$dir")"
    printf '## 7. Environment Variables (referenced)\n\n```text\n%s\n```\n\n' "$(facts_env "$dir")"
    printf '## 8. Dependencies\n\n```text\n%s\n```\n\n' "$(facts_deps "$dir")"
    printf '## 9. Config & Infra Files Present\n\n```text\n%s\n```\n\n' "$(facts_config_files "$dir")"
    printf '## 10. File Counts by Extension\n\n| Ext | Files |\n|---|---|\n%s\n\n' "$(facts_ext_counts "$dir")"
    printf '## 11. Existing Docs\n\n%s\n' "$(facts_readme "$dir")"
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

cmd_plan() {
  load_conf
  printf '%-4s %-22s %-28s %-8s %s\n' "NN" "SERVICE" "SPEC FILE" "MODULES" "SHAPE"
  spec_rows | while IFS='|' read -r nn name dir label group spec; do
    [ "$spec" = "-" ] && continue
    local mods="?" shape="single file"
    if [ -f "$FACTS_DIR/$name.md" ]; then
      mods="$(sed -n 's/^Module count: //p' "$FACTS_DIR/$name.md" | head -1)"
      [ "${mods:-0}" -gt "$SPLIT_THRESHOLD" ] 2>/dev/null && shape="split: index + ${spec%.md}/ (00-core.md, 01-conventions.md, one file per module)"
    else
      shape="(no fact sheet yet — run: scripts/bootstrap.sh facts)"
    fi
    printf '%-4s %-22s %-28s %-8s %s\n' "$nn" "$name" "$spec" "$mods" "$shape"
  done
  printf '\nSplit threshold: more than %s source modules (SPECHUB_SPLIT_THRESHOLD). Numbering follows spechub.conf order.\n' "$SPLIT_THRESHOLD"
}

usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

cmd="${1:-}"; shift || true
case "$cmd" in
  init)     cmd_init "$@" ;;
  facts)    cmd_facts "$@" ;;
  plan)     cmd_plan ;;
  services) cmd_services ;;
  install)  "$STACK" install "$@" ;;
  *) usage ;;
esac
