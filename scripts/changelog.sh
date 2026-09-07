#!/usr/bin/env bash
# scripts/changelog.sh — CHANGELOG.md maintenance (WORKFLOW.md Step 4d).
#
#   scripts/changelog.sh add "<entry text>"        prepend *(YYYY-MM-DD — <entry text>)* as the newest entry
#   scripts/changelog.sh archive <YYYY-MM-DD>      move entries dated before <date> to archive/CHANGELOG-archive.md
#
# The entry text is one paragraph: what shipped, notable deviations, implementing commit refs.
# Entries longer than CHANGELOG_MAX_CHARS (default 900) are refused — trim, don't narrate.
# Neither command reads the changelog into a session: they edit the file in place.

set -euo pipefail
HUB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$HUB_DIR/CHANGELOG.md"
ARCHIVE="$HUB_DIR/archive/CHANGELOG-archive.md"
MAX="${CHANGELOG_MAX_CHARS:-900}"

die() { printf '[changelog] ERROR: %s\n' "$*" >&2; exit 1; }

cmd_add() {
  local text="${1:-}"
  [ -n "$text" ] || die 'Usage: changelog.sh add "<entry text>"'
  text="$(printf '%s' "$text" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
  local n=${#text}
  [ "$n" -le "$MAX" ] || die "Entry is $n characters; the cap is $MAX. Keep what shipped + deviations + commit refs; rationale goes in the archived feature file."
  local entry; entry="*($(date '+%Y-%m-%d') — ${text})*"
  ENTRY="$entry" python3 - "$LOG" <<'PY'
import io, os, sys
p = sys.argv[1]; s = io.open(p, encoding='utf-8').read()
marker = '\n---\n\n'
i = s.find(marker)
if i < 0: sys.exit('CHANGELOG.md has no "---" separator after the preamble')
i += len(marker)
io.open(p, 'w', encoding='utf-8').write(s[:i] + os.environ['ENTRY'] + '\n\n' + s[i:])
PY
  printf '[changelog] added (%d chars): %s\n' "$n" "$(printf '%s' "$text" | head -c 100)…" >&2
}

cmd_archive() {
  local before="${1:-}"
  printf '%s' "$before" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || die 'Usage: changelog.sh archive <YYYY-MM-DD>'
  python3 - "$LOG" "$ARCHIVE" "$before" <<'PY'
import io, os, re, sys
log, arch, before = sys.argv[1:4]
s = io.open(log, encoding='utf-8').read()
marker = '\n---\n\n'; i = s.find(marker); i += len(marker)
head, body = s[:i], s[i:]
blocks = re.split(r'\n\n(?=\*\(\d{4}-\d{2}-\d{2})', body.strip('\n'))
keep = [b for b in blocks if b[2:12] >= before]
move = [b for b in blocks if b[2:12] < before]
io.open(log, 'w', encoding='utf-8').write(head + '\n\n'.join(keep) + '\n')
a = io.open(arch, encoding='utf-8').read() if os.path.exists(arch) else \
    "# Implementation Changelog (archive)\n\nEntries rolled out of `CHANGELOG.md` by `scripts/changelog.sh archive`. Newest first. Do not edit.\n\n---\n\n"
ai = a.find(marker) + len(marker)
io.open(arch, 'w', encoding='utf-8').write(a[:ai] + '\n\n'.join(move + ([a[ai:].strip('\n')] if a[ai:].strip() else [])) + '\n')
print(f'[changelog] kept {len(keep)}, archived {len(move)} (before {before})', file=sys.stderr)
PY
}

case "${1:-}" in
  add)     shift; cmd_add "$@" ;;
  archive) shift; cmd_archive "$@" ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
