# Graphify in a Spec-Driven Development Framework: Evaluation

> **Status:** Evaluated 2026-09-30. **Not adopted.**
> **Context:** SpecHub is a spec-driven development framework for AI coding agents. This document records why Graphify was not added to it, written so that teams building a similar framework can reuse the reasoning.
> **Basis:** A desk study of Graphify's README and one month of measured usage from a production project run with SpecHub. Nothing was installed. Section 10 lists what was not verified.

## 1. Summary

**Question:** Would adding Graphify to the framework reduce token spend or improve results?

**Answer:** No. There are three reasons, in order of weight.

1. **Merge conflicts.** Graphify keeps one generated graph file per repository and recommends committing it. A framework that runs coding agents in parallel on separate branches rewrites that file on every branch, so merges conflict as a matter of routine (section 4).
2. **Wrong cost.** Graphify saves the tokens an agent spends finding its way around a codebase. In a spec-driven framework the specs already do that job, and the measured spend is elsewhere (section 5).
3. **Conflicting principles.** A model-inferred graph of the specs competes with the specs as the source of truth (section 6).

One option survives the analysis: a graph kept on each developer's machine and never committed. Section 8 weighs its pros and cons. Section 9 helps you judge whether the conclusion applies to your own framework.

## 2. Background: how SpecHub works

You need only this much to follow the argument.

SpecHub keeps a **hub**: a git repository of markdown specifications, one per service. The specs are the source of truth for what each service does. The application code lives in separate **service repositories**. The project measured here has eight of them, all TypeScript.

Every feature moves through the same steps. Each step runs in a fresh agent session so that no session carries a large context.

| Step | What happens |
|---|---|
| **Design** | A person and an agent write a short feature document. When they need facts from the code, a read-only subagent reads the service repository and returns a summary |
| **Spec update and prompts** | The feature is written into the affected specs. One implementation prompt per affected service is generated from the updated spec. Each prompt names the files to change and the contracts to honor |
| **Parallel implementation** | Every prompt runs as an unattended ("headless") agent session. Each session gets its own **git worktree**: a separate working folder on its own branch of the service repository. All sessions run at the same time, and each commits to its branch |
| **Human verification** | A person tests the result of each session |
| **Close-out** | Each verified branch is merged into the main branch. The specs are then corrected to match what was actually built |

Two properties of this design matter for Graphify:

- **Many branches of the same repository are alive at once.** Parallel sessions, several features in flight, and several developers all produce branches that are merged later.
- **Context is budgeted.** Agents are told exactly which files to read. Exploring the codebase freely is the exception, not the norm.

## 3. What Graphify is

Graphify (`safishamsi/graphify` on GitHub) turns a folder into a knowledge graph. A coding agent then queries the graph instead of reading and searching files.

| Aspect | Behavior |
|---|---|
| Output | A `graphify-out/` folder holding `graph.json` (the graph), a markdown report and an HTML view |
| Source code | Parsed locally into a syntax tree. Deterministic, no model calls |
| Documents, PDFs, images | Extracted by a language model. This costs tokens and is not deterministic |
| Edges | Each is tagged as extracted, inferred or ambiguous |
| Agent wiring | The installer adds an instruction to the agent's instruction file and a hook that fires before every file read and search. A strict mode blocks the first direct file read of a session |
| Keeping it fresh | Git hooks rebuild the graph after every commit and every checkout. A watch mode rebuilds continuously |
| Sharing | The README recommends **committing `graphify-out/`** so one person builds the graph and everyone else pulls it |

Graphify's model is one working folder, one writer, and one shared graph. That is the root of the problem below.

## 4. Problem 1: merge conflicts (the blocking problem)

The graph is a single generated file that describes the whole repository. Any branch that changes code also changes the graph. When two branches of one repository exist at the same time, both rewrite the same file, and the second one to merge conflicts.

In this framework that situation is normal, not rare. The measured project shipped 32 features in 25 days across eight repositories, with implementation sessions running in parallel.

| # | Problem | Why it happens | Effect on the workflow |
|---|---|---|---|
| 1 | **Overlapping branches conflict on the graph file** | Each branch commits its own rebuilt `graph.json`. Git cannot reconcile two versions of a generated file | The merge at close-out stops and waits for a person to resolve a conflict in a file nobody wrote |
| 2 | **The conflict has no correct manual resolution** | Combining two graphs line by line does not produce the graph of the combined code, and may not even produce valid JSON. The only correct fix is to discard both and rebuild | Every merge would need an automatic rebuild step and a custom merge rule in every repository |
| 3 | **The rebuild hooks fire in every worktree** | Git shares hooks between a repository and all of its worktrees. The checkout hook runs when a worktree is created, and the commit hook runs on every commit an agent makes | Every parallel session rebuilds the graph on start and again on each commit. This is wasted work and causes problem 4 |
| 4 | **Rebuilds leave uncommitted changes** | The hook regenerates the graph after the commit is already made, so the working folder is never clean | The framework refuses to merge a branch whose folder has uncommitted changes, so close-out is blocked |
| 5 | **Noise in every review** | The graph file appears in every diff | Close-out compares the merged code against the spec and must account for every changed file. A generated file adds noise to each review |

Two more problems sit beside the merge path:

- **Unattended sessions commit unpredictably.** An agent told to commit its work may or may not include the graph folder. The same prompt can produce different branch contents from one run to the next.
- **The graph is stale by design.** A graph taken from the main branch describes the main branch. Inside a worktree it is wrong as soon as the agent edits code, which is exactly when the agent relies on it.

**Excluding the graph folder from git** removes problems 1, 2, 4 and 5. It also removes Graphify's sharing model. Every developer, every checkout and every new worktree then needs its own build, and problem 3 remains unless the hooks are left out as well.

## 5. Problem 2: it saves the wrong tokens

Graphify reduces the cost of **discovery**: an agent reading and searching to learn where things are. The measurements show discovery is not where this framework spends.

Usage over 25 days, covering 32 features, 112 implementation sessions and 148 hub sessions. Shares are of total token value at public list prices.

| Where the spend goes | Share |
|---|---|
| Hub sessions: design, spec updates, orchestration, close-out | 69% |
| Parallel implementation sessions | 31% |
| Re-reading existing context on each turn, across both | 43% |
| The design step alone | 18% |
| Ad hoc sessions outside the workflow | 21% |

- **Implementation sessions have little to discover.** Their prompts already name the files to change. The median session lasts two minutes.
- **Hub sessions read specs, not code.** Each spec has an index that points to the one module file a task needs. That routing is already exact.
- **Code reading is already isolated.** It happens in a subagent that returns a summary, so the files never enter the expensive session. It is only a part of the 18% design share.
- **The dominant cost is context re-read.** Long sessions pay for their whole context again on every turn. A graph does not change that.

## 6. Problem 3: it conflicts with the framework's principles

| Principle | Conflict |
|---|---|
| **The markdown specs are the source of truth** | A graph built from the specs is a second copy of them, inferred by a model and rebuilt after every spec change. Two representations can disagree |
| **Generated artifacts must be reproducible** | Graphify extracts documents with a model, and marks some edges as inferred. Two runs can differ |
| **One instruction file for every agent tool** | The framework supports several agent tools through one shared instruction file. Graphify's installer writes its own instruction into a tool-specific file |
| **Agents read only what the task lists** | The hook injects text before every read and search in every session. Strict mode blocks the first listed read |
| **Cross-service behavior must be evidenced** | Calls between services go over HTTP. These are not syntax-tree edges, so the graph does not show the seams that matter most in a multi-service system |

## 7. Decision

| # | Decision | Reason |
|---|---|---|
| 1 | Do not build a graph of the spec hub | Sections 5 and 6 |
| 2 | Do not commit the graph folder in any service repository, and do not install the git hooks | Section 4 |
| 3 | Do not run the Graphify installer | Section 6 |
| 4 | Do not make Graphify part of the framework | The remaining benefit does not pay for the changes needed to the merge and close-out tooling |

**What survives.** A graph kept local and out of git, used only for code reading during design. Section 8 weighs it. It is a permitted trial, not part of the framework.

## 8. Option: a local, uncommitted graph

The setup: each developer builds one graph per service repository on their own machine, from the main branch, and the output folder is listed in the repository's git ignore file. No git hooks, no read hook, no strict mode. Only the read-only subagent that reads code during design queries it.

### Pros

| Pro | Why |
|---|---|
| **No merge conflicts** | The graph file never reaches a branch, so there is nothing to collide at merge. Problems 1 and 2 of section 4 disappear |
| **No blocked merges** | Git ignores the folder, so a rebuilt graph never counts as an uncommitted change. Problem 4 disappears |
| **No review noise** | The graph never appears in a diff. Problem 5 disappears |
| **Free to build for code** | Source code is parsed locally into a syntax tree with no model calls. Rebuilding costs time, not tokens |
| **Better answers to structural questions** | "What calls this function" and "what does this module import" are answered from explicit edges instead of a series of searches. That is the kind of question design asks |
| **Isolated from the workflow** | Nothing in the merge, close-out or dispatch tooling changes. Removing the trial is deleting a folder |
| **Easy to measure** | The design step is already measured per feature, so the effect can be compared against the baseline in section 5 |

### Cons

| Con | Why |
|---|---|
| **The gain is bounded** | It helps only where an agent explores code: design reconnaissance and ad hoc questions. That is a part of the 18% design share, not the 43% spent re-reading context |
| **Implementation sessions do not benefit** | A new worktree does not contain ignored files, so the parallel sessions never see the graph. They also do not need it, because their prompts name the files |
| **Staleness is the developer's job** | The graph describes the main branch at build time. It must be rebuilt after every merge and every pull, or it describes code that no longer exists |
| **Nothing is shared** | Graphify's team model is one build, everyone pulls. Local-only means every developer and every machine builds every repository once, and again after each rebuild trigger |
| **Hooks stay off** | The commit and checkout hooks are shared with every worktree and would rebuild the graph inside each parallel session. A user-level read hook would also fire inside the unattended sessions, where no graph exists |
| **Cross-service calls stay invisible** | The graph holds imports and calls inside one repository. HTTP calls between services, the seams that matter most in a multi-service system, are not in it |
| **Specs stay out** | Extracting the markdown specs goes through a model, costs tokens and is not reproducible. The graph covers code only |
| **Another tool to install** | A Python tool installed per machine, with its own version drift, for a subagent that already works without it |

### How to run it as a trial

1. Build one graph per service repository from the main checkout. Add the output folder to that repository's ignore file.
2. Rebuild after every merge and every pull. Tie it to whatever step already updates the checkout, so it is not forgotten.
3. Do not run the installer. Tell the code-reading subagent, in the shared instruction file, that it may query the graph first during design. Close-out keeps reading the real merged diff, because the graph is stale at that point.
4. Run about ten features and compare the design step's token use against the baseline in section 5. Keep the graph only if the drop is clear; otherwise delete the folder.

## 9. Does this apply to your framework?

The conclusion depends on how your framework works, not on Graphify's quality. The tool is sound for what it was designed for.

**The conclusion holds if:**

- agents work in parallel on separate branches or worktrees of the same repository;
- merges are automated and must not stop for manual conflict resolution;
- specs or prompts already tell the agent which files to read and change;
- specs are the source of truth, and generated artifacts must be reproducible.

**Graphify may earn its place if:**

- one agent works in one working folder at a time;
- agents explore large, unfamiliar codebases with no specs to guide them;
- the graph stays out of git and is rebuilt locally, accepting that each developer pays for the build (section 8).

Before adopting any tool that writes a shared generated file into the repository, ask what happens when two branches both regenerate it.

## 10. Not verified

- Nothing was installed. Graphify's behavior is taken from its README, not from a run against real repositories.
- The git behavior in section 4 (shared hooks, the checkout hook firing when a worktree is created) is standard git. Whether Graphify's hook writes into the worktree it fires in was not tested.
- The share of the design step spent on code reading is not measured separately.

## Sources

- Graphify repository and README: https://github.com/safishamsi/graphify
- Graphify and Claude Code integration: https://graphify.net/graphify-claude-code-integration.html
- Usage figures: the framework's own metrics ledger, 2026-09-06 to 2026-09-30
