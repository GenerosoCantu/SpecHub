#!/usr/bin/env bash
# scripts/test-portable.sh — end-to-end proof that a hub holds no machine-specific path.
#
#   scripts/test-portable.sh          build a throw-away layout <tmp>/root/{hub,repo-a,repo-b}, run
#                                     `bootstrap.sh init` there and check every acceptance criterion:
#     1. spechub.conf gets REPOS_ROOT="${SPECHUB_REPOS_ROOT:-..}" — no absolute path
#     2. no fact sheet names the temp folder — paths are relative to REPOS_ROOT
#     3. stack.sh / bootstrap.sh resolve REPOS_ROOT to the hub's parent
#     4. SPECHUB_REPOS_ROOT in the environment and REPOS_ROOT in spechub.local.conf both override it,
#        for stack.sh and for bootstrap.sh alike
#     5. spechub.local.conf, .run/, .logs/, .dispatch/ and .DS_Store are ignored by git
#     6. verify.sh portable passes on the fresh hub
#     7. a second instance (instance.sh clone <new-root>) resolves its own root, not the source root
#
# The hub under test is a copy of THIS checkout's working tree (not its committed state), so the
# scripts being edited are the ones exercised. Everything runs under mktemp and is removed on exit.
# Compatible with the macOS system bash (3.2). Needs git, tar.

set -euo pipefail
HUB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LC_ALL=C
FAIL=0
ok()  { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; FAIL=1; }
phys() { (cd "$1" 2>/dev/null && pwd -P); }
GIT_ID=(-c user.name=spechub-test -c user.email=test@spechub.invalid)

work="$(mktemp -d "${TMPDIR:-/tmp}/spechub-portable.XXXXXX")"
trap 'rm -rf "$work"' EXIT
root="$work/root"; hub="$root/hub"; mkdir -p "$hub" "$work/elsewhere"

# --- a hub and two fake service repos --------------------------------------------------------
(cd "$HUB_DIR" && tar cf - --exclude=.git --exclude=.run --exclude=.logs --exclude=.dispatch --exclude=node_modules .) | (cd "$hub" && tar xf -)
rm -f "$hub/spechub.conf" "$hub/spechub.local.conf" "$hub/.DS_Store"; rm -rf "$hub/bootstrap/facts"
git -C "$hub" init -q && git -C "$hub" "${GIT_ID[@]}" add -A && git -C "$hub" "${GIT_ID[@]}" commit -qm "hub copy"
for r in repo-a repo-b; do
  mkdir -p "$root/$r/src"
  printf '{ "name": "%s", "version": "1.0.0", "scripts": { "start": "node src/index.js" } }\n' "$r" > "$root/$r/package.json"
  printf 'const http = require("http"); http.createServer().listen(process.env.PORT || 3000);\n' > "$root/$r/src/index.js"
  git -C "$root/$r" init -q && git -C "$root/$r" "${GIT_ID[@]}" add -A && git -C "$root/$r" "${GIT_ID[@]}" commit -qm init
done

printf '\n== init in %s\n' "$root"
if ! "$hub/scripts/bootstrap.sh" init "$root" --name "Portable Test" --no-install >"$work/init.log" 2>&1; then
  bad "bootstrap.sh init failed:"; tail -20 "$work/init.log" | sed 's/^/        /'
  printf '\ntest-portable: FAIL\n'; exit 1
fi
ok "bootstrap.sh init ran ($(grep -c '^[^#]*|' "$hub/spechub.conf" || true) service rows)"

# 1. committed value is relative, with the environment default
if grep -qF 'REPOS_ROOT="${SPECHUB_REPOS_ROOT:-..}"' "$hub/spechub.conf"; then ok 'spechub.conf: REPOS_ROOT="${SPECHUB_REPOS_ROOT:-..}"'
else bad "spechub.conf REPOS_ROOT: $(grep -E '^REPOS_ROOT=' "$hub/spechub.conf" || echo '(missing)')"; fi

# 2. fact sheets name nothing under the temp folder
sheets="$(ls "$hub"/bootstrap/facts/*.md 2>/dev/null || true)"
if [ -z "$sheets" ]; then bad "no fact sheet written"
elif grep -lF "$work" $sheets >/dev/null 2>&1 || grep -lF "$(phys "$work")" $sheets >/dev/null 2>&1; then
  bad "a fact sheet holds the temp path:"; grep -nF "$(phys "$work")" $sheets | head -5 | cut -c1-160 | sed 's/^/        /'
else ok "fact sheets hold no absolute path ($(printf '%s\n' "$sheets" | wc -l | tr -d ' ') sheets; Directory = $(grep -m1 '^| Directory' "$hub/bootstrap/facts/repo-a.md" | cut -d'|' -f3 | tr -d ' '))"; fi

# 3. default resolution → the hub's parent
got="$(phys "$("$hub/scripts/stack.sh" root)")"
[ "$got" = "$(phys "$root")" ] && ok "stack.sh root → the hub's parent" || bad "stack.sh root → $got, expected $(phys "$root")"

# 4. overrides, without touching a committed file
got="$(phys "$(SPECHUB_REPOS_ROOT="$work/elsewhere" "$hub/scripts/stack.sh" root)")"
[ "$got" = "$(phys "$work/elsewhere")" ] && ok "SPECHUB_REPOS_ROOT overrides (stack.sh)" || bad "SPECHUB_REPOS_ROOT ignored by stack.sh: $got"
printf 'REPOS_ROOT="%s"\n' "$work/elsewhere" > "$hub/spechub.local.conf"
got="$(phys "$("$hub/scripts/stack.sh" root)")"
[ "$got" = "$(phys "$work/elsewhere")" ] && ok "spechub.local.conf REPOS_ROOT overrides (stack.sh)" || bad "spechub.local.conf ignored by stack.sh: $got"
out="$("$hub/scripts/bootstrap.sh" facts 2>&1 || true)"   # captured, not piped: grep -q would SIGPIPE the script under pipefail
case "$out" in *"does not exist"*) ok "spechub.local.conf REPOS_ROOT overrides (bootstrap.sh facts looks there)" ;;
  *) bad "bootstrap.sh facts did not read spechub.local.conf: $(printf '%s' "$out" | tail -1)" ;; esac
out="$(SPECHUB_REPOS_ROOT="$root" "$hub/scripts/bootstrap.sh" facts 2>&1 || true)"
case "$out" in *"does not exist"*) ok "spechub.local.conf wins over SPECHUB_REPOS_ROOT (the lasting setup)" ;;
  *) bad "SPECHUB_REPOS_ROOT overrode spechub.local.conf: $(printf '%s' "$out" | tail -1)" ;; esac
rm -f "$hub/spechub.local.conf"
"$hub/scripts/bootstrap.sh" facts >/dev/null 2>&1 || bad "bootstrap.sh facts failed after removing the override"

# 5. ignored files
printf 'PORT_OFFSET="10000"\n' > "$hub/spechub.local.conf"; mkdir -p "$hub/.run" "$hub/.logs" "$hub/.dispatch"
touch "$hub/.run/x.pid" "$hub/.logs/x.log" "$hub/.dispatch/x" "$hub/.DS_Store" "$hub/bootstrap/.DS_Store"
stray="$(git -C "$hub" status --porcelain --untracked-files=all | grep -E 'spechub\.local\.conf|\.run/|\.logs/|\.dispatch/|\.DS_Store' || true)"
[ -z "$stray" ] && ok "spechub.local.conf, .run/, .logs/, .dispatch/, .DS_Store are gitignored" || { bad "not ignored:"; printf '%s\n' "$stray" | sed 's/^/        /'; }
rm -f "$hub/spechub.local.conf" "$hub/.DS_Store" "$hub/bootstrap/.DS_Store"

# 6. the gate passes on the fresh hub (fact sheets included)
git -C "$hub" "${GIT_ID[@]}" add -A >/dev/null && git -C "$hub" "${GIT_ID[@]}" commit -qm "init" >/dev/null
if "$hub/scripts/verify.sh" portable >"$work/verify.log" 2>&1; then ok "verify.sh portable passes"
else bad "verify.sh portable fails:"; grep -E 'FAIL|^        ' "$work/verify.log" | head -8 | sed 's/^/        /'; fi

# 7. a second instance resolves its own root
if "$hub/scripts/instance.sh" clone "$work/root2" >"$work/instance.log" 2>&1; then
  hub2="$work/root2/hub"
  if [ -x "$hub2/scripts/stack.sh" ]; then
    got="$(phys "$("$hub2/scripts/stack.sh" root)")"
    [ "$got" = "$(phys "$work/root2")" ] && ok "instance.sh clone: the new hub resolves root2, not the source root" || bad "new instance resolves $got, expected $(phys "$work/root2")"
    [ -d "$work/root2/repo-a/.git" ] && ok "instance.sh clone: service repos cloned beside the new hub" || bad "repo-a missing in the new instance"
  else bad "instance.sh clone did not place the hub at $hub2"; fi
else bad "instance.sh clone failed:"; tail -8 "$work/instance.log" | sed 's/^/        /'; fi

printf '\n'
[ "$FAIL" = 0 ] && { printf 'test-portable: PASS\n'; exit 0; } || { printf 'test-portable: FAIL\n'; exit 1; }
