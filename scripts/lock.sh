#!/usr/bin/env bash
# scripts/lock.sh — spec locks (LOCKS.md): who is designing against, or holding, which spec file.
#
#   scripts/lock.sh intend <feature> <spec>... [--by "<name>"] [--note "<one line>"] [--no-push]
#                                    Step 1, the design session's first action: post that <feature> — the kebab
#                                    name of Features/FEATURE-<feature>.md or BUG-<feature>.md — is being
#                                    designed against these spec files or services (coarse is fine). A notice,
#                                    not a lock: it WARNS about every overlapping row, refuses nothing, and is
#                                    pushed to origin as its own commit so every instance sees it. Idempotent.
#   scripts/lock.sh claim <feature> <spec>... [--by "<name>"] [--note "<one line>"] [--no-push]
#                                    Step 2a, before any spec edit (run by the cascade skill): HOLD the exact
#                                    spec / module files the cascade edits. Upgrades the feature's intent row
#                                    (its coarse files are replaced by these), or extends an existing hold.
#                                    Refuses when another feature HOLDS one of them; only warns when another
#                                    feature is merely designing against it (that design must be re-validated).
#   scripts/lock.sh release <feature> [--no-push]
#                                    Step 4 (close-out), staling, or an abandoned design: drop the row. Close-out
#                                    passes --no-push so the release travels with the close-out commit — after
#                                    the reconciled spec reaches origin, never before it.
#   scripts/lock.sh check [<spec>...] [--feature <feature>]
#                                    no spec: fail when two HELD rows share a file, here or against the last
#                                    fetch of origin; warn on intent/hold and intent/intent overlaps, on rows
#                                    older than LOCK_STALE_DAYS (default 14), and on rows whose feature file is
#                                    already in Features/Implemented or Staled. With specs: fail when one is
#                                    held by a feature other than --feature; warn when one is being designed.
#   scripts/lock.sh list             print the board, refreshed from origin
#
# A <spec> is a hub path — `07-api/stories.md` (one module), `07-api.md` or `07-api/` (the whole service,
# single-file or split), `CONVENTIONS.md`, `00-architecture-overview.md` — or a service name from
# spechub.conf (`api` → `07-api.md`; `api/stories` → `07-api/stories.md`). A whole-service row overlaps
# every module row under it and vice versa. A module file that does not exist yet (a new module) can be
# named; its directory must exist.
#
# Why two states: the spec is not touched during design, only from the cascade to close-out — so that is
# the only window where a refusal is justified (a hold). A design can take days and may never be
# cascaded, so design posts an intent instead: visible to everyone, blocking no one, enough to start a
# conversation on day one. Worktrees isolate implementation; this board is what isolates the specs, and
# it is advisory — nothing stops an edit, the skills stop at the check. Rows travel through origin
# exactly like feature numbers (scripts/status.sh claim): fetch, fast-forward the hub, edit, commit
# LOCKS.md alone, push; a rejected push undoes the commit and retries on top of the other instance's row.
# --no-push (or a hub with no origin) edits the board only; `check` catches a collision when the hubs meet.

set -euo pipefail
HUB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCKS="$HUB_DIR/LOCKS.md"
TEMPLATE="$HUB_DIR/templates/LOCKS-TEMPLATE.md"
CONF="$HUB_DIR/spechub.conf"
TRIES="${LOCK_CLAIM_TRIES:-5}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"
STALE_DAYS="${LOCK_STALE_DAYS:-14}"

log() { printf '[lock] %s\n' "$*" >&2; }
die() { printf '[lock] ERROR: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

g() { git -C "$HUB_DIR" "$@"; }
branch() { g branch --show-current; }
has_origin() { g remote get-url origin >/dev/null 2>&1; }
tracked() { g ls-files --error-unmatch -- LOCKS.md >/dev/null 2>&1; }
# origin_locks <file> — write origin's LOCKS.md as of the last fetch; false when there is none
origin_locks() {
  local b; b="$(branch)"; [ -n "$b" ] && has_origin || return 1
  g rev-parse --verify --quiet "refs/remotes/origin/$b" >/dev/null || return 1
  g show "origin/$b:./LOCKS.md" > "$1" 2>/dev/null
}
fetch_quiet() { has_origin && [ -n "$(branch)" ] && g fetch --quiet origin "$(branch)" 2>/dev/null || true; }

# board — every table operation. Usage: board <op> [args] ; reads/writes $LOCKS.
#   rows [file]                            "feature|state|files|by|since|note" per row
#   overlap <feature> <spec>...            "spec|feature|state|by|since|hit files" for every other row overlapping a spec
#   add <feature> <state> <by> <note> <spec>...
#                                          designing: create, or merge files into the existing row (state kept)
#                                          held: create; upgrade a designing row (files REPLACED); or extend a hold
#                                          prints "added <files>" / "held <files>" / "unchanged"
#   remove <feature>                       "removed" / "absent"
#   check <stale-days> [origin-file]       conflicts (held/held: exit 1), overlaps, stale and orphan lines
#   list                                   aligned board
board() { python3 - "$LOCKS" "$HUB_DIR" "$@" <<'PY'
import io, os, re, sys
from datetime import date
LOCKS, HUB, op, args = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
ROW = re.compile(r'^\|\s*`([^`|]+)`\s*\|([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|\s*$')
HELD, DESIGNING = 'held', 'designing'

def read(path):
    if not os.path.exists(path): return [], []
    lines = io.open(path, encoding='utf-8').read().split('\n')
    rows = []
    for i, l in enumerate(lines):
        m = ROW.match(l)
        if not m: continue
        state = m.group(2).strip().strip('*')
        if state not in (HELD, DESIGNING): continue
        files = [f.strip().strip('`') for f in m.group(3).split('·') if f.strip()]
        rows.append({'i': i, 'feature': m.group(1).strip(), 'state': state, 'files': files,
                     'by': m.group(4).strip(), 'since': m.group(5).strip(), 'note': m.group(6).strip()})
    return lines, rows

def fmt(r):
    state = '**held**' if r['state'] == HELD else DESIGNING
    return '| `%s` | %s | %s | %s | %s | %s |' % (r['feature'], state, ' · '.join('`%s`' % f for f in r['files']),
                                                 r['by'], r['since'], r['note'])

def key(p):  # `NN-svc/` and `NN-svc.md` are the same target: the whole service
    return p[:-1] + '.md' if p.endswith('/') else p

def overlaps(a, b):
    a, b = key(a), key(b)
    if a == b: return True
    for x, y in ((a, b), (b, a)):
        if x.endswith('.md') and y.startswith(x[:-3] + '/'): return True
    return False

def write(lines):
    io.open(LOCKS, 'w', encoding='utf-8').write('\n'.join(lines))

def table_end(lines):
    sep = next((i for i, l in enumerate(lines) if re.match(r'^\|\s*-{2,}', l)), None)
    if sep is None: sys.exit('LOCKS.md has no table — restore it from templates/LOCKS-TEMPLATE.md')
    end = sep + 1
    while end < len(lines) and lines[end].startswith('|'): end += 1
    return end

lines, rows = read(LOCKS)

if op == 'rows':
    _, rs = read(args[0]) if args else (lines, rows)
    for r in rs: print('|'.join([r['feature'], r['state'], ' '.join(r['files']), r['by'], r['since'], r['note']]))

elif op == 'overlap':
    feature, specs = args[0], args[1:]
    for s in specs:
        for r in rows:
            if r['feature'] == feature: continue
            hit = [f for f in r['files'] if overlaps(f, s)]
            if hit: print('|'.join([s, r['feature'], r['state'], r['by'], r['since'], ' '.join(hit)]))

elif op == 'add':
    feature, state, by, note, specs = args[0], args[1], args[2], args[3], args[4:]
    specs = [key(s) for s in specs]
    mine = next((r for r in rows if r['feature'] == feature), None)
    if not mine:
        r = {'feature': feature, 'state': state, 'files': specs, 'by': by, 'since': date.today().isoformat(), 'note': note}
        lines.insert(table_end(lines), fmt(r)); write(lines)
        print('%s %s' % ('held' if state == HELD else 'added', ' '.join(specs)))
    elif state == HELD and mine['state'] == DESIGNING:
        mine['state'] = HELD; mine['files'] = specs
        if note: mine['note'] = note
        lines[mine['i']] = fmt(mine); write(lines); print('held ' + ' '.join(specs))
    else:
        new = [s for s in specs if not any(key(f) == s for f in mine['files'])]
        if not new and (not note or note == mine['note']): print('unchanged'); sys.exit(0)
        mine['files'] += new
        if note: mine['note'] = note
        lines[mine['i']] = fmt(mine); write(lines)
        print('%s %s' % ('held' if mine['state'] == HELD else 'added', ' '.join(new)))

elif op == 'remove':
    mine = next((r for r in rows if r['feature'] == args[0]), None)
    if not mine: print('absent'); sys.exit(0)
    del lines[mine['i']]
    write(lines); print('removed')

elif op == 'check':
    stale = int(args[0]); bad = 0
    origin = read(args[1])[1] if len(args) > 1 else []
    every = rows + [dict(r, origin=True) for r in origin]
    seen = set()
    for i, a in enumerate(every):
        for b in every[i + 1:]:
            if a['feature'] == b['feature']: continue
            hits = sorted({x for x in a['files'] for y in b['files'] if overlaps(x, y)} |
                          {y for x in a['files'] for y in b['files'] if overlaps(x, y)})
            if not hits: continue
            k = tuple(sorted([a['feature'], b['feature']]))
            if k in seen: continue
            seen.add(k)
            where = ' (on origin)' if b.get('origin') and not a.get('origin') else ''
            who = '`%s` (%s, %s since %s) and `%s` (%s, %s since %s)%s' % (
                a['feature'], a['by'], a['state'], a['since'], b['feature'], b['by'], b['state'], b['since'], where)
            if a['state'] == HELD and b['state'] == HELD:
                bad = 1; print('CONFLICT: %s both hold %s' % (who, ', '.join(hits)))
            elif HELD in (a['state'], b['state']):
                print('OVERLAP: %s — %s; the design must be re-validated once the hold is released'
                      % (who, ', '.join(hits)))
            else:
                print('OVERLAP: %s are both designing against %s — talk before either cascades' % (who, ', '.join(hits)))
    today = date.today()
    for r in rows:
        try: age = (today - date.fromisoformat(r['since'])).days
        except ValueError: age = -1
        gone = [d for d in ('Implemented', 'Staled')
                if any(os.path.exists(os.path.join(HUB, 'Features', d, '%s-%s.md' % (p, r['feature'])))
                       for p in ('FEATURE', 'BUG'))]
        if gone:
            print('ORPHAN: `%s` is in Features/%s/ but still %s %s — release it: scripts/lock.sh release %s'
                  % (r['feature'], gone[0], 'holds' if r['state'] == HELD else 'is designing against',
                     ', '.join(r['files']), r['feature']))
        elif age > stale:
            print('STALE: `%s` (%s) has been %s %s for %d days — still in flight? release it if not'
                  % (r['feature'], r['by'], 'holding' if r['state'] == HELD else 'designing against',
                     ', '.join(r['files']), age))
    sys.exit(bad)

elif op == 'list':
    if not rows: print('(no spec locks)'); sys.exit(0)
    heads = ('FEATURE', 'STATE', 'SPEC FILES', 'BY', 'SINCE')
    cells = [(r['feature'], r['state'], ' '.join(r['files']), r['by'], r['since']) for r in rows]
    w = [max(len(x) for x in col) for col in zip(*([heads] + cells))]
    print('  '.join(h.ljust(n) for h, n in zip(heads, w)) + '  NOTE')
    for c, r in zip(cells, rows):
        print('  '.join(x.ljust(n) for x, n in zip(c, w)) + '  ' + r['note'])
PY
}

# slug <feature> — the kebab name, from a bare slug or a FEATURE-/BUG- file name
slug() {
  local s="$1"; s="${s##*/}"; s="${s%.md}"; s="${s#FEATURE-}"; s="${s#BUG-}"
  case "$s" in ''|*[!a-z0-9-]*|-*) die "feature '$1' is not a kebab name (the {name} of Features/FEATURE-{name}.md)" ;; esac
  printf '%s' "$s"
}

# resolve <spec> — a hub path from a path, a directory, a service name or service/module
resolve() {
  local s="${1%/}" hit svc mod
  s="${s#./}"
  if [ -f "$HUB_DIR/$s" ]; then case "$s" in *.md) printf '%s' "$s"; return ;; *) die "'$s' is not a markdown spec file" ;; esac; fi
  if [ -d "$HUB_DIR/$s" ]; then
    [ -f "$HUB_DIR/$s.md" ] || die "'$s/' is not a split spec directory (no $s.md index)"
    printf '%s.md' "$s"; return
  fi
  case "$s" in
    */*) svc="${s%%/*}"; mod="${s#*/}"; mod="${mod%.md}"
      hit="$(cd "$HUB_DIR" && ls -d [0-9][0-9]-"$svc" 2>/dev/null | head -1)"
      if [ -n "$hit" ]; then
        [ -f "$HUB_DIR/$hit/$mod.md" ] || log "note: $hit/$mod.md does not exist yet — named as a new module"
        printf '%s/%s.md' "$hit" "$mod"; return
      fi
      if [ -d "$HUB_DIR/$svc" ] && [ -f "$HUB_DIR/$svc.md" ]; then
        log "note: $svc/$mod.md does not exist yet — named as a new module"; printf '%s/%s.md' "$svc" "$mod"; return
      fi ;;
    *) hit="$(cd "$HUB_DIR" && ls [0-9][0-9]-"${s%.md}".md 2>/dev/null | head -1)"
      [ -z "$hit" ] || { printf '%s' "$hit"; return; } ;;
  esac
  die "cannot resolve '$1' — give a hub path (07-api/stories.md, 07-api.md, CONVENTIONS.md) or a service name from spechub.conf (api, api/stories)"
}

ensure_board() {
  [ -f "$LOCKS" ] && return 0
  [ -f "$TEMPLATE" ] || die "neither LOCKS.md nor templates/LOCKS-TEMPLATE.md exists"
  local name="${PROJECT_NAME:-Spec Hub}"
  awk 'BEGIN{skip=0} /^<!--/{skip=1} skip&&/-->/{skip=0; getline; if ($0 ~ /^$/) next} !skip' "$TEMPLATE" \
    | sed "s/{Project Name}/$(printf '%s' "$name" | sed 's/[&/\]/\\&/g')/" > "$LOCKS"
  g add -- LOCKS.md
  log "LOCKS.md created from templates/LOCKS-TEMPLATE.md"
}
drop_new_board() { [ "$1" = 1 ] || { g rm --cached --quiet -- LOCKS.md; rm -f "$LOCKS"; }; }

# sync_origin <push> — fetch and fast-forward the hub before an edit (the claim protocol)
sync_origin() {
  local b behind ahead; b="$(branch)"
  [ "$1" = 1 ] || return 0
  g fetch --quiet origin "$b" || die "cannot fetch origin/$b — fix the network, or rerun with --no-push to edit the board offline"
  g rev-parse --verify --quiet "refs/remotes/origin/$b" >/dev/null || return 0
  behind="$(g rev-list --count "$b..origin/$b")"; ahead="$(g rev-list --count "origin/$b..$b")"
  [ "$behind" != 0 ] || return 0
  [ "$ahead" = 0 ] || die "the hub has diverged from origin/$b ($ahead local, $behind remote commit(s)) — run scripts/instance.sh sync, then try again"
  g merge --ff-only --quiet "origin/$b" \
    || die "cannot fast-forward the hub to origin/$b (uncommitted edits in the way?) — post the row before editing specs"
  log "hub fast-forwarded to origin/$b ($behind commit(s))"
}

# commit_push <message> <was-tracked> — commit LOCKS.md alone and push; 0 pushed, 1 origin moved (retry), dies otherwise
commit_push() {
  local b ahead; b="$(branch)"
  g commit --quiet -m "$1" -- LOCKS.md
  ahead="$(g rev-list --count "origin/$b..$b" 2>/dev/null || echo 1)"
  [ "$ahead" -le 1 ] || log "pushing $((ahead - 1)) earlier local hub commit(s) along with it"
  g push --quiet origin "$b" 2>/dev/null && return 0
  g reset --quiet --soft HEAD~1
  if [ "$2" = 1 ]; then g checkout HEAD -- LOCKS.md; else drop_new_board 0; fi
  g fetch --quiet origin "$b" 2>/dev/null || true
  [ "$(g rev-list --count "$b..origin/$b" 2>/dev/null || echo 0)" != 0 ] \
    || die "push to origin/$b failed and origin did not move (auth? protected branch?) — undone; fix the push, or rerun with --no-push"
  return 1
}

# push_mode <push> — 0/1 after the no-origin / no-branch fallback
push_mode() {
  if [ "$1" = 1 ] && { [ -z "$(branch)" ] || ! has_origin; }; then
    log "WARNING: hub has no origin remote or no branch — editing the board locally (scripts/lock.sh check guards the merge)"; echo 0
  else echo "$1"; fi
}

# say_overlaps <lines> — one log line per overlap row from `board overlap`
say_overlaps() {
  local s f st b d h
  while IFS='|' read -r s f st b d h; do
    [ -n "$s" ] || continue
    if [ "$st" = held ]; then log "$s is HELD by '$f' ($b, since $d)${h:+ — as $h}"
    else log "$s is being designed against by '$f' ($b, since $d)${h:+ — as $h}"; fi
  done <<< "$1"
}

# post <state> <args...> — intend and claim share everything but the state and the refusal rule
post() {
  local state="$1"; shift
  local feature="" by="" note="" push=1 specs=() a
  while [ $# -gt 0 ]; do
    case "$1" in
      --by) [ $# -ge 2 ] || die "--by needs a value"; by="$2"; shift 2 ;;
      --note) [ $# -ge 2 ] || die "--note needs a value"; note="$2"; shift 2 ;;
      --no-push) push=0; shift ;;
      --*) die "unknown option $1" ;;
      *) if [ -z "$feature" ]; then feature="$(slug "$1")"; else specs+=("$(resolve "$1")"); fi; shift ;;
    esac
  done
  [ -n "$feature" ] && [ ${#specs[@]} -gt 0 ] || usage
  case "$by$note" in *'|'*|*'`'*) die "--by and --note cannot contain '|' or backticks" ;; esac
  [ -n "$by" ] || by="$(g config user.name 2>/dev/null || true)"; [ -n "$by" ] || by="${USER:-unknown}"
  push="$(push_mode "$push")"
  [ ! -f "$LOCKS" ] || g diff --quiet HEAD -- LOCKS.md 2>/dev/null || ! tracked \
    || die "LOCKS.md has uncommitted changes — commit or discard them first: the board is committed alone"

  local try=0 over blocked was res verb
  while :; do
    try=$((try + 1))
    sync_origin "$push"
    if tracked; then was=1; else was=0; fi
    ensure_board
    over="$(board overlap "$feature" "${specs[@]}")"
    say_overlaps "$over"
    blocked="$(printf '%s\n' "$over" | awk -F'|' '$3=="held"' )"
    if [ "$state" = held ] && [ -n "$blocked" ]; then
      drop_new_board "$was"
      die "cannot hold for '$feature' — another feature holds the file until its close-out; coordinate with the holder, or release theirs (scripts/lock.sh release <feature>) if it is done"
    fi
    res="$(board add "$feature" "$state" "$by" "$note" "${specs[@]}")"
    if [ "$res" = unchanged ]; then
      log "'$feature' already names ${specs[*]} — nothing to post"; drop_new_board "$was"; return 0
    fi
    verb="${res%% *}"; res="${res#* }"; [ "$res" != "$verb" ] || res="(note only)"
    [ "$verb" = held ] && verb="holds" || verb="is designing against"
    if [ "$push" = 0 ]; then
      log "'$feature' $verb $res in LOCKS.md, not committed (--no-push) — run scripts/lock.sh check after the hubs meet"; return 0
    fi
    if commit_push "locks: $feature $verb $res" "$was"; then
      log "'$feature' $verb $res ($by; pushed to origin/$(branch))"
      [ -z "$over" ] || [ "$state" = held ] || log "overlaps above are a notice, not a block — talk to them before either of you cascades"
      return 0
    fi
    [ "$try" -lt "$TRIES" ] || die "origin kept moving — $TRIES attempts lost the race; try again"
    log "origin moved meanwhile — retrying on top of it"
  done
}

cmd_release() {
  local feature="" push=1 a
  for a in "$@"; do case "$a" in --no-push) push=0 ;; --*) die "unknown option $a" ;; *) feature="$(slug "$a")" ;; esac; done
  [ -n "$feature" ] || usage
  push="$(push_mode "$push")"
  if [ "$push" = 0 ]; then
    [ -f "$LOCKS" ] || { log "no LOCKS.md — nothing to release"; return 0; }
    case "$(board remove "$feature")" in
      absent) log "'$feature' has no row — nothing to release" ;;
      *) log "'$feature' released in LOCKS.md, not committed (--no-push) — the release goes out with your next commit" ;;
    esac; return 0
  fi
  g diff --quiet HEAD -- LOCKS.md 2>/dev/null || ! tracked \
    || die "LOCKS.md has uncommitted changes — commit or discard them first, or release with --no-push"
  local try=0
  while :; do
    try=$((try + 1))
    sync_origin "$push"
    [ -f "$LOCKS" ] || { log "no LOCKS.md — nothing to release"; return 0; }
    case "$(board remove "$feature")" in absent) log "'$feature' has no row — nothing to release"; return 0 ;; esac
    if commit_push "locks: release $feature" 1; then log "'$feature' released (pushed to origin/$(branch))"; return 0; fi
    [ "$try" -lt "$TRIES" ] || die "origin kept moving — $TRIES releases lost the race; try again"
    log "origin moved meanwhile — retrying on top of it"
  done
}

cmd_check() {
  local feature="" specs=() tmp rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) [ $# -ge 2 ] || die "--feature needs a value"; feature="$(slug "$2")"; shift 2 ;;
      --*) die "unknown option $1" ;;
      *) specs+=("$(resolve "$1")"); shift ;;
    esac
  done
  fetch_quiet
  if [ ${#specs[@]} -gt 0 ]; then
    [ -f "$LOCKS" ] || { log "ok — no LOCKS.md, nothing is held"; return 0; }
    local over; over="$(board overlap "${feature:--}" "${specs[@]}")"
    [ -n "$over" ] || { log "ok — ${specs[*]} free${feature:+ for '$feature'}"; return 0; }
    say_overlaps "$over"
    [ -z "$(printf '%s\n' "$over" | awk -F'|' '$3=="held"')" ] \
      || die "held by another feature until its close-out — coordinate with the holder before cascading against it"
    log "ok — nothing held; the designs above are a notice, talk to them before either of you cascades"; return 0
  fi
  [ -f "$LOCKS" ] || { log "ok — no LOCKS.md, nothing is held"; return 0; }
  tmp="$(mktemp)"
  if origin_locks "$tmp"; then board check "$STALE_DAYS" "$tmp" >&2 || rc=1; else board check "$STALE_DAYS" >&2 || rc=1; fi
  rm -f "$tmp"
  [ "$rc" = 0 ] || die "two features hold the same spec file — one of them was claimed offline; the holders decide who yields (scripts/lock.sh release <feature>)"
  log "ok — no two features hold the same spec file ($(board rows | wc -l | tr -d ' ') row(s))"
}

cmd_list() { fetch_quiet; board list; }

cmd="${1:-}"; shift || true
case "$cmd" in
  intend)  post designing "$@" ;;
  claim)   post held "$@" ;;
  release) cmd_release "$@" ;;
  check)   cmd_check "$@" ;;
  list)    cmd_list ;;
  *) usage ;;
esac
