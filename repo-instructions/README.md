# Canonical Repo Instruction Files

This folder holds the **canonical copy** of each service repo's agent instruction file (`AGENTS.md` in the repo root — read by Codex, Copilot and most agents; `CLAUDE.md` holds one line, `@AGENTS.md`, so Claude Code imports it; `.github/copilot-instructions.md` points at it). The per-repo instruction file is the one artifact that can silently drift from the hub's `CONVENTIONS.md` — keeping the canon here closes that gap.

## Rules

- One file per code service: `{service}.md`, using the service identifiers from `spechub.conf`.
- Content is **stable, repo-wide conventions only** — stack, naming rules, module layout, env var names, build/test/lint commands. Never feature-level detail; features reach a repo through a prompt, not through the instructions file.
- **Edit here first, then copy into the repo.** Never edit the file inside a service repo directly.
- WORKFLOW.md Step 4g: when a feature changes a shared convention, update `CONVENTIONS.md`, update the affected file(s) here, and copy them into the repo(s) in the same pass.

## Seeding

Step 0 (`bootstrap-specs`) seeds this folder: a repo that already has an instruction file gets it copied here verbatim (banner prepended); a repo without one gets a file generated from `_TEMPLATE.md` and the spec's stack facts. After Step 0, copy each file into its repo:

```bash
cp repo-instructions/api.md /path/to/api/AGENTS.md
printf '@AGENTS.md\n' > /path/to/api/CLAUDE.md
```

## Template

See `_TEMPLATE.md` for the expected shape.
