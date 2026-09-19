#!/usr/bin/env bash
# scripts/status.sh — STATUS.md feature numbers, safe across several instances of the stack.
#
#   scripts/status.sh claim "<Feature name>" <service>... [--note "<one line>"] [--no-push]
#                                    Step 2a: take the next free number and add the feature's In Flight
#                                    row (each service 🔄), as its own commit pushed to origin. Prints
#                                    the number on stdout. Idempotent: a name already on the board
#                                    prints its number and changes nothing.
#   scripts/status.sh next           print the next free number (this checkout and the last fetch of origin)
#   scripts/status.sh check          fail when two rows share a number, here or against the last fetch
#                                    of origin (a claim made offline, or an old-style hand-numbered row)
#
# Why a push: every instance of the stack (another folder, another laptop) has its own STATUS.md, so
# "max + 1" alone gives two instances the same number. Origin is the one place they share, and a push
# is atomic: the claim fetches origin, fast-forwards the hub, writes the row, commits STATUS.md alone and
# pushes. A rejected push means another instance claimed first — the commit is undone and the claim
# retried on top of theirs. Run it FIRST in Step 2a, before any spec edit: the fast-forward must not
# meet a half-written cascade. --no-push (or a hub with no origin) writes the row without committing;
# `check` then catches a collision when the hubs meet.
#
# Metrics are keyed by the feature slug, not this number (scripts/metrics.py resolves the number at
# render time), so a renumbered row re-labels the board and moves no cost.

set -euo pipefail
HUB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS="$HUB_DIR/STATUS.md"
STACK="$HUB_DIR/scripts/stack.sh"
TRIES="${STATUS_CLAIM_TRIES:-5}"

log() { printf '[status] %s\n' "$*" >&2; }
die() { printf '[status] ERROR: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

[ -f "$STATUS" ] || die "STATUS.md not found in $HUB_DIR"
g() { git -C "$HUB_DIR" "$@"; }

# rows <file> — "number|name" for every numbered table row (both In Flight and Shipped)
rows() { sed -nE 's/^\|[[:space:]]*([0-9]+)[[:space:]]*\|[[:space:]]*([^|]*[^|[:space:]])[[:space:]]*\|.*/\1|\2/p' "$1"; }
max_of() { cut -d'|' -f1 | sort -n | tail -1; }

branch() { g branch --show-current; }
has_origin() { g remote get-url origin >/dev/null 2>&1; }
# origin_status <file> — write origin's STATUS.md as of the last fetch; false when there is none
origin_status() {
  local b; b="$(branch)"; [ -n "$b" ] && has_origin || return 1
  g rev-parse --verify --quiet "refs/remotes/origin/$b" >/dev/null || return 1
  g show "origin/$b:./STATUS.md" > "$1" 2>/dev/null
}

cmd_next() {
  local tmp n m; tmp="$(mktemp)"
  has_origin && [ -n "$(branch)" ] && g fetch --quiet origin "$(branch)" 2>/dev/null || true
  n="$(rows "$STATUS" | max_of)"
  if origin_status "$tmp"; then m="$(rows "$tmp" | max_of)"; [ "${m:-0}" -le "${n:-0}" ] || n="$m"; fi
  rm -f "$tmp"
  echo $(( ${n:-0} + 1 ))
}

cmd_check() {
  local tmp bad=0 d n name theirs; tmp="$(mktemp)"
  d="$(rows "$STATUS" | cut -d'|' -f1 | sort -n | uniq -d)"
  for n in $d; do
    bad=1; log "#$n is used by: $(rows "$STATUS" | awk -F'|' -v n="$n" '$1==n {printf "%s%s", s, $2; s=" · "}')"
  done
  if origin_status "$tmp"; then
    # same number, different name: one instance claimed it offline while another pushed it
    while IFS='|' read -r n name; do
      theirs="$(rows "$tmp" | awk -F'|' -v n="$n" '$1==n {print $2; exit}')"
      [ -z "$theirs" ] || [ "$(printf '%s' "$theirs" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$name" | tr 'A-Z' 'a-z')" ] && continue
      bad=1; log "#$n is '$name' here but '$theirs' on origin/$(branch)"
    done < <(rows "$STATUS")
  fi
  rm -f "$tmp"
  [ "$bad" = 0 ] || die "duplicate feature numbers — renumber the newer row(s) with 'scripts/status.sh next', then fix the number in that feature's prompts and changelog entry if they cite it"
  log "ok — every feature number is unique ($(rows "$STATUS" | wc -l | tr -d ' ') rows)"
}

# insert_row <number> <name> <note> <service>... — first row of the In Flight table
insert_row() {
  local n="$1" name="$2" note="$3"; shift 3
  local cells="" s; for s in "$@"; do cells="${cells:+$cells · }\`$s\` 🔄"; done
  ROW="| $n | $name | $cells | $note |" python3 - "$STATUS" <<'PY'
import io, os, re, sys
p = sys.argv[1]; lines = io.open(p, encoding='utf-8').read().split('\n')
try:
    h = next(i for i, l in enumerate(lines) if re.match(r'^##\s+In Flight\b', l))
    sep = next(i for i in range(h + 1, len(lines)) if re.match(r'^\|\s*-{2,}', lines[i]))
except StopIteration:
    sys.exit('STATUS.md has no "## In Flight" table')
lines.insert(sep + 1, os.environ['ROW'])
io.open(p, 'w', encoding='utf-8').write('\n'.join(lines))
PY
}

cmd_claim() {
  local name="" note="" push=1 svcs=() a
  while [ $# -gt 0 ]; do
    case "$1" in
      --note) [ $# -ge 2 ] || die "--note needs a value"; note="$2"; shift 2 ;;
      --no-push) push=0; shift ;;
      --*) die "unknown option $1" ;;
      *) if [ -z "$name" ]; then name="$1"; else svcs+=("$1"); fi; shift ;;
    esac
  done
  [ -n "$name" ] && [ ${#svcs[@]} -gt 0 ] || usage
  case "$name$note" in *'|'*) die "the name and note cannot contain '|'" ;; esac
  local known; known=" $("$STACK" repos 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ')"
  for a in "${svcs[@]}"; do case "$known " in *" $a "*) ;; *) die "unknown service '$a' — use a name from spechub.conf" ;; esac; done

  local b; b="$(branch)"
  if [ "$push" = 1 ] && { [ -z "$b" ] || ! has_origin; }; then
    log "WARNING: hub has no origin remote or no branch — claiming locally (scripts/status.sh check guards the merge)"; push=0
  fi
  g diff --quiet HEAD -- STATUS.md 2>/dev/null \
    || die "STATUS.md has uncommitted changes — commit or discard them first: the claim commits STATUS.md alone"

  local try=0 behind ahead existing n
  while :; do
    try=$((try + 1))
    if [ "$push" = 1 ]; then
      g fetch --quiet origin "$b" \
        || die "cannot fetch origin/$b — fix the network, or rerun with --no-push to claim offline"
      if g rev-parse --verify --quiet "refs/remotes/origin/$b" >/dev/null; then
        behind="$(g rev-list --count "$b..origin/$b")"; ahead="$(g rev-list --count "origin/$b..$b")"
        if [ "$behind" != 0 ]; then
          [ "$ahead" = 0 ] || die "the hub has diverged from origin/$b ($ahead local, $behind remote commit(s)) — run scripts/instance.sh sync, then claim again"
          g merge --ff-only --quiet "origin/$b" \
            || die "cannot fast-forward the hub to origin/$b (uncommitted edits in the way?) — claim before editing specs"
          log "hub fast-forwarded to origin/$b ($behind commit(s))"
        fi
      fi
    fi
    existing="$(rows "$STATUS" | awk -F'|' -v k="$(printf '%s' "$name" | tr 'A-Z' 'a-z')" 'tolower($2)==k {print $1; exit}')"
    if [ -n "$existing" ]; then log "'$name' is already on the board as #$existing — nothing claimed"; echo "$existing"; return 0; fi
    n=$(( $(rows "$STATUS" | max_of) + 1 ))
    insert_row "$n" "$name" "$note" "${svcs[@]}"
    if [ "$push" = 0 ]; then
      log "#$n written to STATUS.md, not committed (--no-push) — run scripts/status.sh check after the hubs meet"
      echo "$n"; return 0
    fi
    g commit --quiet -m "status: claim #$n $name" -- STATUS.md
    ahead="$(g rev-list --count "origin/$b..$b" 2>/dev/null || echo 1)"
    [ "$ahead" -le 1 ] || log "pushing $((ahead - 1)) earlier local hub commit(s) along with the claim"
    if g push --quiet origin "$b" 2>/dev/null; then
      log "claimed #$n '$name' (pushed to origin/$b)"; echo "$n"; return 0
    fi
    # Undo the claim commit and put STATUS.md back; it had no local edits before the claim.
    g reset --quiet --soft HEAD~1
    g checkout HEAD -- STATUS.md
    g fetch --quiet origin "$b" 2>/dev/null || true
    [ "$(g rev-list --count "$b..origin/$b" 2>/dev/null || echo 0)" != 0 ] \
      || die "push to origin/$b failed and origin did not move (auth? protected branch?) — claim undone; fix the push, or rerun with --no-push"
    [ "$try" -lt "$TRIES" ] || die "origin kept moving — $TRIES claims lost the race; try again"
    log "#$n was taken on origin meanwhile — retrying on top of it"
  done
}

cmd="${1:-}"; shift || true
case "$cmd" in
  claim) cmd_claim "$@" ;;
  next)  cmd_next ;;
  check) cmd_check ;;
  *) usage ;;
esac
