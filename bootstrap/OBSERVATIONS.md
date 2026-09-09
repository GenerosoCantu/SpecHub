# Bootstrap Observations

Append-only log of cases where a template rule did not decide the outcome, so a later run does not
have to rediscover them.

**Step 0 never edits a template.** A run that rewrites its own contract makes the next run
incomparable to it: two earlier runs each hit a real ambiguity, each patched
`templates/SERVICE-SPEC-TEMPLATE.md` with its own fix, and neither could see the other's. Writers
report `AMBIGUITIES`, the session appends them here, and promoting one into a `D` rule is a human
step taken *between* runs.

Format — one entry, newest first:

```
## YYYY-MM-DD — {service} — {the rule that did not decide it}
- Readings: {A} vs {B}
- Taken: {which, and why the source supports it}
- Proposed rule: {one line, or "none — one-off"}
```

---

_No observations logged yet._
