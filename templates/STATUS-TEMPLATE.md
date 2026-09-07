<!--
  STATUS TEMPLATE → `STATUS.md`
  Written empty by the bootstrap-specs skill (Step 0). A row is added in Step 2a (Pending) and
  flipped to complete + moved to Shipped in Step 4c. Notes are ONE line. No history here.
  Per-service state cell: 🔄 Pending · ✅ Complete · ⏸ Staled · N/A
-->

# {Project Name} — Feature Status Board

> **Live status of every in-flight and shipped feature.** This is the table flipped to complete in Step 4 of `WORKFLOW.md`. Check this file (instead of the full overview) for feature state.

**Notes are one line max.** Implementation detail lives in `CHANGELOG.md` (dated entries, newest first) and in the archived design docs in `Features/Implemented/`. Do not paste close-out summaries into this board.

The board has two sections: **In Flight** (design or implementation pending) and **Shipped** (nothing pending). Step 4 moves a finished row into Shipped with a one-line note. Feature numbers are sequential and never reused.

---

## In Flight

| # | Feature | Services (state per service) | Notes |
|---|---------|------------------------------|-------|
| 1 | {Feature} | `{service}` 🔄 · `{service}` 🔄 | See `Features/FEATURE-{name}.md` |

## Shipped

| # | Feature | Services (state per service) | Notes |
|---|---------|------------------------------|-------|
