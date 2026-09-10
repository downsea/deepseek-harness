# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repo.

@AGENTS.md

The import above is the public, load-bearing agent contract (the same file
`packages/CLAUDE.md` and `examples/CLAUDE.md` symlink). **For anything
repo-conventional (layout, gates, testing, docs, commit/PR discipline),
AGENTS.md wins; the sections below only add the host-local half** per
`~/code/claude-template.md`, and must never duplicate or contradict it.

## Constitutional references

This repo has its own constitutional system — do **not** create the template's
default trees here. Template concept → this repo's home:

| Template concept | This repo's home |
|---|---|
| Positioning / design philosophy | root `AGENTS.md` (identity line, pre-release stance, Conventions) + [docs/defensive-patterns.md](docs/defensive-patterns.md) |
| `docs/<proj>-architecture.md` | [docs/architecture.md](docs/architecture.md) (read before changing `packages/`); per-subsystem detail in [docs/subsystems/](docs/subsystems/README.md) |
| `docs/adr/` (decisions) | `.agents/notes/{proposed,implemented,rejected}/{class}/yyyy-mm-dd-topic.md` Agent Notes (same-PR rule + format gate in [.agents/notes/README.md](.agents/notes/README.md)); `archived/` is frozen history |
| `docs/research/` | Upstream-worthy: an Agent Note in `proposed/`. Cross-stack (dsh × aeu / atd / mem): `~/code/agent-native-stack/docs/research/` (e.g. `2026-08-14-dsh-deep-study/`, `2026-08-19-dsh-rc7-recheck.md`). Local-only: the issue's Context in `.issues-local/` |
| `docs/issues/` file tracker | `.issues-local/`（见下节；fork 的 GitHub issues 关闭）；上游通道可用时再 `gh` 上报 |
| Stable contracts | None until the first tagged release (AGENTS.md "Pre-release stance": `SESSION_FORMAT_VERSION` 0, no compatibility promise) |
| Doc standard | [docs/AGENTS.md](docs/AGENTS.md) — tiers, one home per fact, bilingual pairing, word budgets |

Project ledger (cross-session progress): `20-Projects/Active/deepseek-harness.md`
under the kms default vault, resolved by `kms vault path` on every host — never a
hardcoded home path. Read it before substantial work (the SessionStart hook injects
现状 + 下一步); update at session end per the vault's
`30-Areas/Technology/project-tracking.md` (收工三件事: `kms project log deepseek-harness`
→ `kms daily log --proj deepseek-harness` → cross-project decisions to
`80-Meta/Decision-Log.md`). Theory base (Cordiverse paper) is ingested: vault
`70-Wiki/cordis-meta-framework.md` + 3 sibling pages.

## Research → dev

Non-trivial work is research-first: findings are written down **before**
implementation, never left in chat history. The doc is what a cold agent reads to
understand why the design is shaped as it is.

**Doc flow:** research (Agent Note `proposed/`, or an agent-native-stack research doc)
→ decision (Agent Note `implemented/`, same PR as the code) → work (`.issues-local/NNN`)
→ source + `docs/architecture.md` + the owning subsystems page.

**Naming:** one dated file — Agent Notes already encode it
(`{lifecycle}/{class}/yyyy-mm-dd-topic-title.md`, date = first proposed, gated by
`verify-agent-note-format`); agent-native-stack uses `YYYY-MM-DD-<slug>.md`. A dated
**directory** with a numbered `NN-<slug>.md` series is reserved for a huge epic (next
section) or a deliberately ordered series where later parts depend on earlier findings
(`2026-08-14-dsh-deep-study/` is one).

**Mandatory for:** a new capability seam or provider · adopting an external protocol or
library · anything that will become an Agent Note · a build-vs-reuse fork (AGENTS.md
"dependencies over hand-rolling"). **Not for:** bugfixes, mechanical refactors, and work
an existing Agent Note already covers — cite it.

Findings are host-shaped: say which host a finding was verified on (this checkout is
oh-vm, an aarch64 openEuler container) and name the ones it wasn't. Fixtures must replay
on macOS/Linux regardless.

## Work units — task · epic · huge epic

Three sizes. The size decides the ceremony; pick it at the start and state it in the
issue's `Size:` line.

| Unit | Shape | Tracked by | Exit |
|---|---|---|---|
| **Task** | One issue, a few commits on one `local/NNN-<slug>` branch | `.issues-local/NNN` | The issue's `## Exit` |
| **Epic** | One goal, several issues, one research doc (or Agent Notes cited), one or more sub-agent waves | An umbrella local issue + the research doc | The umbrella issue's `## Exit` |
| **Huge epic** | Several epics aimed at one very big goal: a new seam family, a port, a rewrite | An umbrella local issue + `.issues-local/YYYY-MM-DD-<slug>/` with an epic SOT (`00-epic-sot.md`, skeleton in `~/code/claude-template.md` Appendix D) | Human end-to-end evaluation on a real dsh session |

The test for "huge" is not size: no existing gate can verify the goal, so the epic needs
its own metrics. The epic directory lives beside the tracker, not under `docs/`,
because committed docs are under upstream's doc gates (bilingual triplets, budgets,
`verify-md-links`) — the same reason the tracker is local.

### Huge epic protocol

Steps are ordered; a later step never starts before the earlier one is recorded.

1. **Charter.** Open the umbrella issue and the directory. The date is the day the
   epic opens; the directory is never renamed. It holds `README.md` (index of every
   doc, its status, known disagreements) and `00-epic-sot.md`. The SOT is the single
   source of truth: read it before touching anything, update it after.
2. **Research wave.** Every research doc for the epic lives in the directory as the
   next `NN-<slug>.md`, including mid-epic ones. Sub-agents research in parallel; the
   orchestrator adjudicates disagreements in the SOT, not in the docs.
3. **Metrics before code.** Before the first dev wave the SOT's `## Metrics` table is
   agreed with the human: id, what it measures, the exact command, the baseline
   measured now, the target, who judges it.
   - **Wave metrics** — the orchestrator computes them from the tree: focused vitest
     count, per-file 100% coverage on the changed `src/`, `doc-sync` PASS,
     `typecheck` / `lint` exit 0, snapshot replay (issue 001's Exit is the model).
   - **Exit metrics** — only a human on a real session can judge: a real-API e2e with
     `DEEPSEEK_API_KEY`, a hook round-trip through the dsh Web UI, a canary recall.
     These go in `## Exit`, never in a wave.
   Metrics are frozen once wave 1 starts; changing one is a dated SOT decision.
4. **Dev waves.** Each wave is an epic's worth of work with its own leg(s) in the SOT.
   Per wave: task spec (below) → sub-agents implement → the orchestrator re-runs the
   selected checks and scores every wave metric itself → a dated progress row with
   numbers and commit hashes → commit. A wave that misses a target does not hand off.
5. **Human e2e exit.** After the last wave the human runs the exit metrics and records
   the verdict in the SOT ledger. Findings become local issues; the epic stays open
   until each is fixed and re-verified or deferred by a dated decision.
6. **Delivery.** The fork does not cut versions — `release(dsh): …` commits are
   upstream's. Delivery here is one batch: Agent Note(s) for every SOT decision, SOT
   status → closed with date, umbrella issue → `closed-verified`, upstream-worthy items
   re-filed when a channel exists, ledger + daily updated.

The orchestrator (the main session) owns steps 1, 3, 5, 6 and the scoring in 4.
Sub-agents own the research and implementation batches.

## Session orchestration

The main session orchestrates; sub-agents implement and inherit the session's model.
Pick a cheaper tier only for mechanical batches, never for research, adjudication, or
wave scoring.

- **Main session owns:** requirement shaping, architectural decisions, task specs,
  verification (re-run the selected checks yourself before committing, never on a
  sub-agent's word), commits and pushes, ledger / daily / SOT records, and anything
  touching root `.env`, `~/.claude/settings.json`, or other live user config.
- **Sub-agents own:** research sweeps and implementation batches against the working
  tree.
- **Stays in the main session:** one-liners, doc touch-ups, read-only spot checks.

**Task spec** — what makes a wave land the first time:

1. **Required reading:** **AGENTS.md first**, then `docs/architecture.md`, the relevant
   Agent Notes, the local issue, exemplar source files. The agent reads before it
   touches.
2. **Environment traps:** `test:coverage` not `test` is the coverage gate; e2e
   self-skips without `DEEPSEEK_API_KEY`; snapshot fixtures must replay cross-platform;
   `typecheck` / `lint` / `doc-typecheck` build `lib/types` first — never call a
   `*:contracts-ready` script directly; committed docs are bilingual triplets
   (`.md` + `.zh.md` + `.i18n.yaml`) and `doc-sync` rejects an unpaired edit; the build
   slot rule below, copied verbatim.
3. **Hard boundaries:** no commits (the main session commits after verification); root
   `.env` read-only; `.issues-local/` and the SOT are main-session files; never
   `git stash`.
4. **Return format:** file list, the exact checks run with their numbers, sample
   outputs, and "spec deviations with reasons". Deviations are argued, not silent.
5. **Interrupted ≠ lost.** A sub-agent that died mid-task is resumed from its
   transcript with "check `git status`, reconcile against the spec, continue", never
   restarted over a live tree.
6. **New facts go to the running agent** as a follow-up message, not saved for after.

## What this checkout is

`~/code/deepseek-harness` is **the `downsea` fork of upstream `deepseek-ai/deepseek-harness`,
used for host-local development and research on dsh** (capability seams, session
persistence, the hooks bridge, mem × dsh integration), and nothing more. `origin` is the
fork, `upstream` is DeepSeek's; `master` tracks upstream with local commits re-applied
on top. What dsh itself is, AGENTS.md says.

It is **not** upstream's development line: GitHub issues are disabled on the fork,
releases are upstream's, and upstream-worthy work is re-filed there when a channel
exists. It is not a place for host-only files in git: `start-local.sh` and
`.issues-local/` stay excluded.

## Build & Test

There is no universal local gate here by design. Commands are in AGENTS.md; which ones
to run for a given diff is decided by
[dsh-pre-push-checks](.agents/skills/dsh-pre-push-checks/SKILL.md): the narrowest
test or check that would fail for the regression, `doc-sync` for docs, `build` +
hygiene + the built smoke for published paths, real-API e2e for provider behaviour.
Git hooks are the only automatic baseline — pre-commit: staged lint / whitespace /
vendor manifest guard; pre-push: `pnpm run typecheck`. CI owns the full matrix.

- `pnpm run test:coverage`, not `test` — the CI coverage gate (per-file 100% on
  `packages/*/*/src`; [why](docs/testing.md)). Focus it with
  `--coverage.include='packages/<group>/<pkg>/src/**/*.ts'`.
- `pnpm run test:e2e` self-skips without `DEEPSEEK_API_KEY` (root `.env`) — a green run
  without a key proves nothing.
- `pnpm run doc-sync` — every documentation gate; run it whenever an Agent Note,
  catalog, README, or doc-linked comment changed.
- Never `--passWithNoTests`, lower thresholds, or narrow `--coverage.include` to hide an
  uncovered file.

### One build slot per machine

A compile or test run is a machine-level resource shared across sessions and
sub-agents. Rules, in order:

1. **Before any heavy build or test run:** `pgrep -xa node | rg 'vitest|tsc|tsdown|vite|tsx'`;
   non-empty ⇒ wait and re-check every ~60 s, whoever owns the run. Use `-x`, never
   `pgrep -f` (it matches the waiting shell itself and waiters livelock). The dsh Web
   server and TCP forwarder from `start-local.sh` are also `node` — they are not
   builds; ignore them. Copy this rule verbatim into every sub-agent spec.
2. **One in-flight build per machine.** An orchestrator with N sub-agents still has one
   slot; sub-agents queue on rule 1.
3. **Tell peer sessions.** `ListAgents` lists them. Before a long run send one line
   ("starting pnpm test:coverage, ~N min") and "slot is yours" when done. Busy is not
   building: ask.
4. **Never `git stash` a shared tree.** Another session's uncommitted work rides in it.
   Run checks on the mixed tree or isolate with `git worktree`. A red in a file you
   didn't touch is a concurrent intermediate state: wait and re-run.
5. **Long runs go to the background** with a log in the scratchpad, so the session
   stays responsive while it holds the slot.

### Disk hygiene

`node_modules/` + per-package `lib/` + `coverage/` + the VitePress build are the bulk
here. On this thin-provisioned host a full disk is data corruption, not slowness.

1. **Purge at wrap-up.** No rebuild planned within days ⇒ `pnpm run clean` (repo) /
   `fed clean --apply` (machine-wide).
2. **Check the real water level before a big build** per `~/tools/TOOLS.md`; in this
   guest `df` lies. Below margin ⇒ clean first.
3. **Purges break checks that expect built `lib/`.** Rebuild (`pnpm run build:lib`)
   before triaging a built-`lib/` smoke failure as a code defect. A `node_modules`
   purge is not a free `pnpm install` on oh-vm — native addons (node-pty) needed hand
   steps last time; read the ledger's 2026-08-14 entry first.
4. **Freed space returns to the host late and partially.** Deletion is damage control,
   not a last-second flush.

## Current project state

- **master = upstream `0.1.0-rc.8`** (`f1f7dc36fa`, 2026-08-19) + local commits re-applied:
  `af8b379269` sandbox `writablePaths` (local issue 001, closed-verified) and
  `c75d8163ae` this file. `backup/master-pre-rc7` keeps the pre-rebase line;
  `local/001-*` and `local/claude-md-merge` are its merged feature branches.
- **Active:** mem × dsh integration via the `hooks-claude-code` bridge — usable under
  `workspace-write` with `writablePaths`; `start-local.sh` serves the Web UI at
  VM-IP:3080 for the host browser. Open local issues 002 (SessionStart audit gap +
  first-turn race), 003 (no `PostToolUseFailure` hook point), 004 (extensions doc drift).
- **Dormant:** Cordiverse-paper reusable points → concrete tasks; trigger is the user
  confirming `/paper-to-project` (ledger 下一步).

## Hard rules

- Root `.env` (where `DEEPSEEK_API_KEY` is read from when present) is read-only for
  agents and never printed.
- `.issues-local/` and `start-local.sh` are excluded via `.git/info/exclude` (not
  `.gitignore` — that file is upstream's); they never appear in commits. Do not add
  host-only files anywhere else.
- Local development happens on `local/NNN-<slug>` off `master`; the main session
  verifies and commits per AGENTS.md. No `git stash`, no raw `--force`.
- `vendor/` changes only through the sync procedure in `vendor/README.md`.

## Cross-repo development

mem × dsh work spills into siblings; a gap belongs to the repo that owns it, filed there
and back-linked from the local issue:

| Concern | Owning repo |
|---|---|
| hooks bridge behaviour, sandbox policy, session log | this repo (`.issues-local/`) |
| mem hook scripts, transcript adapter (mem-cli#1), `mem install` | `~/code/mem-cli` |
| cross-stack research (dsh × aeu / atd / mem) | `~/code/agent-native-stack/docs/research/` |

One sub-agent per sibling repo: it reads that repo's `CLAUDE.md` and issue conventions
first and verifies against that repo's gate. Drafts for upstream live in
`~/.dsh-mem/dsh-issue-drafts.md` until a channel exists.

## Usage-time feedback

When using `dsh` as a tool (any session, any repo) and hitting a bug or missing
capability: file it at discovery time, before working around it; the issue names the
workaround. **This fork has GitHub issues disabled** — file to the local tracker below;
upstream-worthy items get re-filed upstream when a channel exists. Name the skill or
job that hit it.

## Local issue tracker

`.issues-local/NNN-<slug>.md` — file-based, per `~/code/claude-template.md`
Appendix B (Status / Severity / Labels / **Size** / Context / Items / Exit; append-mostly;
`closed-verified` means exit criteria re-run). Numbering is 3-digit sequential; the
creation date goes in the `Status:` line. Labels: `needs-triage` / `needs-info` /
`ready-for-agent` / `ready-for-human` / `wontfix`, plus this fork's `upstream-worthy`.
An issue without `## Exit` is `needs-info`.

## Commit style

Upstream's conventional commits, scope = package short name or area:

```
feat(session): …   fix(llm-deepseek): …   docs: …   test: …   refactor: …
chore(local): …    ← host-local-only changes (this file, tracker plumbing)
```

Attribution is disabled globally: do not add `Co-Authored-By` / generated-with
footers to commits or PR bodies unless explicitly asked.

## New work checklist

- [ ] Work sized (task / epic / huge epic) and stated in the local issue; a huge epic
      has its directory, SOT, and agreed metrics **before** wave 1
- [ ] Non-trivial work → an Agent Note (or agent-native-stack research doc) before
      implementation, or an existing one cited
- [ ] Non-trivial change → Agent Note added or updated in the same PR; `packages/`
      behaviour or loop change → `docs/architecture.md` + owning subsystems page
- [ ] Model- or user-visible output changed → keyless snapshot via a real runnable
      example; loop / `SessionEventMap` change → both SDK expected outputs
- [ ] Committed docs edited as bilingual triplets; `pnpm run doc-sync` green
- [ ] Per-file 100% coverage on changed `src/`; every changed acceptance path has a
      rejection case
- [ ] The selected checks pass, run by the main session on the mixed tree
- [ ] Local issue updated (`Size`, Items, Exit); a sibling-repo gap filed there and
      back-linked
- [ ] No secret in a commit, log, or `--dry-run`; no host-only file staged
- [ ] Vault ledger + daily updated (`kms project log deepseek-harness`)
