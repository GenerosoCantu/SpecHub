# BUG — {Name}

**Status:** Pending (design)
**Class:** {A — code diverges from spec | B — spec is wrong or silent}
**Scope:** {affected service identifiers, from spechub.conf}
**Implementation order:** {service → service, or "single service"}

> **Size budget:** ≤ 8 KB. A bug file records a defect and its fix contract, not a design essay. Use this file only for a defect in **merged, closed** work — a defect in a prompt that is still `Applied` is fixed with `scripts/dispatch.sh resume <prompt> "<fix>"` instead. Code reconnaissance goes to an `Explore` subagent; do not paste source files here.

## Observed behavior

{What happens, where (service, route/view/endpoint), with which input. Error text or status code verbatim.}

## Expected behavior

{What should happen. **Class A:** cite the spec passage that already states it — `NN-{service}.md` / `NN-{service}/{module}.md` → section. **Class B:** state the corrected behavior; it becomes the spec change below.}

## Reproduction

1. {Step}
2. {Step}

## Suspected cause

{File(s) and function(s), from reconnaissance — or "unknown". One short paragraph.}

## Spec change

{**Class A:** "None — the spec is correct; the code is brought back to it." **Class B:** the corrected contract (field, endpoint, validation rule, UX state) exactly as it must read in the spec, per service.}

## Regression test

{The test the fix must add, per service: what it exercises and that it fails before the fix.}

## Open questions

- {Must be empty before Step 2.}

## Recommended model tier (per service)

- {service}: {Light | Standard | Advanced} — {one-line reason}

## Outstanding work (checklist)

- [ ] Class B only: cascade the corrected contract into {spec / module file(s)} as PENDING (Step 2a)
- [ ] Add row to STATUS.md
- [ ] Generate Prompts/PROMPT-{service}-{bug-name}.md (Step 2b, same session)
