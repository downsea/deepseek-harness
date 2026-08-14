# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repo.

@AGENTS.md

The import above is the public, load-bearing agent contract (the same file
`packages/CLAUDE.md` and `examples/CLAUDE.md` still symlink). **For anything
repo-conventional (layout, gates, testing, docs, commit/PR discipline),
AGENTS.md wins; the sections below only add the host-local half** per
`~/code/claude-template.md`, and must never duplicate or contradict it.
(Merged from the former gitignored `CLAUDE.local.md`, 2026-08-14.)

## Project ledger (kms)

`~/Documents/Vault/20-Projects/Active/deepseek-harness.md` — read before
substantial work; update on session-end per vault
`30-Areas/Technology/project-tracking.md` SOP (收工三件事: `kms project log` →
`kms daily log --proj deepseek-harness` → cross-project decisions to
`80-Meta/Decision-Log.md`). Theory base for this repo (Cordiverse paper) is
ingested: vault `70-Wiki/cordis-meta-framework.md` + 3 sibling pages.

## Doc-flow mapping (template → this repo)

This repo has its own constitutional system — do **not** create the template's
default trees here:

| Template concept | This repo's home |
|---|---|
| `docs/<proj>-architecture.md` | `docs/architecture.md` (read before changing `packages/`) |
| `docs/adr/` (decisions) | `.agents/notes/` Agent Notes (same-PR rule in AGENTS.md) |
| `docs/research/` | Agent Notes + `docs/` per [docs/AGENTS.md](docs/AGENTS.md) |
| `docs/issues/` file tracker | 本地 `.issues-local/`（见下节；fork 无 GitHub issues）；上游通道可用时再 `gh` 上报 |

## Session orchestration

Main session = orchestrator: requirement shaping, decisions, spec-writing,
result verification (re-run the gate yourself before committing), commits/pushes,
ledger + daily records. Research sweeps and implementation batches go to
sub-agents by default (inherit session model); trivial one-liners stay in the
main session. Every sub-agent task spec names required reading — **AGENTS.md
first**, plus docs/architecture.md and the relevant Agent Notes — states
environment traps (coverage gate is `test:coverage` not `test`; e2e self-skips
without `DEEPSEEK_API_KEY`; snapshot fixtures must replay cross-platform),
draws hard boundaries (no commits; root `.env` read-only), and defines the
return format. Interrupted agents are resumed from transcript, never restarted
over a live tree.

## Usage-time feedback

When using `dsh` as a tool (any session, any repo) and hitting a bug or missing
capability: file it at discovery time, before working around it; the issue
names the workaround. **This fork has GitHub issues disabled** — file to the
local tracker below; upstream-worthy items get re-filed upstream when a
channel exists.

## Local issue tracker

`.issues-local/NNN-<slug>.md` — file-based, per `~/code/claude-template.md`
Appendix B (Status/Severity/Labels/Context/Items/Exit; append-mostly;
`closed-verified` means exit criteria re-run). The directory is **local-only**:
ignored via `.git/info/exclude` (not `.gitignore` — that file is upstream's),
so it never appears in commits or `git status`. Issue numbering is 3-digit
sequential. Development of a local issue happens on a `local/NNN-<slug>`
branch off master; main session verifies gates and commits per AGENTS.md.

## Build-cache / disk hygiene

`node_modules/` + per-package `lib/` + VitePress build are the bulk here. At
iteration wrap-up with no immediate rebuild planned: `pnpm run clean` (repo) /
`fed clean --apply` (machine-wide). Before big builds check the real water
level per `~/tools/TOOLS.md`; a full disk is data corruption, not slowness.
After a purge, rebuild before triaging built-`lib/` smoke failures as code
defects.

## Commit attribution

Attribution is disabled globally: do not add `Co-Authored-By` / generated-with
footers to commits or PR bodies unless explicitly asked.
