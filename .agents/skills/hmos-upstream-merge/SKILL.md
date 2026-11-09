---
name: hmos-upstream-merge
description: Use when merging a new upstream deepseek-ai dsh-v* release tag into this fork's master while keeping the HarmonyOS (HMOS) delta. Takes the work from "a newer upstream release exists" to "master with the tag merged, verified and pushed to origin": pick and verify the tag, review the upstream range against the delta hazards, merge on a branch, resolve conflicts by the delta table, run delta-check.sh, the in-repo gates and the device recipe on a second root, then push master fast-forward. The HMOS release that follows is the maintainer's hmos-bundle run in homebrew-hmos, not part of this skill.
---

# HMOS upstream merge

One upstream release tag in, `master` = that tag + the HMOS delta out, pushed to `origin` (the GitHub fork). This is a development task of this repository; it ends at the push. Releasing for the PC is a separate act: the maintainer runs `scripts/hmos-bundle run dsh` in `~/code/homebrew-hmos`, which builds from the pushed `master`, signs, smokes on the device, bottles and publishes. Read [`CLAUDE.md`](../../../CLAUDE.md) first (the HMOS delta table, build knobs, hard rules); device metrics are in [`scripts/openharmony/METRICS.md`](../../../scripts/openharmony/METRICS.md), hazards in [`scripts/openharmony/KNOWN-ISSUES.md`](../../../scripts/openharmony/KNOWN-ISSUES.md), the recipe in [`scripts/openharmony/README.md`](../../../scripts/openharmony/README.md).

## 1. Pick and verify the tag

1. `master` follows the **latest upstream release**: the newest `dsh-v*` release by date, whatever its kind (alpha, rc or final). List them with `gh release list -R deepseek-ai/deepseek-harness --limit 10`.
2. Fetch it from `upstream` (`deepseek-ai/deepseek-harness`): `git fetch upstream master "refs/tags/<tag>:refs/tags/<tag>"`, then `git fetch origin`.
3. Verify it: `git rev-parse "<tag>^{commit}"` must equal the peeled sha that `git ls-remote upstream "refs/tags/<tag>^{}"` reports and the commit `gh release view <tag> -R deepseek-ai/deepseek-harness` names. A mismatch is a moved or rewritten tag: stop and ask.
4. Classify:
   - `git merge-base --is-ancestor <tag> origin/master` holds ⇒ already merged, nothing to do.
   - Several new tags at once ⇒ merge the newest; the older ones are covered (name them in the merge commit body).
   - The tag does not contain `B=$(git merge-base origin/master upstream/master)`, the last upstream commit `master` absorbed ⇒ it sits behind `master`'s line: do not back-merge it; ask which line `master` follows.

## 2. Budget the machine

The machine is shared (oh-vm, ~8–9 GB). One heavy job at a time: before any install, typecheck, test, build or pack, `pgrep -x cargo || pgrep -x rustc || pgrep -x box64` and `pgrep -xa node | rg 'vitest|tsc|tsdown|vite|tsx'` must both print nothing; otherwise wait and re-check every ~60 s. Check the host share's water level (`~/.bin/disk-guard.sh --check`; the number that matters is `/mnt/linux_share/storage/Users/currentUser`, not `df /`). Long commands run in the background with a log. Never `git stash`; never work in a checkout another session uses: use your own `git worktree` under `~/.cache` (not `/tmp`, a small tmpfs) and remove it at the end.

## 3. Review the upstream range before merging

`U=$(git merge-base origin/master <tag>)`. Run the inventory of `KNOWN-ISSUES.md` §1 on `U..<tag>`: `git log --no-merges --oneline U..<tag> -- <inventory paths>` and its grep set. Write one verdict per hit: none / check in gates / check on device / ask. Keep the table for the merge record (section 9).

## 4. Merge on a branch

```sh
git worktree add -b local/merge-<tag> ~/.cache/dsh-merge-<tag> origin/master
cd ~/.cache/dsh-merge-<tag>
git merge --no-ff <tag> -m "merge(hmos): <tag> into master"
```

Conflict policy, in order:

1. `version` fields: take the tag's.
2. Generated files (`*.i18n.yaml` hashes, catalogs, `pnpm-lock.yaml`): take either side, then regenerate with the owning tool (`pnpm run verify-translation-pairing --write <README.md path>`, `pnpm install` for the lockfile). Never hand-merge a hash: the right value is often neither side's.
3. Paths in the HMOS delta (`git diff --name-only U origin/master`, summarised in `CLAUDE.md` "HMOS delta"): **keep the HMOS behaviour**, re-expressed on upstream's new code (upstream's structure, HMOS semantics).
4. Paths outside the delta: **upstream's side** (the tag).
5. Repository-owned files (`CLAUDE.md`, `scripts/openharmony/**`, `.agents/skills/hmos-*`, `.docs-check.toml`, `scripts/docs-gate.py`): ours.
6. Upstream now does what an HMOS change did: prefer upstream, list the dropped paths as R, and ask before dropping a behaviour (section 10).

The merge commit body records each conflicted path and the rule used. Each non-mechanical adaptation is its own conventional commit after the merge (`fix(<pkg>): … for <tag>`), then `chore(docs): regenerate i18n records` for hash files.

## 5. Delta check

```sh
scripts/openharmony/delta-check.sh [--added A.lst] [--dropped R.lst] [--adapted X.lst] <tag>
```

It must print `delta-check: PASS`. Every path in A (added to the delta), R (dropped because upstream adopted it) and X (adapted hunks) needs a reason in the merge record.

## 6. In-repo gates

Run them one at a time, each after the section 2 check, as background jobs. A fresh worktree installs with `pnpm install --frozen-lockfile --ignore-scripts` (the postinstall would rewrite the hooks the shared checkout uses).

| Gate | Command |
|---|---|
| Typecheck | `DSH_GATE_CONCURRENCY=1 pnpm run typecheck` — alone; it runs 8 GiB compiler heaps. An OOM kill (`Killed`, exit 137, "heap out of memory") is `environment`: re-run once with nothing else running |
| Lint | changed paths only: `pnpm exec tsx scripts/run-oxlint.ts <changed paths>` (full `pnpm run lint` is OOM-killed here) |
| Tests | `pnpm exec vitest run <owning tests> --coverage --coverage.include='packages/<group>/<pkg>/src/**/*.ts'` for each HMOS package (atomic-write, fs-local, attachment-local, session-persistence-jsonl, subprocess-local, bash-local, bash-sandbox) and any package section 3 named; `node --test` in `native/system` |
| Docs | `pnpm run doc-sync`; `python3 scripts/docs-gate.py` |

A red gate: re-run the same gate on the pristine tag (`git worktree add --detach <dir> <tag>`). Red there too ⇒ `upstream` (record, do not fix). Red only on your branch ⇒ `adaptation` (fix; two failed fix attempts ⇒ ask). Machine trouble ⇒ `environment`.

## 7. Device recipe

Build the tree from the merged head and verify it on the PC per [`scripts/openharmony/README.md`](../../../scripts/openharmony/README.md) and the metrics in `METRICS.md`. Deploy to a **second root of your own**, never the default root `/data/storage/el2/base/dsh`: that is the maintainer's install of the released harmonybrew package.

```sh
R=scripts/openharmony O=~/.cache/dsh-merge-<tag>-out
export DSH_OH_ROOT=/data/storage/el2/base/dsh-dev DSH_OH_OWNER=nan
$R/build-natives.sh . $O/natives
$R/make-node.sh /mnt/linux_share/storage/Users/currentUser/hmos-clt/command-line-tools/node/bin/node $O/node
OH_BUILD_ARGS=--serial $R/pack-tree.sh . $O/natives $O       # tree/oh/dsh-commit.txt = HEAD
$R/deploy.sh $O/tree $O/node hmos
$R/smoke.sh --m3 --m6 hmos
```

Commit first: the tree records `HEAD`, and `M0 … commit=` must equal the merged head. Pass: every M1, M2, M3 and M6 line ok; M5 (deploy from an empty root) as well when the device recipe changed since the last verified merge. The second root needs no env file: M3 and M6 are keyless. Review any change to `deploy.sh`, `smoke.sh`, `push-env.sh`, `lib.sh` or `dsh-web.zsh` before running it on the device. `ssh hmos` refused means sshd on the PC is down: only the maintainer can restore it (`KNOWN-ISSUES.md` §2).

## 8. Push `master`

```sh
git fetch origin
git merge-base --is-ancestor origin/master HEAD    # must hold; otherwise merge origin/master in and re-run the affected gates
DSH_GATE_CONCURRENCY=1 git push origin HEAD:master  # pre-push runs typecheck; fast-forward only
```

Never force-push, never create tags (`dsh-v*` tags are upstream's, release tags homebrew-hmos's). Then remove the worktree and the branch, and purge the recipe's output directory unless a rebuild is planned.

## 9. Record and hand off

The merge record (the merge commit body; what does not fit goes to the local issue in `.issues-local/`): tag and sha, `git rev-list --count <previous master>..<tag>`, conflicts with rules, the section 3 review table, A / R / X with reasons, gate results with exit codes and each red classified, the device evidence (`smoke.sh` output, `M0 … commit=`), skipped tags, open questions. Update the local issue and the vault ledger per `CLAUDE.md`. Then tell the maintainer that `master` carries `<tag>`; `scripts/hmos-bundle check` in homebrew-hmos reports what is releasable, and `scripts/hmos-bundle run dsh` is the maintainer's release.

## 10. Stop and ask (one concrete question each)

- The tag cannot be classified, or its sha moved.
- A conflict or review hit in HMOS-owned code needs a design choice, or a change outside the delta (A non-empty in product `src/`), or R is non-empty.
- A native pin in `build-natives.sh` drifts to a new major or minor, or the ELF sweep removes a native a used profile needs.
- An `adaptation` red that two fix attempts did not clear; any red touching the device recipe.
- A device failure not in `KNOWN-ISSUES.md`, sshd on the PC down, an owner mismatch on the second root, or the host disk below the margin.
- `origin/master` moved in a way that is not a fast-forward of your base.
- Anything that would touch secrets, the maintainer's default root, or another repository.
