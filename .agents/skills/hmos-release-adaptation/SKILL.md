---
name: hmos-release-adaptation
description: Use for a Ticket or issue about a new upstream dsh-v* release tag in this HarmonyOS copy of deepseek-harness. Takes the work from "issue for tag X" to "PR ready for review with evidence" by merging the tag into master on an agent branch, keeping the HMOS delta, running the in-repo gates, the W2 delta self-check and device verification with sa-device-verify, and stopping for a human in the listed cases.
---

# HMOS release adaptation

One upstream release tag in, one reviewable PR out. `master` here = the last adapted upstream tag + the HMOS delta, advanced only by merge PRs that the maintainer merges. You never merge, never push `master`, never force-push, never create tags. Read [`CLAUDE.md`](../../../CLAUDE.md) first (resources, hard rules); the device metrics are in [`scripts/openharmony/METRICS.md`](../../../scripts/openharmony/METRICS.md) and the hazards in [`scripts/openharmony/KNOWN-ISSUES.md`](../../../scripts/openharmony/KNOWN-ISSUES.md).

## 1. Confirm and classify

1. Reply on the issue: the tag name and the sha you will merge.
2. Fetch it from the `upstream` remote (the Gitea pull mirror of upstream; the Ticket's prepare command adds it — never GitHub): `git fetch upstream "refs/tags/<tag>:refs/tags/<tag>"`, then `git rev-parse "<tag>^{commit}"`. If the sha differs from the one the issue names, stop and ask (moved tag).
3. Classify. `master` follows the **alpha line** only (decision D2). `git fetch upstream master`, then `B=$(git merge-base origin/master upstream/master)` is the last upstream commit `master` absorbed. Adapt the tag when `git merge-base --is-ancestor "$B" <tag>` holds and `git merge-base --is-ancestor <tag> origin/master` does not (not yet merged); this is the `dsh-v0.2.2-alpha.N` line. An rc tag (`…-rc.N`) sits on a release branch that does not contain `B`: it is **not** adapted; comment "rc line not followed (D2)" with that ancestry fact and end the Ticket. If the name and the ancestry disagree, ask. Several new alpha tags at once: merge the newest and list the others as covered.

## 2. Budget the machine

One heavy job per machine. Before any install, build, typecheck, test or pack: `pgrep -x cargo || pgrep -x rustc || pgrep -x box64` and `pgrep -xa node | grep -E 'vitest|tsc|tsdown|vite|tsx'` must both print nothing; if not, wait (a background job `sleep 120`) and check again. Check the host disk with `~/.bin/disk-guard.sh --check` (exit 0 needed; the number that matters is `/mnt/linux_share/storage/Users/currentUser`, not `df /`). Every long command runs as a background job that finishes well inside 30 minutes.

## 3. Review the upstream range before merging

`U=$(git merge-base origin/master <tag>)`. Run the inventory of `KNOWN-ISSUES.md` §1 on `U..<tag>`: `git log --no-merges --oneline U..<tag> -- <inventory paths>` and the grep set. Write one verdict per hit: none / check in gates / check on device / ask. This table becomes PR body item ③.

## 4. Merge

Work on your Ticket branch `agent/<ticket-short-name>` (the Super-agent binds the PR to the Ticket by the last branch segment; do not invent another prefix), created from `origin/master`.

```sh
git merge --no-ff <tag> -m "merge(hmos): <tag> into master"
```

Conflict policy, in order:

1. `version` fields: take the tag's.
2. Generated files (`*.i18n.yaml` hashes, catalogs, `pnpm-lock.yaml`): take either side, then regenerate with the owning tool (`pnpm run verify-translation-pairing --write <README.md path>`, `pnpm install` for the lockfile). Never hand-merge a hash: the right value is often neither side's.
3. Paths in the HMOS delta (`git diff --name-only U origin/master`): **keep the HMOS behaviour**, re-expressed on upstream's new code (upstream's structure, HMOS semantics).
4. Paths outside the delta: **upstream's side** (the tag).
5. Repository-owned files (`CLAUDE.md`, `scripts/openharmony/**`, `.agents/skills/hmos-*`, `.docs-check.toml`, `scripts/docs-gate.py`): ours.
6. Upstream now does what an HMOS change did: prefer upstream, list the dropped paths as R, and ask before dropping a behaviour (section 9).

The merge commit records each conflicted path and the rule used. Each non-mechanical adaptation is its own conventional commit after the merge (`fix(<pkg>): … for <tag>`), then `chore(docs): regenerate i18n records` for hash files.

## 5. W2 self-check

```sh
scripts/openharmony/delta-check.sh [--added A.lst] [--dropped R.lst] [--adapted X.lst] <tag>
```

It must print `W2 self-check: PASS`. Every path in A (added to the delta), R (dropped because upstream adopted it) and X (adapted hunks) needs a reason in the PR body. Paste the output verbatim (item ④). The orchestrator scores W2 with its own copy; do not edit `delta-check.sh` in an adaptation PR.

## 6. In-repo gates (W3)

There is no CI here; your local gates are the only evidence. Run them one at a time, each after the section 2 check, as background jobs:

| Gate | Command |
|---|---|
| Install | `pnpm install --frozen-lockfile` |
| Typecheck | `pnpm run typecheck` — alone; from 0.2.2-alpha.2 it uses 8 GiB heaps on a 9 GB machine. An OOM kill (`Killed`, exit 137, "heap out of memory") is `environment`: re-run once with nothing else running |
| Lint | changed paths only: `pnpm exec tsx scripts/run-oxlint.ts <changed paths>` (full `pnpm run lint` is OOM-killed here) |
| Tests | `pnpm exec vitest run <owning tests> --coverage --coverage.include='packages/<group>/<pkg>/src/**/*.ts'` for each HMOS package (atomic-write, fs-local, attachment-local, session-persistence-jsonl, subprocess-local, bash-local, bash-sandbox) and any package section 3 named; `node --test` in `native/system` |
| Docs | `pnpm run doc-sync` |

A red gate: re-run the same gate on the pristine tag (`git worktree add --detach <dir> <tag>`). Red there too ⇒ `upstream` (record, do not fix, do not ask). Red only on your branch ⇒ `adaptation` (fix; two failed fix attempts ⇒ ask). Machine trouble ⇒ `environment`.

## 7. Push and open the PR as a draft

Push `agent/<ticket-short-name>` to `origin` and open a draft PR into `master` with the instance's `gh` (the Gitea shim). Title `merge(hmos): <tag> into master`. Body (items ⑥–⑨ follow later):

① tag, tag sha, `git rev-list --count origin/master..<tag>`; ② conflicts: path · hunks · owning HMOS commit · rule used; ③ the section 3 review table with verdicts; ④ `delta-check.sh` output verbatim + A / R / adapted lists with reasons; ⑤ W3: command, exit code, wall clock, each red classified `upstream` / `adaptation` / `environment`; ⑥ device evidence; ⑦ skipped tags (rc, covered); ⑧ cost: wall clock, peak disk; ⑨ open questions for the maintainer.

## 8. Device verification (W4)

Only through the runner; never raw `ssh`, `scp`, `hdc` or `oh`, never `deploy.sh` or `push-env.sh` by hand, never the maintainer's root `/data/storage/el2/base/dsh`.

```sh
scripts/openharmony/sa-device-verify --dry-run next   # once: read the plan
scripts/openharmony/sa-device-verify next             # as a background job; repeat after each job ends
```

Each `next` runs one step for your committed `HEAD` (uncommitted changes are not verified; a new commit starts over). React to the exit status:

| Exit | Meaning | Do |
|---|---|---|
| 0 | a step finished | run `next` again |
| 10 | all done; the evidence block is printed | paste it into the PR as item ⑥ (`sa-device-verify evidence` prints it again) |
| 75 | busy: a heavy job on the VM, the maintainer's dsh/hvigor on the PC, or another checkout holds the device slot | wait (`sleep 120; sa-device-verify next` as one job) and continue |
| 1 | a step failed | read the log it names and `KNOWN-ISSUES.md`; fix an adaptation cause, or call `next` again for a transient one |
| 2 | needs a human | stop and ask with the runner's message (section 9) |

Pass: every M line in the evidence is ok and `M0 … commit=` equals your head. M5 runs by itself when the device recipe changed since the last verified run.

## 9. Stop and ask (one concrete question each)

- The tag cannot be classified, or its sha moved.
- A conflict or review hit in HMOS-owned code needs a design choice, or a change outside the delta (A non-empty in product `src/`), or R is non-empty.
- A native pin in `build-natives.sh` drifts to a new major or minor, or the ELF sweep removes a native a used profile needs.
- An `adaptation` red that two fix attempts did not clear; any red touching the device recipe.
- **Your PR changes the device recipe** (`deploy.sh`, `smoke.sh`, `push-env.sh`, `lib.sh`, `dsh-web.zsh`, `sa-device-verify`): the runner exits 2 before deploying; a human reviews and approves the commit. Do not write the approval file yourself.
- **sshd on the PC is down** (exit 2, `Connection refused`): report `blocked` at once; only the maintainer can restore it.
- **Repeated yield**: the runner exits 2 after 8 yields in a row (the maintainer keeps using the PC).
- Owner mismatch, env file problems, low disk, or a device failure not in `KNOWN-ISSUES.md`.
- Anything that would touch secrets, the device env file contents, the maintainer's device install, GitHub, `~/code/*`, Gitea settings, or the host disk below the margin.

## 10. Ready

Add items ⑦–⑨, mark the PR ready, report `ready`. Never merge it; the maintainer merges with a merge commit.
