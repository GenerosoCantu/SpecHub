#!/usr/bin/env bash
# scripts/models.sh — keep the tier pins and metrics/prices.tsv in step with Anthropic's lineup.
#
#   scripts/models.sh check [--hook]   compare the live pricing page with metrics/prices.tsv and the
#                                      tier pins in spechub.conf; print every drift (exit 1 if any)
#                                      --hook: at most once every 7 days, silent unless something
#                                      changed, never fails (the SessionStart hook)
#   scripts/models.sh upgrade [--apply]
#                                      print what `check` found as a plan; --apply carries it out:
#                                      re-prices drifted rows, prices new models, moves each tier
#                                      pin to the newest model of its family (spechub.conf and
#                                      spechub.conf.example, the `model:` line of .claude/agents/*.md,
#                                      WORKFLOW-CHEATSHEET.md)
#
# Tiers map to families: Light = Haiku, Standard = Sonnet, Advanced = Opus. Fable and Mythos are
# priced but never pinned to a tier. A pin moves only with `upgrade --apply` — never on its own — so
# a model release is a moment someone chose, and runs on either side of it stay comparable.
# Price changes re-price all of history on the next `metrics.sh render`, hub sessions and dispatch
# runs alike. Source: https://platform.claude.com/docs/en/about-claude/pricing.md

set -euo pipefail
HUB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export HUB_DIR
# shellcheck disable=SC1091
. "$HUB_DIR/scripts/python.sh"

case "${1:-}" in
  check|upgrade)
    hub_python "$HUB_DIR/scripts/models.py" "$@" ;;
  *) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
