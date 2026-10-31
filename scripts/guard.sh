#!/usr/bin/env bash
# scripts/guard.sh — PreToolUse hook: enforces two AGENTS.md "Context Budget" rules in every session.
#
#   1. Never open CHANGELOG.md, METRICS.md or metrics/ledger.jsonl (Read, Grep, Bash).
#      The sanctioned surfaces are scripts/changelog.sh add, scripts/metrics.sh report / render.
#   2. Never edit a template, SPEC-GUIDELINES.md or AGENTS.md (Edit, Write, and writing Bash commands).
#      Those files are the contract a workflow run is compared against; a human edits them between runs,
#      from the editor or a plain shell (hooks only see Claude Code tool calls).
#
# Wired in .claude/settings.json under hooks.PreToolUse. Reads the hook JSON on stdin, exits 2 to refuse
# (stderr is shown to the session as the reason), exits 0 to allow. Matching is by path substring, so a
# command that merely mentions a protected file (e.g. `git log -- CHANGELOG.md`) is refused too — say so
# and use the sanctioned script. Hook 2 blocks Bash only when the command both names a protected path and
# carries a write operator (>, >>, sed -i, tee, mv, cp, rm); reading a template with sed -n stays allowed.
#
# Escape hatch for framework work: SPECHUB_GUARD=off in the environment of the Claude Code process
# (e.g. `SPECHUB_GUARD=off claude`) disables both rules for that session. Never set it from a workflow step.

[ "${SPECHUB_GUARD:-on}" = "off" ] && exit 0

# shellcheck disable=SC1091
. "$(dirname "$0")/python.sh"
# -I ignores the environment, so UTF-8 (the hook JSON carries file contents) is asked for with -X utf8.
hub_python -I -X utf8 "$(dirname "$0")/guard.py" "${CLAUDE_PROJECT_DIR:-$PWD}"
