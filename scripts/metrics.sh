#!/usr/bin/env bash
# scripts/metrics.sh — WORKFLOW.md observability: one ledger, many views.
#
#   scripts/metrics.sh emit <event> [flags]      append one event (called by dispatch.sh, not by hand)
#   scripts/metrics.sh session [--transcript P]  record the hook's hub session, then sync (SessionStart/SessionEnd hooks)
#   scripts/metrics.sh sync                      record every hub transcript the ledger lacks or has outgrown
#   scripts/metrics.sh report [--days N] [--feature SLUG]
#                                                sync, then terminal summary
#   scripts/metrics.sh render                    sync, then (re)write METRICS.md from the ledger
#   scripts/metrics.sh backfill [--dry-run]      seed the ledger from Prompts/, .dispatch/runs/ and transcripts
#   scripts/metrics.sh selftest                  prove the derived cost formula against every reported cost
#   scripts/metrics.sh archive <YYYY-MM-DD>      roll older lines into archive/metrics-ledger-archive.jsonl
#
# The ledger is metrics/ledger.jsonl — append-only, committed, machine-read. METRICS.md is generated
# from it. Neither is ever opened in a model session: both are written and read by this script.
#
# Dispatch-run costs are REPORTED by the agent CLI. Hub-session costs are DERIVED from token counts
# via metrics/prices.tsv; `selftest` proves that derivation reproduces reported costs exactly.
# A hub session is its Claude Code transcript plus the subagent transcripts forked from it (the
# hub-ops fork of Steps 3/4, Explore agents, spec-writers). Recording is a reconciliation, not an
# event: the hooks, `sync`, `report` and `render` each record whatever transcript on disk the
# ledger lacks or has outgrown, so a session whose SessionEnd hook never fired is still counted.
#
# Emitting never fails a caller: `emit` and `session` exit 0 even when they cannot record, so a
# broken ledger can never break a dispatch run or end-of-session hook.

set -euo pipefail
HUB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export HUB_DIR

case "${1:-}" in
  emit|session|sync|report|render|backfill|selftest|archive)
    exec python3 "$HUB_DIR/scripts/metrics.py" "$@" ;;
  *) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
