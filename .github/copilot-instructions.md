# Spec Hub — Copilot Instructions

This workspace's operating instructions live in [../AGENTS.md](../AGENTS.md).
Read that file before answering questions or generating any output in this workspace — it defines the workspace purpose, document map, routing rules, split-spec structure, and the workflow for feature design, spec cascading, prompt generation, dispatch and close-out.

The skills in `.github/skills/` (a symlink to `skills/`) are the workflow steps; the custom agents in `.github/agents/` are the subagents two of them fork into. The scripts in `scripts/` run from any terminal; set `AGENT_CLI="copilot"` in `spechub.conf` to have the dispatcher run implementation prompts with the Copilot CLI.
