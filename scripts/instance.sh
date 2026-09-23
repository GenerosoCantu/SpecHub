#!/bin/bash
# ---------------------------------------------------------------------------
# instance.sh — create another instance of the whole stack under a new root, on shifted ports
#
#   scripts/instance.sh init  <new-root> <offset> [--no-install] [--no-db]
#                              every step below, in order
#   scripts/instance.sh clone <new-root>            clone the hub and every service repo to the same
#                                                   relative paths (from the local checkouts, so local
#                                                   commits come along; origin re-pointed at the real remote)
#   scripts/instance.sh conf  <new-root> <offset>   write the new hub's spechub.local.conf: PORT_OFFSET and
#                                                   the instance's own mongod (a `mongodb` static service)
#   scripts/instance.sh env   <new-root> <offset>   copy each repo's gitignored env files (WORKTREE_COPY_FILES),
#                                                   shifting every localhost:<known port> and PORT=<known port>
#   scripts/instance.sh files <new-root> <offset>   copy the static servers' folders, shifting localhost ports
#                                                   inside their text files
#   scripts/instance.sh install <new-root>          run every install command from the new hub
#   scripts/instance.sh db    <new-root> <offset> [--force]
#                                                   start the new mongod, copy every database named by a
#                                                   MONGO_URI* in the env files, shift localhost ports inside
#                                                   the documents (tenant urls, allowed origins, content).
#                                                   --force re-copies over databases that already hold data
#   scripts/instance.sh ports [<offset>]            print the port map of this instance (and of <offset>)
#   scripts/instance.sh pull [--rebase] [--no-install]
#                                                   bring THIS instance up to date: fast-forward the hub and every
#                                                   service repo to origin (each on its current branch), reinstall
#                                                   dependencies whose manifests changed, and list the running
#                                                   services to restart. --rebase replays local commits on origin
#                                                   when a checkout has diverged (clean trees only). Run it before
#                                                   starting a workflow step — the other instances push to origin.
#   scripts/instance.sh sync [--no-push] [--rebase] [--no-install]
#                                                   pull, for a hub the session hooks keep dirtying: commit the
#                                                   hub's metrics/ledger.jsonl alone (the lines the SessionEnd hook
#                                                   appended after your last commit), merge origin into the hub
#                                                   (the ledger merges as a union; other uncommitted edits are
#                                                   stashed around the merge), push the hub, then pull every
#                                                   service repo as above. A real conflict aborts the merge and
#                                                   leaves the hub as it was. Ends with scripts/lock.sh check: two
#                                                   features holding one spec file is reported, never resolved here.
#
# Run init..ports from the hub of the SOURCE instance; run pull from the hub of the instance to update.
# A port here is a spechub.conf port plus an offset: this hub's PORT_OFFSET (its spechub.local.conf,
# 0 when absent) for the source, <offset> for the new instance. MongoDB counts as one more port
# (MONGO_PORT, default 27017). Only ports in that set are shifted, only on localhost / 127.0.0.1.
# Nothing in the source instance is written; the db step refuses to run when source and target
# mongod are the same.
# Afterwards the new instance is driven from its own hub: <new-root>/<hub path>/scripts/stack.sh start.
# ---------------------------------------------------------------------------
set -euo pipefail

HUB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="$HUB_DIR/spechub.conf"
STACK="$HUB_DIR/scripts/stack.sh"
[ -f "$CONF" ] || { echo "spechub.conf not found in $HUB_DIR" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"
# shellcheck disable=SC1091
[ -f "$HUB_DIR/spechub.local.conf" ] && . "$HUB_DIR/spechub.local.conf"
SRC_OFFSET="${PORT_OFFSET:-0}"
MONGO_BASE="${MONGO_PORT:-27017}"
COPY_FILES="${WORKTREE_COPY_FILES:-.env .env.*}"
SRC_ROOT="$(cd "$("$STACK" root)" && pwd -P)"
HUB_GIT="$(cd "$(git -C "$HUB_DIR" rev-parse --show-toplevel)" && pwd -P)"
HUB_SUB="${HUB_DIR#$HUB_GIT}"; HUB_SUB="${HUB_SUB#/}"   # hub folder inside its git repo ("" = repo root)

log()  { printf '[instance] %s\n' "$*" >&2; }
die()  { printf '[instance] ERROR: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; }

# --- ports --------------------------------------------------------------------
base_ports() {  # every numeric spechub.conf port plus MongoDB, unique
  { printf '%s\n' "$SERVICES" | grep -v '^[[:space:]]*#' | grep '|' | cut -d'|' -f4; echo "$MONGO_BASE"; } \
    | grep -E '^[0-9]+$' | sort -n -u
}
src_ports() { base_ports | while read -r p; do echo $((p + SRC_OFFSET)); done | tr '\n' ' '; }

check_offset() {
  case "$1" in ''|*[!0-9]*) die "offset must be a non-negative integer (got '$1')" ;; esac
  [ "$1" != "$SRC_OFFSET" ] || die "offset $1 is this instance's own PORT_OFFSET — pick another (e.g. 10000)"
  local max; max="$(base_ports | tail -1)"
  [ $((max + $1)) -le 65535 ] || die "offset $1 pushes port $max past 65535"
  local p; for p in $(base_ports); do
    case " $(base_ports | while read -r q; do echo $((q + SRC_OFFSET)); done | tr '\n' ' ') " in
      *" $((p + $1)) "*) die "offset $1 maps port $p onto a port this instance uses ($((p + $1)))" ;;
    esac
  done
}

# In-place rewrite of one file: localhost:<src port> / 127.0.0.1:<src port> and PORT=<src port> shift by DELTA.
# Prints the number of replacements.
shift_ports() {  # shift_ports <file> <delta>
  PORTS="$(src_ports)" DELTA="$2" perl -pi -e '
    BEGIN { %p = map { $_ => 1 } split " ", $ENV{PORTS}; $d = $ENV{DELTA}; $n = 0 }
    s{\b(localhost|127\.0\.0\.1):(\d+)(?!\d)}{ exists $p{$2} ? do { $n++; "$1:" . ($2 + $d) } : "$1:$2" }ge;
    s{^(\s*(?:export\s+)?PORT\s*=\s*["\x27]?)(\d+)(?!\d)}{ exists $p{$2} ? do { $n++; $1 . ($2 + $d) } : "$1$2" }e;
    END { print STDERR "$n\n" }
  ' "$1" 2>&1 >/dev/null | tail -1
}

# --- arguments -----------------------------------------------------------------
new_root() {  # absolute, created, and not the source root or inside it
  [ -n "${1:-}" ] || die "missing <new-root>"
  mkdir -p "$1"
  local r; r="$(cd "$1" && pwd -P)"
  case "$r/" in "$SRC_ROOT/"*) die "new root $r is the source root or inside it ($SRC_ROOT)" ;; esac
  case "$SRC_ROOT/" in "$r/"*) die "new root $r contains the source root ($SRC_ROOT)" ;; esac
  echo "$r"
}
rel_to_src() {  # path relative to the source root; dies when outside it
  case "$1" in "$SRC_ROOT"/*) echo "${1#$SRC_ROOT/}" ;; *) die "$1 is not under REPOS_ROOT ($SRC_ROOT) — move it there or clone it by hand" ;; esac
}
new_hub() { printf '%s/%s%s\n' "$1" "$(rel_to_src "$HUB_GIT")" "${HUB_SUB:+/$HUB_SUB}"; }

# name|dir|kind|git-root|path-in-repo|git-root-rel, from stack.sh (realpaths)
repos_table() { "$STACK" repos; }
git_roots() { { echo "$HUB_GIT"; repos_table | cut -d'|' -f4; } | while read -r g; do (cd "$g" 2>/dev/null && pwd -P) || true; done | awk 'NF && !seen[$0]++'; }

# --- steps ---------------------------------------------------------------------
cmd_clone() {
  local root; root="$(new_root "${1:-}")"
  local g rel dest branch url
  # The new hub must carry the same scripts and service table, so those must be committed.
  if [ -n "$(git -C "$HUB_GIT" status --porcelain -- "${HUB_SUB:-.}/scripts" "${HUB_SUB:-.}/spechub.conf" 2>/dev/null)" ]; then
    [ "${INSTANCE_ALLOW_DIRTY:-0}" = 1 ] && log "WARNING: hub scripts/ or spechub.conf uncommitted — the new hub gets the committed state" || \
    die "the hub has uncommitted changes in scripts/ or spechub.conf — commit them first, the new hub is cloned from the committed state"
  fi
  for g in $(git_roots); do
    rel="$(rel_to_src "$g")"; dest="$root/$rel"
    if [ -e "$dest/.git" ]; then log "$rel — already cloned, skipped"; continue; fi
    branch="$(git -C "$g" branch --show-current)"
    [ -n "$branch" ] || die "$g is on a detached HEAD — check out a branch first"
    url="$(git -C "$g" remote get-url origin 2>/dev/null || true)"
    mkdir -p "$(dirname "$dest")"
    git clone --quiet --branch "$branch" "$g" "$dest"
    if [ -n "$url" ]; then
      git -C "$dest" remote set-url origin "$url"
      if git -C "$dest" fetch --quiet origin 2>/dev/null; then
        if git -C "$dest" rev-parse --verify --quiet "origin/$branch" >/dev/null; then git -C "$dest" branch --quiet --set-upstream-to="origin/$branch" "$branch"; fi
      else
        log "$rel — could not fetch $url (offline?); origin set, fetch later"
      fi
    fi
    log "$rel — cloned on $branch${url:+ (origin $url)}"
    [ -z "$(git -C "$g" status --porcelain --untracked-files=no 2>/dev/null)" ] || log "  note: uncommitted changes in the source checkout were not copied"
  done
}

cmd_conf() {
  local root off hub file; root="$(new_root "${1:-}")"; off="${2:-}"; check_offset "$off"
  hub="$(new_hub "$root")"; [ -f "$hub/spechub.conf" ] || die "no hub at $hub — run: $0 clone $root"
  file="$hub/spechub.local.conf"
  {
    printf '# spechub.local.conf — overrides for this instance of the stack (gitignored). Written by scripts/instance.sh on %s.\n' "$(date '+%Y-%m-%d')"
    printf '# Every spechub.conf port is shifted by PORT_OFFSET; stack.sh passes the shifted port as PORT and {port}.\n'
    printf 'PORT_OFFSET="%s"\n' "$off"
    if [ "$off" != 0 ]; then
      printf '\n# This instance'"'"'s own MongoDB on %s + PORT_OFFSET, data in <root>/.mongo/db. It starts with the static tier.\n' "$MONGO_BASE"
      printf 'SERVICES="$SERVICES\nmongodb|.mongo|mongod --port {port} --bind_ip 127.0.0.1 --dbpath db|%s|MongoDB for this instance|static|-\n"\n' "$MONGO_BASE"
    fi
  } > "$file"
  mkdir -p "$root/.mongo/db"
  log "wrote $file (PORT_OFFSET=$off)"
}

cmd_env() {
  local root off delta; root="$(new_root "${1:-}")"; off="${2:-}"; check_offset "$off"; delta=$((off - SRC_OFFSET))
  local name dir kind pat f rel dest n
  while IFS='|' read -r name dir kind _; do
    [ "$kind" = code ] || continue
    rel="$(rel_to_src "$(cd "$dir" && pwd -P)")"; dest="$root/$rel"
    [ -d "$dest" ] || { log "$name — $dest missing, skipped (run clone first)"; continue; }
    for pat in $COPY_FILES; do
      for f in "$dir"/$pat; do
        [ -f "$f" ] || continue
        git -C "$dir" ls-files --error-unmatch "$(basename "$f")" >/dev/null 2>&1 && continue   # tracked: the clone has it
        cp -p "$f" "$dest/"
        n="$(shift_ports "$dest/$(basename "$f")" "$delta")"
        log "$name — $(basename "$f") ($n port reference(s) shifted)"
      done
    done
  done < <(repos_table)
}

cmd_files() {
  local root off delta; root="$(new_root "${1:-}")"; off="${2:-}"; check_offset "$off"; delta=$((off - SRC_OFFSET))
  local name dir kind rel dest f files total
  while IFS='|' read -r name dir kind _; do
    [ "$kind" = static ] || continue
    [ -d "$dir" ] || continue
    dir="$(cd "$dir" && pwd -P)"
    case "$dir" in "$SRC_ROOT"/*) ;; *) continue ;; esac
    case "$dir" in "$SRC_ROOT"/.mongo|"$SRC_ROOT"/.mongo/*) continue ;; esac   # an instance's own mongod data
    rel="$(rel_to_src "$dir")"; dest="$root/$rel"
    mkdir -p "$dest"
    rsync -a "$dir/" "$dest/"
    files=0; total=0
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      files=$((files + 1)); total=$((total + $(shift_ports "$f" "$delta")))
    done < <(grep -rlIE '(localhost|127\.0\.0\.1):[0-9]+' "$dest" 2>/dev/null || true)
    log "$name — copied $(du -sh "$dest" | cut -f1) to $rel ($total port reference(s) shifted in $files file(s))"
  done < <(repos_table)
}

cmd_install() {
  local root hub; root="$(new_root "${1:-}")"; hub="$(new_hub "$root")"
  [ -x "$hub/scripts/stack.sh" ] || die "no hub at $hub — run: $0 clone $root"
  "$hub/scripts/stack.sh" install
}

mongo_ping() { mongosh --quiet --host 127.0.0.1 --port "$1" --eval 'db.runCommand({ping:1}).ok' >/dev/null 2>&1; }

cmd_db() {
  local root off force=0 a; root="$(new_root "${1:-}")"; off="${2:-}"; check_offset "$off"; shift 2 || true
  for a in "$@"; do case "$a" in --force) force=1 ;; *) die "unknown option $a" ;; esac; done
  local sport tport hub dbs d
  sport=$((MONGO_BASE + SRC_OFFSET)); tport=$((MONGO_BASE + off))
  [ "$sport" != "$tport" ] || die "source and target MongoDB are both on port $sport — refusing to write to the source"
  for d in mongosh mongodump mongorestore; do command -v "$d" >/dev/null || die "$d not found (brew install mongodb-database-tools mongosh)"; done
  mongo_ping "$sport" || die "source MongoDB is not answering on port $sport"

  # Databases: the path of every MONGO_URI* pointing at the source mongod, in the source env files.
  dbs="$(repos_table | while IFS='|' read -r _ dir kind _; do
      [ "$kind" = code ] || continue
      for pat in $COPY_FILES; do for f in "$dir"/$pat; do if [ -f "$f" ]; then cat "$f"; fi; done; done
    done | sed -nE "s#^[[:space:]]*MONGO_URI[A-Za-z_]*[[:space:]]*=[[:space:]]*[\"']?mongodb://([^@/]*@)?(localhost|127\\.0\\.0\\.1):$sport/([A-Za-z0-9_-]+).*#\\3#p" | sort -u | tr '\n' ' ')" || true
  [ -n "$(echo "$dbs" | tr -d ' ')" ] || die "no MONGO_URI on port $sport found in the env files"
  log "databases: $dbs"

  if ! mongo_ping "$tport"; then
    hub="$(new_hub "$root")"
    [ -x "$hub/scripts/stack.sh" ] || die "nothing on port $tport and no hub at $hub to start it"
    "$hub/scripts/stack.sh" start mongodb >&2
    local i=0; until mongo_ping "$tport"; do i=$((i + 1)); [ "$i" -lt 30 ] || die "MongoDB did not come up on port $tport — see $hub/.logs/mongodb.log"; sleep 1; done
  fi

  for d in $dbs; do
    if [ "$force" = 0 ] && [ "$(mongosh --quiet --host 127.0.0.1 --port "$tport" --eval "db.getSiblingDB('$d').getCollectionNames().length")" != 0 ]; then
      die "database $d on port $tport already holds data — re-run with --force to replace it with a fresh copy"
    fi
  done
  for d in $dbs; do
    mongodump --quiet --host 127.0.0.1 --port "$sport" --db "$d" --archive \
      | mongorestore --quiet --host 127.0.0.1 --port "$tport" --archive --drop --nsInclude "$d.*"
    log "copied $d ($sport → $tport)"
  done

  local js; js="$(mktemp -t instance-db.XXXXXX)"; mv "$js" "$js.js"; js="$js.js"
  cat > "$js" <<EOF
const PORTS = new Set([$(src_ports | tr ' ' ',' | sed 's/,$//')]);
const DELTA = $((off - SRC_OFFSET));
const DBS = [$(for d in $dbs; do printf "'%s'," "$d"; done | sed 's/,$//')];
EOF
  cat >> "$js" <<'EOF'
const re = /\b(localhost|127\.0\.0\.1):(\d+)(?!\d)/g;
function fix(v, st) {
  if (typeof v === 'string') return v.replace(re, (m, h, p) => PORTS.has(+p) ? (st.n++, h + ':' + (+p + DELTA)) : m);
  if (Array.isArray(v)) return v.map(x => fix(x, st));
  // Plain objects only: documents come from another realm, so compare the constructor by name; BSON values carry _bsontype.
  if (v && typeof v === 'object' && !v._bsontype && Object.prototype.toString.call(v) === '[object Object]'
      && (!v.constructor || v.constructor.name === 'Object')) {
    const o = {}; for (const k of Object.keys(v)) o[k] = fix(v[k], st); return o;
  }
  return v;   // ObjectId, Date, numbers, binary … untouched
}
for (const d of DBS) {
  const x = db.getSiblingDB(d);
  for (const info of x.getCollectionInfos({ type: 'collection' })) {
    const c = info.name; if (c.startsWith('system.')) continue;
    let docs = 0, hits = 0;
    try {
      x.getCollection(c).find().forEach(doc => {
        const st = { n: 0 }; const nd = fix(doc, st);
        if (st.n) { x.getCollection(c).replaceOne({ _id: doc._id }, nd); docs++; hits += st.n; }
      });
    } catch (e) { print(`  ${d}.${c}: skipped (${e.message})`); continue; }
    if (docs) print(`  ${d}.${c}: ${hits} port reference(s) shifted in ${docs} document(s)`);
  }
}
EOF
  log "shifting localhost ports inside the copied documents"
  mongosh --quiet --host 127.0.0.1 --port "$tport" "$js" >&2
  rm -f "$js"
}

cmd_ports() {
  local off="${1:-}"
  printf '%-26s %-6s %-8s %s\n' SERVICE BASE "THIS(+$SRC_OFFSET)" "${off:+NEW(+$off)}"
  { printf '%s\n' "$SERVICES" | grep -v '^[[:space:]]*#' | grep '|' | cut -d'|' -f1,4; echo "mongodb|$MONGO_BASE"; } | awk -F'|' '!seen[$1]++' \
    | while IFS='|' read -r n p; do
        case "$p" in ''|*[!0-9]*) continue ;; esac
        printf '%-26s %-6s %-8s %s\n' "$n" "$p" $((p + SRC_OFFSET)) "${off:+$((p + ${off:-0}))}"
      done
}

# pull [--rebase] [--no-install] — every git root of this instance (hub first) to origin/<its branch>.
# Never merges: a checkout is fast-forwarded, rebased on request, or reported and left untouched.
cmd_pull() {
  local rebase=0 install=1 a g rel branch before behind ahead how changed
  local moved="" failed="" restart="" envs="" n
  for a in "$@"; do case "$a" in --rebase) rebase=1 ;; --no-install) install=0 ;; *) die "unknown option $a" ;; esac; done
  for g in $(git_roots); do
    case "$g" in "$SRC_ROOT"/*) rel="${g#$SRC_ROOT/}" ;; *) rel="$g" ;; esac
    branch="$(git -C "$g" branch --show-current)"
    [ -n "$branch" ] || { log "$rel — detached HEAD, skipped"; failed="$failed $rel"; continue; }
    git -C "$g" remote get-url origin >/dev/null 2>&1 || { log "$rel — no origin remote, skipped"; continue; }
    if ! git -C "$g" fetch --quiet origin "$branch" 2>/dev/null; then
      log "$rel — could not fetch origin/$branch (offline?), skipped"; failed="$failed $rel"; continue
    fi
    git -C "$g" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null \
      || { log "$rel — origin has no '$branch', skipped"; continue; }
    behind="$(git -C "$g" rev-list --count "$branch..origin/$branch")"
    ahead="$(git -C "$g" rev-list --count "origin/$branch..$branch")"
    if [ "$behind" = 0 ]; then
      log "$rel — up to date on $branch$( [ "$ahead" = 0 ] || echo " ($ahead local commit(s) not pushed)")"; continue
    fi
    before="$(git -C "$g" rev-parse HEAD)"
    if [ "$ahead" = 0 ]; then
      git -C "$g" merge --ff-only --quiet "origin/$branch" \
        || { log "$rel — fast-forward refused (uncommitted changes in the way?) — left as it was"; failed="$failed $rel"; continue; }
      how="fast-forwarded"
    elif [ "$rebase" = 1 ]; then
      [ -z "$(git -C "$g" status --porcelain --untracked-files=no)" ] \
        || { log "$rel — diverged and has uncommitted changes: commit or stash, then rerun with --rebase"; failed="$failed $rel"; continue; }
      if ! git -C "$g" rebase --quiet "origin/$branch" >/dev/null 2>&1; then
        git -C "$g" rebase --abort >/dev/null 2>&1 || true
        log "$rel — rebase on origin/$branch conflicts; aborted, left as it was. Resolve by hand: git -C $g pull --rebase"
        failed="$failed $rel"; continue
      fi
      how="rebased ($ahead local commit(s) replayed)"
    else
      log "$rel — diverged from origin/$branch ($ahead local, $behind remote commit(s)): rerun with --rebase"; failed="$failed $rel"; continue
    fi
    log "$rel — $how on $branch: $behind new commit(s)"
    moved="$moved $rel"
    [ "$g" = "$HUB_GIT" ] && continue
    changed="$(git -C "$g" diff --name-only "$before" HEAD)"
    # Env files are per-instance copies (the env step): a changed template means a key to add by hand.
    printf '%s\n' "$changed" | grep -Eq '(^|/)\.env[^/]*$' && envs="$envs $rel"
    [ "$install" = 1 ] && "$HUB_DIR/scripts/dispatch.sh" deps "$g" "$before" >/dev/null
    for n in $("$STACK" service-for "$g" 2>/dev/null); do
      "$STACK" is-running "$n" >/dev/null 2>&1 && restart="$restart $n"
    done
  done
  [ -n "$moved$failed" ] || log "nothing to pull — every checkout matches origin"
  [ -z "$restart" ] || log "running on code that changed — restart them: scripts/stack.sh restart$restart"
  [ -z "$envs" ] || log "env templates changed in:$envs — this instance's env files are copies; add the new keys by hand (shift localhost ports by PORT_OFFSET)"
  [ "$install" = 1 ] || [ -z "$moved" ] || log "dependencies not checked (--no-install): scripts/stack.sh install <names> if a manifest changed"
  [ -z "$failed" ] || die "not updated:$failed"
}

# sync [--no-push] [--rebase] [--no-install] — the hub merged with origin and pushed, then pull for the rest.
# The ledger is the only file committed on your behalf: it is written by the session hooks, never by hand.
cmd_sync() {
  local push=1 a branch ledger ahead behind pass=()
  for a in "$@"; do case "$a" in --no-push) push=0 ;; --rebase|--no-install) pass+=("$a") ;; *) die "unknown option $a" ;; esac; done
  branch="$(git -C "$HUB_GIT" branch --show-current)"
  [ -n "$branch" ] || die "the hub is on a detached HEAD — check out a branch first"
  [ -z "$(git -C "$HUB_GIT" diff --name-only --diff-filter=U)" ] || die "the hub has unresolved conflicts — resolve them first"
  git -C "$HUB_GIT" remote get-url origin >/dev/null 2>&1 || die "the hub has no origin remote"
  git -C "$HUB_GIT" fetch --quiet origin "$branch" || die "could not fetch origin/$branch (offline?)"

  # 1. The ledger: record any transcript the hooks missed, then commit the file alone.
  "$HUB_DIR/scripts/metrics.sh" sync --quiet >/dev/null 2>&1 || true
  ledger="${HUB_SUB:+$HUB_SUB/}metrics/ledger.jsonl"
  if [ -n "$(git -C "$HUB_GIT" status --porcelain -- "$ledger")" ]; then
    git -C "$HUB_GIT" commit --quiet -m "metrics: hub sessions" -- "$ledger"
    log "hub — committed the ledger ($ledger)"
  fi
  [ -z "$(git -C "$HUB_GIT" status --porcelain --untracked-files=no)" ] \
    || log "hub — other uncommitted edits stay uncommitted (stashed around the merge): $(git -C "$HUB_GIT" status --porcelain --untracked-files=no | awk '{print $2}' | paste -sd' ' -)"

  # 2. Merge origin (a merge, not a rebase: nothing already pushed is rewritten).
  behind="$(git -C "$HUB_GIT" rev-list --count "$branch..origin/$branch")"
  if [ "$behind" != 0 ]; then
    if ! git -C "$HUB_GIT" merge --quiet --autostash --no-edit "origin/$branch" >/dev/null 2>&1; then
      local conflicts; conflicts="$(git -C "$HUB_GIT" diff --name-only --diff-filter=U | paste -sd' ' -)"
      git -C "$HUB_GIT" merge --abort >/dev/null 2>&1 || true
      die "hub — merging origin/$branch conflicts in: ${conflicts:-?} — aborted, left as it was. Resolve by hand: git -C $HUB_GIT pull"
    fi
    log "hub — merged $behind commit(s) from origin/$branch"
  fi

  # 3. Push. A rejected push means another instance pushed in between: merge once more and retry.
  ahead="$(git -C "$HUB_GIT" rev-list --count "origin/$branch..$branch")"
  if [ "$ahead" = 0 ]; then
    log "hub — nothing to push"
  elif [ "$push" = 0 ]; then
    log "hub — $ahead commit(s) not pushed (--no-push)"
  else
    local try
    for try in 1 2 3; do
      if git -C "$HUB_GIT" push --quiet origin "$branch" 2>/dev/null; then log "hub — pushed $ahead commit(s) to origin/$branch"; break; fi
      [ "$try" != 3 ] || die "hub — push to origin/$branch rejected three times — run: git -C $HUB_GIT pull && git -C $HUB_GIT push"
      git -C "$HUB_GIT" fetch --quiet origin "$branch" || die "hub — push rejected and origin unreachable"
      git -C "$HUB_GIT" merge --quiet --autostash --no-edit "origin/$branch" >/dev/null 2>&1 || {
        git -C "$HUB_GIT" merge --abort >/dev/null 2>&1 || true
        die "hub — push rejected, and merging the newer origin/$branch conflicts — resolve by hand: git -C $HUB_GIT pull"
      }
      ahead="$(git -C "$HUB_GIT" rev-list --count "origin/$branch..$branch")"
    done
  fi

  # 4. The service repos (the hub now matches origin, so pull reports it up to date).
  cmd_pull ${pass[@]+"${pass[@]}"}

  # 5. Spec locks: a collision (two features holding one spec file) is reported, not fixed here.
  [ -x "$HUB_DIR/scripts/lock.sh" ] && { "$HUB_DIR/scripts/lock.sh" check || log "hub — spec locks collide (above): the holders decide who yields"; }
  return 0
}

cmd_init() {
  local root off install=1 db=1 a; root="$(new_root "${1:-}")"; off="${2:-}"; check_offset "$off"; shift 2 || true
  for a in "$@"; do case "$a" in --no-install) install=0 ;; --no-db) db=0 ;; *) die "unknown option $a" ;; esac; done
  log "new instance at $root, ports +$off (this one: +$SRC_OFFSET)"
  cmd_clone "$root"
  cmd_conf "$root" "$off"
  cmd_env "$root" "$off"
  cmd_files "$root" "$off"
  if [ "$install" = 1 ]; then cmd_install "$root"; fi
  if [ "$db" = 1 ]; then cmd_db "$root" "$off"; fi
  local hub; hub="$(new_hub "$root")"
  cmd_ports "$off" >&2
  cat >&2 <<EOF

[instance] Done. Drive the new instance from its own hub:
  cd $hub
  scripts/stack.sh start        # its mongod first, then the services on +$off
  scripts/stack.sh list         # URLs
$( [ "$install" = 1 ] || echo "  (dependencies not installed: scripts/stack.sh install)" )$( [ "$db" = 1 ] || echo "  (databases not copied: $0 db $root $off)" )
Both instances push to the same remotes. Before each workflow step, bring an instance up to date with
  scripts/instance.sh sync        # commit the ledger, merge + push the hub, fast-forward every service repo
Feature numbers are claimed through origin by scripts/status.sh claim (Step 2) and spec files by scripts/lock.sh claim
(Step 1), so two instances never take the same number or design against the same spec at once.
EOF
}

case "${1:-help}" in
  init)    shift; cmd_init "$@" ;;
  clone)   shift; cmd_clone "$@" ;;
  conf)    shift; cmd_conf "$@" ;;
  env)     shift; cmd_env "$@" ;;
  files)   shift; cmd_files "$@" ;;
  install) shift; cmd_install "$@" ;;
  db)      shift; cmd_db "$@" ;;
  ports)   shift; cmd_ports "$@" ;;
  pull)    shift; cmd_pull "$@" ;;
  sync)    shift; cmd_sync "$@" ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
