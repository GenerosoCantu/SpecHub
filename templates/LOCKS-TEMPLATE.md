<!--
  LOCKS TEMPLATE → `LOCKS.md`
  Written by scripts/lock.sh on the first intend/claim (the project name comes from spechub.conf).
  Every row is written by that script (intend / claim / release), never by hand. One row per feature
  that is being designed against, or holds, spec files; a row lives from the start of design to
  close-out. No history here.
-->

# {Project Name} — Spec Locks

> **Who is designing against, or holding, which spec file right now.** A row has two states. **designing** — posted by the design session as its first action (Step 1, `scripts/lock.sh intend`): a notice, coarse (services are fine), blocking nobody; overlapping rows warn each other so the designers talk on day one. **held** — set by the cascade (Step 2a, `scripts/lock.sh claim`) on the exact module files it edits, upgrading the intent: from here to close-out the spec is half-written, so another feature's hold on the same file is refused (a design against it is only warned). Dropped at close-out (Step 4) or when the feature is staled or its design abandoned (`scripts/lock.sh release`). Rows go through origin like feature numbers, so every instance of the stack sees the same board. Advisory: nothing stops an edit, the skills stop at `scripts/lock.sh check`.

A spec file is a module file (`NN-{service}/{module}.md`), a whole service (`NN-{service}.md` — its single file, or the index plus every module under it), or a shared document (`CONVENTIONS.md`, `00-architecture-overview.md`). A whole-service row overlaps every module under it and vice versa. Two features on different modules of one service do not overlap.

| Feature | State | Spec files | By | Since | Note |
|---|---|---|---|---|---|
