# CLAUDE.md

Instructions for agents working in this repository, in particular the Super-agent's workers (DeepSeek Harness loads `AGENTS.md`, then this file). `AGENTS.md` is upstream's and stays untouched; where the two disagree for this repository, **this file wins** (overrides in §2).

## 1. What this repository is

- **The experiment SOT `nan/deepseek-harness` on the local Gitea** (`http://127.0.0.1:3000`): upstream DeepSeek Harness at the last adapted `dsh-v*` alpha tag, plus the HarmonyOS (HMOS) delta. `master` = tag + delta, advanced only by merge PRs that the maintainer (`nan`) merges with a merge commit.
- **Gitea only.** `origin` is this Gitea repository; the `upstream` remote, where present, is the Gitea pull mirror of upstream (read-only). Nothing from here goes to GitHub, and you never contact GitHub.
- **Not** the operator's GitHub fork. The operator's own instructions for that fork (vault ledger, `kms`, `.issues-local/`, sub-agent orchestration, GitHub `origin`) stay in the operator's checkout `~/code/deepseek-harness`; none of it applies here, and you neither read nor write that checkout.
- Tracker: **Gitea issues and PRs** of this repository. There is no `.issues-local/`, no vault, no `kms`.

## 2. Overrides of AGENTS.md here

| AGENTS.md says | Here |
|---|---|
| CI owns exhaustive coverage and the platform matrix | **No CI** (Gitea Actions is off). Your local gates (§6) are the only evidence |
| `gh stack sync`, stacked branches, `--force-with-lease` | One branch per Ticket, `agent/<ticket-short-name>`; never force-push |
| `kind/*`, `area/*` labels, native Issue Types | Not in this Gitea; do not create labels |
| PR descriptions via `dsh-pr-description` | Release PRs use the body of skill `hmos-release-adaptation`; other PRs: what, why, evidence |
| `CLAUDE.md` symlinks `AGENTS.md` at root | False here: this file is real |
| Escalate the sandbox for `gh` | `gh` here is the instance's Gitea shim, acting as the agent account |

## 3. The HMOS delta

What makes upstream run natively on the HarmonyOS PC (platform `openharmony`). Review it with `git diff <last-tag> master`.

| Area | Commits | What |
|---|---|---|
| Publish without hard links | `152df123be`, `e0685f90fa` | `packages/util/atomic-write` no-clobber publish; `link()` `EPERM`/`EACCES` = no hard links; attachment fsync stops at the sandbox |
| Platform support | `8a32f6d895` | flock (`native/system`) knows `openharmony`; `bash-local` / `bash-sandbox` `shellPath`; `userInfo()` guard |
| Procfs | `530cb707d6` | `hasLinuxProcfs()` covers `openharmony` |
| Device recipe | `scripts/openharmony/` | NDK natives, self-signed node, packed tree, deploy, smoke, runner — see its [README](scripts/openharmony/README.md) |
| Agent Notes | `.agents/notes/proposed/architecture/2026-10-24-*` | no-clobber publish, openharmony host platform |

Hazards and the per-release review inventory: [`scripts/openharmony/KNOWN-ISSUES.md`](scripts/openharmony/KNOWN-ISSUES.md). Device metrics M1–M6, E1–E3: [`scripts/openharmony/METRICS.md`](scripts/openharmony/METRICS.md).

## 4. Release adaptation

A Ticket about a new upstream `dsh-v*` tag: **load skill `hmos-release-adaptation`** ([SKILL.md](.agents/skills/hmos-release-adaptation/SKILL.md)) and follow it, from "issue for tag X" to "PR ready with evidence". The flow follows the latest upstream release — the newest `dsh-v*` tag by release date, including rc and final tags — not only the alpha line; a newest release that sits behind `master`'s line is reported, not back-merged.

## 5. Resources (this machine is shared, 9 GB RAM)

You do not see the host's own build rules, so they are restated here.

- **One heavy job per machine.** Heavy = `pnpm install`, `typecheck`, `lint`, tests, `build:*`, `pack-tree.sh`, natives builds, anything cargo. Before one: `pgrep -x cargo || pgrep -x rustc || pgrep -x box64` **and** `pgrep -xa node | grep -E 'vitest|tsc|tsdown|vite|tsx'` must print nothing; otherwise wait (`sleep 60` as a background job) and check again. The dsh Web server is node but not a build: ignore it. Your own gates and the device runner must not overlap either.
- **Memory.** From 0.2.2-alpha.2 `typecheck` and `build:artifacts` run 8 GiB compiler heaps: run them alone. `build:artifacts --serial` exists for that. An OOM kill (`Killed`, exit 137, "heap out of memory") is an environment failure, not a code defect: re-run once with nothing else running. Full `pnpm run lint` is OOM-killed here: lint changed paths with `pnpm exec tsx scripts/run-oxlint.ts <paths>`.
- **Time.** A foreground command over 5 s becomes a background job; a background job is killed 30 minutes after your turn ends. Split long work into steps that each finish well inside that (the device runner does this for you).
- **Disk.** The host disk behind `/mnt/linux_share/storage/Users/currentUser` is the one that matters (`df /` lies; a full host disk zeroes files). Check `~/.bin/disk-guard.sh --check` (exit 0) before installs and builds. Never put worktrees or build trees in `/tmp` (a 4.9 GB tmpfs). Remove build output you created when the Ticket ends.
- **Never `git stash`**; never rewrite shared history.

## 6. Gates

Run what covers your change, one at a time per §5:

| Gate | Command |
|---|---|
| Install | `pnpm install --frozen-lockfile` |
| Typecheck | `pnpm run typecheck` |
| Lint | `pnpm exec tsx scripts/run-oxlint.ts <changed paths>` |
| Tests | `pnpm exec vitest run <owning tests> --coverage --coverage.include='packages/<group>/<pkg>/src/**/*.ts'`; `node --test` in `native/system` |
| Docs | `pnpm run doc-sync`; this file's own gate `python3 scripts/docs-gate.py` |

A red gate that is also red on the pristine upstream tag is `upstream`: record it, do not fix it. Never lower thresholds, `--passWithNoTests`, or narrow coverage to hide a file.

## 7. Device

The HarmonyOS PC is the maintainer's real machine. You reach it **only** through `scripts/openharmony/sa-device-verify` (`--dry-run next` to read the plan, then `next` once per background job). It deploys to the agent root `/data/storage/el2/base/dsh-sa` (owner `superagent-dsh`) with a key-free env file; it never touches the maintainer's root `/data/storage/el2/base/dsh`, his `.env.private`, `~/.zshrc` or oh config. Never run `ssh`, `scp`, `hdc` or `oh` yourself, never `deploy.sh` / `push-env.sh` / `smoke.sh` by hand, never open apps or the browser on the PC. Exit codes and what to do: the skill, §8.

The PC's dsh install itself is the harmonybrew package `downsea/hmos/dsh`: [`pack-bottle.sh`](scripts/openharmony/pack-bottle.sh) builds the bottle and formula, and `brew install` / `brew upgrade` replaces `/data/storage/el2/base/dsh` in place and verifies the new tree with `dsh --version`.

## 8. Evidence on the PR

Every PR body states what changed, why, and the evidence: commands with exit codes and wall clock, each red classified (`upstream` / `adaptation` / `environment`), and for release PRs the nine items of the skill (conflicts, review table, `delta-check.sh` output, gates, the `sa-device-verify` evidence block, skipped tags, cost, open questions). Paste outputs verbatim; never paraphrase a number.

## 9. Hard rules

- No secrets in commits, logs, PR text or comments. Do not read `~/.env.private`, `~/.config/gh*`, `~/.ssh`, `~/.hermes`, the Gitea admin CLI, or the device's credential files.
- No `kms`, no vault, nothing under `~/code/*`, no GitHub, no other hosts. Write only in your Ticket directory, the runner's caches (`~/.cache/dsh-sa-hmos`) and the agent root it manages (tool caches such as the pnpm store aside).
- Never push `master`, never merge, never force-push, never create or move tags, never change Gitea settings, users or protections.
- Never edit `AGENTS.md` or other upstream files outside the HMOS delta, except as an adapted hunk listed in the PR body.
- Never write `~/.config/dsh-sa/` (the device env file and the recipe approvals are the maintainer's).

## 10. When to stop and ask

Ask one concrete question on the issue (`human_action`) and wait when: the tag cannot be classified or moved; keeping HMOS behaviour needs a design choice or a change outside the delta; you would drop an HMOS behaviour because upstream covers it; a native pin drifts to a new major or minor; an adaptation red survives two fix attempts; your change touches the device recipe; `sa-device-verify` exits 2 (sshd down, recipe approval, owner, env file, disk, repeated failure or yield); anything would touch secrets, the maintainer's install (other than the dsh `brew install` / `brew upgrade` of §7), GitHub, `~/code/*` or Gitea settings.

## 11. Commits

Upstream's conventional commits (`feat(<scope>): …`, `fix(…)`, `docs(…)`, `chore(…)`). The release merge commit is `merge(hmos): <tag> into master` and lists each conflicted path with its rule. No `Co-Authored-By` lines.
