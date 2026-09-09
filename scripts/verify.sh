#!/usr/bin/env bash
# scripts/verify.sh — determinism gates for Step 0. Every check is mechanical and exits non-zero on
# failure, so "the specs are consistent" stops being a judgment the session makes about its own work.
#
#   scripts/verify.sh manifest              every file in `bootstrap.sh plan --manifest` exists, and
#                                           no extra module file exists that the manifest does not list
#   scripts/verify.sh facts [<service>...]  each spec's Environment Variables table == fact sheet §7a,
#                                           and every entity in fact sheet §6 has a field table somewhere
#   scripts/verify.sh diff <dirA> <dirB>    compare two generated spec trees by their EXTRACTED SETS
#                                           (file names, headings, endpoint rows, env names, entities,
#                                           and the section 10 seams) rather than their prose — only
#                                           the tables have to match. Seams are grouping-independent,
#                                           so "seams differ" means one run dropped a real seam.
#   scripts/verify.sh records [--all]       every endpoint/route record carries every key of its type
#                                           (--all lists every failure instead of the first 40)
#   scripts/verify.sh headings              module files use only the closed heading set
#   scripts/verify.sh mechanisms            every overview section 10 entry is well formed: the four
#                                           keys, >= 2 services from spechub.conf, evidence on both
#                                           sides, contiguous numbering
#   scripts/verify.sh all                   manifest + facts + records + headings + mechanisms
#
# Compatible with the macOS system bash (3.2).

set -euo pipefail
HUB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FACTS_DIR="$HUB_DIR/bootstrap/facts"
CONF="$HUB_DIR/spechub.conf"
BOOTSTRAP="$HUB_DIR/scripts/bootstrap.sh"
export LC_ALL=C
FAIL=0

ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=1; }
head_() { printf '\n== %s\n' "$*"; }

# ---------------------------------------------------------------- extractors
# One place that knows how to read a fact out of a generated spec, so `facts` and `diff` agree.
spec_files() {  # spec_files <root> <specfile> → the spec plus its split directory, if any
  local root="$1" spec="$2"
  if [ -f "$root/$spec" ]; then printf '%s\n' "$root/$spec"; fi
  if [ -d "$root/${spec%.md}" ]; then find "$root/${spec%.md}" -name '*.md' -type f | sort; fi
  return 0
}
x_headings() {  # level + name only. A heading's trailing "(...)" or " — ..." is prose, which the
  # determinism contract lets vary; the name itself is not, so `## Shared Shapes` vs
  # `## Shared Request/Response Shapes` is still a difference.
  #
  # The `### 10.x` entry headings are the one exemption: how the cross-service mechanisms are
  # grouped and titled is a free choice (one run may file three CDN artifacts as three entries,
  # the next may file them as one), so comparing those titles reports differences that are not
  # differences in content. They are compared as seams instead — see x_seams / cmd_mechanisms.
  grep -hE '^#{2,5} ' "$@" 2>/dev/null \
    | grep -vE '^### 10\.[0-9]+' \
    | sed -E 's/[[:space:]]*\(.*$//; s/[[:space:]]*(—|--)[[:space:]].*$//; s/[[:space:]]*$//' \
    | sort -u
}
x_envrows() {  # only rows inside an "Environment Variables" section — schema field tables look identical
  awk '
    /^#+ / { inenv = ($0 ~ /Environment Variables/) ? 1 : 0; next }
    inenv && /^\| *`[A-Z][A-Za-z0-9_]*` *\|/ {
      i = index($0, "`"); rest = substr($0, i+1); j = index(rest, "`")
      print substr(rest, 1, j-1)
    }' "$@" 2>/dev/null | sort -u
}
x_endpoints() { grep -hE '^\| *(GET|POST|PUT|PATCH|DELETE|ALL|HEAD|OPTIONS) *\|' "$@" 2>/dev/null \
                 | sed -E 's/^\| *([A-Z]+) *\| *`?([^|`]+)`? *\|.*/\1 \2/' | sed 's/[[:space:]]*$//' | sort -u; }
x_entities() { grep -hE '^#{3,5} `?[A-Za-z][A-Za-z0-9_]*`? *\(' "$@" 2>/dev/null \
                 | sed -E 's/^#+ `?([A-Za-z][A-Za-z0-9_]*)`?.*/\1/' | sort -u; }

svc_names() {  # every service name in <root>/spechub.conf, space separated (falls back to the hub's)
  local conf="${1:-$HUB_DIR}/spechub.conf"
  [ -f "$conf" ] || conf="$CONF"
  sed -n '/^SERVICES="/,/^"/p' "$conf" 2>/dev/null | grep '|' | cut -d'|' -f1 | tr -d ' \t' | tr '\n' ' '
}

x_seams() {  # the undirected {service <-> service} pairs section 10 says exist, one per line.
  # This is the granularity-independent view of the cross-service inventory: merging two entries
  # into one, or splitting one into three, leaves the seam set unchanged, so two runs that grouped
  # the mechanisms differently still compare equal — while a seam that one run documented and the
  # other dropped shows up as a single line. Direction is deliberately discarded: which side is
  # called "Producer" is a framing choice, and the two runs disagreed on it for the same seam.
  local root="$1" ov="$1/00-architecture-overview.md"
  [ -f "$ov" ] || return 0
  awk -v svcs="$(svc_names "$root")" '
    BEGIN { n = split(svcs, a, " "); for (i = 1; i <= n; i++) if (a[i] != "") ok[a[i]] = 1 }
    function flush(   i, j, x, y) {
      for (i = 1; i <= np; i++) for (j = 1; j <= nc; j++) if (P[i] != C[j]) {
        x = P[i]; y = C[j]; print (x < y ? x " <-> " y : y " <-> " x)
      }
      np = 0; nc = 0; delete P; delete C
    }
    function grab(l, which,   t) {
      while (match(l, /`[a-z0-9-]+`/)) {
        t = substr(l, RSTART + 1, RLENGTH - 2)
        if (t in ok) { if (which == "p") P[++np] = t; else C[++nc] = t }
        l = substr(l, RSTART + RLENGTH)
      }
    }
    /^### 10\./              { flush(); inentry = 1; next }
    /^## /                   { flush(); inentry = 0 }
    inentry && /^- \*\*Producer/ { grab($0, "p") }
    inentry && /^- \*\*Consumer/ { grab($0, "c") }
    END { flush() }
  ' "$ov" | sort -u
}

frontend_prefixes() {  # "NN-{service}" for every service whose spechub.conf group is frontend
  local name dir start port label group install nn=0
  while IFS='|' read -r name dir start port label group install; do
    [ -n "$name" ] || continue
    [ "$group" = static ] && continue
    nn=$((nn + 1))
    if [ "$group" = frontend ]; then printf '%02d-%s ' "$nn" "$name"; fi
  done < <(sed -n '/^SERVICES="/,/^"/p' "$CONF" | grep '|')
  return 0
}

conf_specs() {  # "service|specfile" per non-static service, in spechub.conf order
  "$BOOTSTRAP" plan 2>/dev/null | awk 'NR>1 && NF>=4 && $1 ~ /^[0-9]+$/ {printf "%s|%s\n", $2, $3}'
}

# ---------------------------------------------------------------- manifest
cmd_manifest() {
  head_ "manifest — every planned file exists, nothing extra"
  local svc="" spec="" line path missing=0
  local tmp; tmp="$(mktemp)"; "$BOOTSTRAP" plan --manifest > "$tmp"
  while IFS= read -r line; do
    case "$line" in
      "  "*) path="${line#  }"
            if [ -f "$HUB_DIR/$path" ]; then :; else bad "missing: $path"; missing=$((missing+1)); fi ;;
      "") ;;
      *) : ;;
    esac
  done < "$tmp"
  if [ "$missing" = 0 ]; then ok "all planned files present"; fi
  # extra module files nobody planned
  local d base
  grep -E '^  [0-9]+-.*/' "$tmp" | sed 's/^  //' | sort > "$tmp.planned"
  for d in "$HUB_DIR"/[0-9][0-9]-*/; do
    [ -d "$d" ] || continue
    base="$(basename "$d")"
    find "$d" -maxdepth 1 -name '*.md' -type f | sed "s#^$HUB_DIR/##" | sort > "$tmp.actual"
    comm -13 "$tmp.planned" "$tmp.actual" | while IFS= read -r path; do
      if [ -n "$path" ]; then printf '  FAIL  not in manifest: %s\n' "$path"; fi
    done || true
    if [ -n "$(comm -13 "$tmp.planned" "$tmp.actual")" ]; then FAIL=1; fi
  done
  rm -f "$tmp" "$tmp.planned" "$tmp.actual"
}

# ---------------------------------------------------------------- facts
sheet_env() { sed -n '/^### 7a\./,/^### 7b\./p' "$1" | sed -n '/```text/,/```/p' | grep -v '```' | grep -E '^[A-Za-z]' | sort -u; }
sheet_entities() {  # class names declared in fact sheet §6
  sed -n '/^## 6\. Data Models/,/^## 7\./p' "$1" \
    | grep -oE 'export (class|const) [A-Za-z][A-Za-z0-9_]*|^model [A-Za-z][A-Za-z0-9_]*' \
    | awk '{print $NF}' | sort -u
}
cmd_facts() {
  local want=" $* "
  local svc spec sheet files
  while IFS='|' read -r svc spec; do
    [ -n "$svc" ] || continue
    [ "$#" -eq 0 ] || case "$want" in *" $svc "*) ;; *) continue ;; esac
    sheet="$FACTS_DIR/$svc.md"
    [ -f "$sheet" ] || continue
    head_ "facts — $svc"
    files="$(spec_files "$HUB_DIR" "$spec")"
    if [ -z "$files" ]; then bad "no spec written for $svc"; continue; fi
    local a b
    a="$(sheet_env "$sheet")"
    b="$(x_envrows $files | grep -E '^[A-Z]')"
    local only_sheet only_spec
    only_sheet="$(comm -23 <(printf '%s\n' "$a") <(printf '%s\n' "$b") | tr '\n' ' ')"
    if [ -n "${only_sheet// /}" ]; then bad "env in §7a but not in the spec: $only_sheet"; else ok "env table covers §7a"; fi
  done < <(conf_specs)
}

# ---------------------------------------------------------------- records (D12)
# Every endpoint/route record carries every key of its record type. The record type is read from the
# record itself: a **Component:** key makes it a route, anything else an endpoint. Written in awk
# without interval quantifiers, which the macOS system awk does not support.
BACKEND_KEYS="Guard|Request|Response|Status codes|Notes"
ROUTE_KEYS="Component|Guard / Layout|Loads|State|States|Notes"

cmd_records() {
  head_ "records — every endpoint/route record carries every key (D12)"
  [ "${1:-}" = "--all" ] && shown_all=1 || shown_all=0
  local files out
  files="$(ls "$HUB_DIR"/[0-9][0-9]-*.md 2>/dev/null; find "$HUB_DIR"/[0-9][0-9]-*/ -name '*.md' -type f 2>/dev/null)"
  [ -n "$files" ] || { bad "no spec files found"; return; }
  local fe_prefixes; fe_prefixes="$(frontend_prefixes)"
  out="$(awk -v bk="$BACKEND_KEYS" -v rk="$ROUTE_KEYS" -v fes="$fe_prefixes" -v hub="$HUB_DIR" '
    BEGIN { n = split(fes, f, " "); for (i = 1; i <= n; i++) if (f[i] != "") fegroup[f[i]] = 1 }
    function flush(   i, n, k, miss, keys) {
      if (!inrec) return
      total++
      isroute = ("Component" in seen)
      isapi = (rectitle ~ /\/api\//)
      if (fe && !isroute && !isapi) {
        printf "%s:%d\t%s\twrong record type: a frontend view needs the route record (Component/Guard / Layout/Loads/State/States/Notes), not the endpoint record\n", file, recline, rectitle
        inrec = 0; split("", seen); return
      }
      if (isroute && !isapi && rectitle ~ /^`(GET|POST|PUT|PATCH|DELETE|ALL|HEAD|OPTIONS) /) {
        printf "%s:%d\t%s\theading shape: a route record heading is the path alone, with no method (D15)\n", file, recline, rectitle
        inrec = 0; split("", seen); return
      }
      keys = isroute ? rk : bk
      n = split(keys, k, "|"); miss = ""
      for (i = 1; i <= n; i++) if (!(k[i] in seen)) miss = miss (miss ? ", " : "") k[i]
      if (miss == "") ok++
      else printf "%s:%d\t%s\tmissing: %s\n", file, recline, rectitle, miss
      inrec = 0; split("", seen)
    }
    FNR == 1 {
      flush(); file = FILENAME
      if (hub != "" && index(file, hub) == 1) file = substr(file, length(hub) + 2)
      fe = 0; for (pfx in fegroup) if (index(FILENAME, pfx) > 0) fe = 1
    }
    /^#+ / {
      # a record heading is level 4+ whose text begins with a backtick
      hashes = $0; sub(/ .*$/, "", hashes)
      text = $0; sub(/^#+ +/, "", text)
      isrec = (length(hashes) >= 4 && (text ~ /^`(GET|POST|PUT|PATCH|DELETE|ALL|HEAD|OPTIONS) / || text ~ /^`\//))
      if (isrec) { flush(); inrec = 1; recline = FNR; rectitle = text }
      else flush()
      next
    }
    inrec && /^- \*\*/ {
      key = $0; sub(/^- \*\*/, "", key); sub(/:\*\*.*$/, "", key); seen[key] = 1
    }
    END { flush(); printf "TOTALS\t%d\t%d\n", total, ok }
  ' $files)"
  local totals; totals="$(printf '%s\n' "$out" | grep '^TOTALS')"
  local t o; t="$(printf '%s' "$totals" | cut -f2)"; o="$(printf '%s' "$totals" | cut -f3)"
  local fails shown=40
  if [ "$shown_all" = 1 ]; then shown=100000; fi
  fails="$(printf '%s\n' "$out" | grep -v '^TOTALS' | grep -c . || true)"
  printf '%s\n' "$out" | grep -v '^TOTALS' | head -"$shown" | while IFS="$(printf '\t')" read -r loc title msg; do
    if [ -n "$loc" ]; then printf '  FAIL  %s  %s — %s\n' "$loc" "$title" "$msg"; fi
  done || true
  if [ "$fails" -gt "$shown" ]; then
    printf '  ...  and %s more (full list: scripts/verify.sh records --all)\n' "$((fails - shown))"
  fi
  if [ "$t" = "$o" ]; then ok "all $t records complete"
  else
    FAIL=1
    printf '  %s of %s records complete (%s incomplete)\n' "$o" "$t" "$((t - o))"
  fi
}

# ---------------------------------------------------------------- headings (D1, closed set)
MODULE_HEADINGS="Schema|Endpoints|Request / Response Shapes|Business Logic|Files|Views & Routes|State|Action Types|Error Codes"

cmd_headings() {
  head_ "headings — module files use only the closed set (D1)"
  local files bad_ct
  files="$(find "$HUB_DIR"/[0-9][0-9]-*/ -name '*.md' -type f 2>/dev/null | grep -vE '/(00-core|01-conventions)\.md$')"
  [ -n "$files" ] || { ok "no split specs"; return; }
  local stray
  stray="$(grep -hE '^#### ' $files 2>/dev/null | sed -E 's/^#### +//; s/[[:space:]]*$//' | sort -u \
           | awk -v allow="$MODULE_HEADINGS" '
               BEGIN { n = split(allow, a, "|"); for (i = 1; i <= n; i++) ok[a[i]] = 1 }
               !($0 in ok) { print }')"
  if [ -z "$stray" ]; then ok "only closed-set headings ($(grep -hE '^#### ' $files | sort -u | wc -l | tr -d ' ') distinct)"
  else
    FAIL=1
    printf '%s\n' "$stray" | head -15 | sed 's/^/  FAIL  heading outside the closed set: /'
  fi
}

# ---------------------------------------------------------------- mechanisms (section 10)
cmd_mechanisms() {
  head_ "mechanisms — overview section 10 entries are well formed"
  local ov="$HUB_DIR/00-architecture-overview.md"
  [ -f "$ov" ] || { ok "no architecture overview"; return; }

  local count
  count="$(grep -cE '^### 10\.[0-9]+' "$ov" || true)"
  if [ "$count" = 0 ]; then
    # "None — no artifact is named by more than one service." is a legitimate section 10.
    if sed -n '/^## 10\./,/^## 11\./p' "$ov" | grep -qi '^ *None'; then
      ok "no mechanisms, declared None"
    else
      bad "section 10 has no entries and no explicit \"None\" declaration"
    fi
    return
  fi

  local problems
  problems="$(awk -v svcs="$(svc_names "$HUB_DIR")" '
    BEGIN { n = split(svcs, a, " "); for (i = 1; i <= n; i++) if (a[i] != "") ok[a[i]] = 1 }
    function flush() {
      if (cur == "") return
      if (!hasP) print cur "\tno **Producer:** line"
      if (!hasC) print cur "\tno **Consumer(s):** line"
      if (!hasK) print cur "\tno **Contract:** line"
      if (!hasE) print cur "\tno **Evidence:** line"
      if (nsvc < 2) print cur "\tnames " nsvc " service(s) from spechub.conf; a mechanism needs 2 or more"
      if (hasE && nev < 2) print cur "\tEvidence cites " nev " service(s); a mechanism needs evidence on both sides"
      cur = ""; hasP = 0; hasC = 0; hasK = 0; hasE = 0; nsvc = 0; nev = 0; delete S; delete EV
    }
    function addsvc(l,   t) {
      while (match(l, /`[a-z0-9-]+`/)) {
        t = substr(l, RSTART + 1, RLENGTH - 2)
        if ((t in ok) && !(t in S)) { S[t] = 1; nsvc++ }
        l = substr(l, RSTART + RLENGTH)
      }
    }
    function addev(l,   t) {
      while (match(l, /`[^`]+`/)) {
        t = substr(l, RSTART + 1, RLENGTH - 2); sub(/:.*$/, "", t)
        if ((t in ok) && !(t in EV)) { EV[t] = 1; nev++ }
        l = substr(l, RSTART + RLENGTH)
      }
    }
    /^### 10\./ {
      flush(); num++
      if (match($0, /10\.[0-9]+/)) cur = substr($0, RSTART, RLENGTH)
      if (cur != "10." num) print cur "\tout of order; expected 10." num
      inentry = 1; next
    }
    /^## / { flush(); inentry = 0 }
    inentry && /^- \*\*Producer/  { hasP = 1; addsvc($0) }
    inentry && /^- \*\*Consumer/  { hasC = 1; addsvc($0) }
    inentry && /^- \*\*Contract/  { hasK = 1 }
    inentry && /^- \*\*Evidence/  { hasE = 1; addev($0) }
    END { flush() }
  ' "$ov")"

  if [ -z "$problems" ]; then
    ok "all $count mechanisms well formed ($(x_seams "$HUB_DIR" | grep -c . || true) seams)"
  else
    printf '%s\n' "$problems" | head -30 | sed 's/^/  FAIL  /'
    FAIL=1
  fi
}

# ---------------------------------------------------------------- diff
cmd_diff() {
  local A="$1" B="$2"
  head_ "diff — extracted sets, $A vs $B"
  local fa fb
  fa="$(cd "$A" && find . -name '*.md' -type f | sed 's#^\./##' | sort)"
  fb="$(cd "$B" && find . -name '*.md' -type f | sed 's#^\./##' | sort)"
  if [ "$fa" = "$fb" ]; then ok "same file set ($(printf '%s\n' "$fa" | wc -l | tr -d ' ') files)"
  else
    bad "file sets differ"
    comm -23 <(printf '%s\n' "$fa") <(printf '%s\n' "$fb") | sed 's/^/        only in A: /'
    comm -13 <(printf '%s\n' "$fa") <(printf '%s\n' "$fb") | sed 's/^/        only in B: /'
  fi
  local kind
  for kind in headings envrows endpoints entities; do
    local ga gb
    ga="$(x_$kind $(find "$A" -name '*.md' -type f | sort))"
    gb="$(x_$kind $(find "$B" -name '*.md' -type f | sort))"
    if [ "$ga" = "$gb" ]; then ok "$kind identical ($(printf '%s\n' "$ga" | grep -c . || true))"
    else
      bad "$kind differ"
      comm -23 <(printf '%s\n' "$ga") <(printf '%s\n' "$gb") | head -20 | sed 's/^/        only in A: /'
      comm -13 <(printf '%s\n' "$ga") <(printf '%s\n' "$gb") | head -20 | sed 's/^/        only in B: /'
    fi
  done

  # Seams are compared from the trees themselves rather than through x_$kind, because the extractor
  # needs each root's own spechub.conf to know the service vocabulary.
  local sa sb
  sa="$(x_seams "$A")"; sb="$(x_seams "$B")"
  if [ "$sa" = "$sb" ]; then ok "seams identical ($(printf '%s\n' "$sa" | grep -c . || true))"
  else
    bad "seams differ — one run documented a cross-service seam the other dropped"
    comm -23 <(printf '%s\n' "$sa") <(printf '%s\n' "$sb") | sed 's/^/        only in A: /'
    comm -13 <(printf '%s\n' "$sa") <(printf '%s\n' "$sb") | sed 's/^/        only in B: /'
  fi
}

case "${1:-all}" in
  manifest) cmd_manifest ;;
  facts)    shift || true; cmd_facts "$@" ;;
  records)  shift || true; cmd_records "$@" ;;
  headings) cmd_headings ;;
  mechanisms) cmd_mechanisms ;;
  diff)     shift; [ "$#" -eq 2 ] || { echo "usage: verify.sh diff <dirA> <dirB>" >&2; exit 2; }; cmd_diff "$1" "$2" ;;
  all)      cmd_manifest; cmd_facts; cmd_records; cmd_headings; cmd_mechanisms ;;
  *)        sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

printf '\n'
[ "$FAIL" = 0 ] && { printf 'verify: PASS\n'; exit 0; } || { printf 'verify: FAIL\n'; exit 1; }
