#!/usr/bin/env bash
# scripts/metrics.sh — WORKFLOW.md observability: one ledger, many views.
#
#   scripts/metrics.sh emit <event> [flags]      append one event (called by dispatch.sh, not by hand)
#   scripts/metrics.sh session [--transcript P]  record the hook's hub session, then sync (SessionStart/SessionEnd hooks)
#   scripts/metrics.sh sync [--reparse]          record every hub transcript the ledger lacks or has outgrown
#                                                (--reparse: re-attribute every transcript still on disk)
#   scripts/metrics.sh report [--days N] [--feature SLUG]
#                                                sync, then terminal summary
#   scripts/metrics.sh render                    sync, then (re)write METRICS.md from the ledger
#   scripts/metrics.sh backfill [--dry-run]      seed the ledger from Prompts/, .dispatch/runs/ and transcripts
#   scripts/metrics.sh selftest                  prove the derived cost formula against every reported cost
#   scripts/metrics.sh archive <YYYY-MM-DD>      roll older lines into archive/metrics-ledger-archive.jsonl
#   scripts/metrics.sh prices [--hook]           list ledger models with no price row (exit 1 if any;
#                                                --hook: tell the session to add them, exit 0)
#   scripts/metrics.sh price <model> <in> <out> [cread_mult]
#                                                add/replace a metrics/prices.tsv row, verified today
#
# The ledger is metrics/ledger.jsonl — append-only, committed, machine-read. METRICS.md is generated
# from it. Neither is ever opened in a model session: both are written and read by this script.
#
# Every dollar the views show is DERIVED: stored token counts priced at today's metrics/prices.tsv,
# for hub sessions and dispatch runs alike. The ledger also keeps the cost the agent CLI REPORTED
# for each dispatch run; `selftest` proves the derivation reproduces it.
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
# shellcheck disable=SC1091
. "$HUB_DIR/scripts/python.sh"

case "${1:-}" in
  emit|session|sync|report|render|backfill|selftest|archive|prices|price)
    hub_python "$HUB_DIR/scripts/metrics.py" "$@" ;;
  *) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
