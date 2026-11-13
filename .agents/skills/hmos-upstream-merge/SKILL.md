---
name: hmos-upstream-merge
description: Use when merging a new upstream deepseek-ai dsh-v* release tag into this fork's master while keeping the HarmonyOS (HMOS) delta. Takes the work from "a newer upstream release exists" to "master with the tag merged, verified and pushed to origin". The mechanical part is the script scripts/openharmony/upstream-merge.sh (tag check, machine budget, range review, merge with the fixed conflict rules, delta-check.sh, the gates, the device recipe on a second root, the push); this skill is what it does, and what the agent does when it stops with exit 2 (conflicts, review, delta-check, gates, device). The HMOS release that follows is the maintainer's hmos-bundle run in homebrew-hmos, not part of this skill.
---

# HMOS upstream merge

One upstream release tag in, `master` = that tag + the HMOS delta out, pushed to `origin` (the GitHub fork). This is a development task of this repository; it ends at the push. Releasing for the PC is a separate act: the maintainer runs `scripts/hmos-bundle run dsh` in `~/code/homebrew-hmos`, which builds from the pushed `master`, signs, smokes on the device, bottles and publishes. Read [`CLAUDE.md`](../../../CLAUDE.md) first (the HMOS delta table, build knobs, hard rules); device metrics are in [`scripts/openharmony/METRICS.md`](../../../scripts/openharmony/METRICS.md), hazards in [`scripts/openharmony/KNOWN-ISSUES.md`](../../../scripts/openharmony/KNOWN-ISSUES.md), the recipe in [`scripts/openharmony/README.md`](../../../scripts/openharmony/README.md).

## 0. Run the script

```sh
scripts/openharmony/upstream-merge.sh <tag>                 # from any checkout of the fork; adds the upstream remote if missing
scripts/openharmony/upstream-merge.sh --no-push <tag>       # all but the push
scripts/openharmony/upstream-merge.sh --base <ref> <tag>    # rehearsal onto an older master (implies --no-push)
```

The maintainer's usual entry is `scripts/hmos-bundle run dsh --merge` in homebrew-hmos, which calls the script from its work clone and continues into the release on exit 0. The script does sections 1–9 below. Its last stdout line is `dsh-merge: state=<STATE> tag=<tag> exit=<N> worktree=<path|-> report=<path|-> head=<sha12|->`; the report is `~/.cache/dsh-merge-<tag>.report.md`, logs `~/.cache/dsh-merge-<tag>.logs/` (`DSH_MERGE_ROOT` moves all of it). Exit `0` done (`pushed`, `already-merged`, `merged-unpushed` with `--no-push`) · `2` needs an agent or a human · `1` a tool failed · `75` busy (machine budget after a bounded wait, `DSH_MERGE_WAIT_MAX`; re-run later).

**On exit 2** the worktree `~/.cache/dsh-merge-<tag>` (branch `local/merge-<tag>`) is kept. Continue from the report's **Next** paragraph in that worktree: resolve (section 4), adapt (`fix(<pkg>): … for <tag>` commits), record the reasons in the merge commit body, commit, **do not push**. Then the maintainer re-runs (`hmos-bundle run dsh --merge`, or the script with the same arguments, from the same clone): it resumes in the kept worktree, commits a resolved merge still in progress, and continues from the delta check (section 5); the gates are not re-run while the head is the one they passed on. Only a run that ends in `pushed` or `merged-unpushed` removes the worktree and its branch; the report and logs stay.

| State (exit 2) | What the agent does |
|---|---|
| `conflicts` | the paths marked "needs agent" (rule 3), and a verdict per "ask" review row; replace each `TODO(agent)` of the prepared message (`git rev-parse --git-path MERGE_MSG`), `git add`, `LEFTHOOK=0 git commit --no-edit` |
| `review` | the merge is committed; read each "ask" row (section 3), adapt where the HMOS behaviour needs carrying, record one verdict per hit in the merge body (`LEFTHOOK=0 git commit --amend`) |
| `delta-check` | MISSING / EXTRA / MISMATCH (section 5): fix by an adaptation commit, or name an intended X path with its reason in the record; A and R are a maintainer decision passed through `<logs>/A.lst` / `R.lst` |
| `gates` | an `adaptation` red (section 6): fix it; two failed attempts ⇒ ask. `environment` twice ⇒ a quieter machine |
| `device` | compare with `KNOWN-ISSUES.md` §2: known cause ⇒ its fix; anything else, or sshd down ⇒ ask |
| `diverged` | the worktree does not carry the merge, belongs to another clone, or `origin/master` moved: section 8 |

Run the steps by hand only to debug the script; then follow the sections literally.

## 1. Pick and verify the tag

1. `master` follows the **latest upstream release**: the newest `dsh-v*` release by date, whatever its kind (alpha, rc or final). List them with `gh release list -R deepseek-ai/deepseek-harness --limit 10`. `hmos-bundle check` in homebrew-hmos names it.
2. Fetch it from `upstream`: `git fetch upstream master "refs/tags/${T}:refs/tags/${T}"`, then `git fetch origin`. In zsh write `${T}`: `$T:r…` is a history modifier.
3. Verify it: `git rev-parse "${T}^{commit}"` must equal the sha `git ls-remote upstream "refs/tags/${T}" "refs/tags/${T}^{}"` reports — the peeled `^{}` line for an annotated tag, **the plain line for a lightweight tag** (upstream's release tags are lightweight; they have no `^{}` line) — and the GitHub ref API (`gh api repos/deepseek-ai/deepseek-harness/git/ref/tags/${T}`); `gh release view` must show a published release. A mismatch is a moved or rewritten tag: stop and ask.
4. Classify:
   - `git merge-base --is-ancestor <tag> origin/master` holds ⇒ already merged, nothing to do.
   - Several new tags at once ⇒ merge the newest; the older ones are covered (the script names them).
   - The tag does not contain `B=$(git merge-base origin/master upstream/master)`, the last upstream commit `master` absorbed ⇒ it sits behind `master`'s line: do not back-merge it; ask which line `master` follows.

## 2. Budget the machine

The machine is shared (oh-vm, ~8–9 GB). One heavy job at a time: before any install, typecheck, test, build or pack, `pgrep -x cargo || pgrep -x rustc || pgrep -x box64` and `pgrep -xa node | rg 'vitest|tsc|tsdown|vite|tsx'` must both print nothing and the build slot must be free (unless the caller holds it: `CARGO_SLOT_HELD`); otherwise wait and re-check every ~60 s (the script bounds the wait and exits 75). Check the host share's water level (`~/.bin/disk-guard.sh --check`; the number that matters is `/mnt/linux_share/storage/Users/currentUser`, not `df /`). Long commands run in the background with a log. Never `git stash`; never work in a checkout another session uses: use your own `git worktree` under `~/.cache` (not `/tmp`, a small tmpfs) and remove it at the end.

## 3. Review the upstream range before merging

`U=$(git merge-base origin/master <tag>)`. The review is `KNOWN-ISSUES.md` §1 on `U..<tag>`, **restricted to what needs a decision**: the grep set on the lines the range adds under `src/` of the delta packages (the packages with a `src/` path in `git diff --name-only U origin/master`; spec files, tests and READMEs are left out — they were most of the ~140 hits of the rc.2 range), and the native pins of `build-natives.sh` against the tag's `pnpm-lock.yaml`. Each such hit is an "ask": read it and give a verdict (none / check in gates / check on device / adapt). The rest of the inventory (upstream commits in the delta packages' `src/`, release steps, replay fixtures, `tool-fs-search`, `native/system`, allow-lists, new packages) gets its verdict mechanically: the gates and the device run settle it. The table is in the report.

## 4. Merge on a branch

```sh
git worktree add -b local/merge-<tag> ~/.cache/dsh-merge-<tag> origin/master
cd ~/.cache/dsh-merge-<tag>
LEFTHOOK=0 git -c merge.conflictStyle=diff3 merge --no-ff --no-commit <tag>
```

Conflict policy, in order (the script applies 1, 2, 4 and 5 and leaves 3 and 6 to the agent):

1. `version` fields: take the tag's (a `package.json` whose other changes then merge cleanly is resolved; otherwise rule 3).
2. Generated files (`*.i18n.yaml` hashes, `pnpm-lock.yaml`): take the tag's side, then regenerate with the owning tool (`pnpm run verify-translation-pairing --write <README.md path>`, `pnpm install --lockfile-only --ignore-scripts` for the lockfile). Never hand-merge a hash: the right value is often neither side's.
3. Paths in the HMOS delta (`git diff --name-only U origin/master`, summarised in `CLAUDE.md` "HMOS delta"): **keep the HMOS behaviour**, re-expressed on upstream's new code (upstream's structure, HMOS semantics).
4. Paths outside the delta: **upstream's side** (the tag).
5. Repository-owned files (`CLAUDE.md`, `scripts/openharmony/**`, `.agents/skills/hmos-*`, `.docs-check.toml`, `scripts/docs-gate.py`): ours.
6. Upstream now does what an HMOS change did: prefer upstream, list the dropped paths as R, and ask before dropping a behaviour (section 10).

Commit the merge with `LEFTHOOK=0` (the lefthook pre-commit would lint and fix every staged upstream file of the range); every later commit runs the hooks normally. The merge commit body is the merge record: tag and sha, range count, each conflicted path with the rule used (for rule 3, how the HMOS behaviour was kept), the section 3 verdicts, and A / R / X with reasons. Each non-mechanical adaptation is its own conventional commit after the merge (`fix(<pkg>): … for <tag>`), then `chore(docs): regenerate i18n records` for hash files.

## 5. Delta check

```sh
scripts/openharmony/delta-check.sh [--added A.lst] [--dropped R.lst] [--adapted X.lst] <tag> [HEAD [<base>]]
```

It must print `delta-check: PASS`. Every path in A (added to the delta), R (dropped because upstream adopted it) and X (adapted hunks) needs a reason in the merge record. The script passes as X the delta paths an agent resolved or changed after the merge commit **and that the record names**; A and R only from `<logs>/A.lst` / `R.lst`, written after the maintainer's decision.

`CLAUDE.md` is in the delta's path set (repository-owned). An edit to it on the merge branch changes its delta lines and fails the check as a MISMATCH; edits committed on `master` (before or after the merge) are in both diffs and pass. So the merge never edits `CLAUDE.md`: its "Current project state" names no merged tag (`git describe --tags --abbrev=0 --match 'dsh-v*' origin/master` does), and the main session updates the other bullets in a separate `chore(local)` commit on `master`.

## 6. In-repo gates

One at a time, each after the section 2 check. A fresh worktree installs with `pnpm install --frozen-lockfile --ignore-scripts` (the postinstall would rewrite the hooks the shared checkout uses), then builds the host flock addon `--ignore-scripts` skipped: `pnpm run build:native-system` (`tsx native/system/scripts/build.ts --host-addon-only`; without it session-persistence-jsonl fails ~370 tests).

| Gate | Command |
|---|---|
| Typecheck | `DSH_GATE_CONCURRENCY=1 pnpm run typecheck` — alone; it runs 8 GiB compiler heaps |
| Lint | delta paths only: `pnpm exec tsx scripts/run-oxlint.ts --format=unix <paths>` (`*.{ts,tsx,mts,cts,mjs}` of `git diff --name-only <tag> HEAD`; full `pnpm run lint` is OOM-killed here) |
| Tests | `pnpm exec vitest run packages/<group>/<pkg> --coverage --coverage.include='packages/<group>/<pkg>/src/**/*.ts'` for each package with `src/` in the delta, plus `tool-fs-search` when the range touched it; in `native/system`: `node ./scripts/build-test-oracle.mjs` (the C flock oracle; on oh-vm it builds the glibc one and then fails for want of `musl-gcc`, which is fine), then `node --test ./test/flock.test.js ./test/package-matrix.test.js ./test/release-packing.test.js` (bare `node --test` picks up fixtures and needs a musl `landlock-run`) |
| Docs | `NODE_OPTIONS=--max-old-space-size=4096 DSH_GATE_CONCURRENCY=1 pnpm run doc-sync` (the docs build and doc graphs abort with the default heap here); `python3 scripts/docs-gate.py` |

An OOM kill (`Killed`, exit 137/134, "heap out of memory") is `environment`: the failed run-gates sub-gates are re-run alone, or the gate once; still out of memory ⇒ stop. Any other red: run the same gate on the pristine tag (`git worktree add --detach <dir> <tag>`, same install). Green there ⇒ `adaptation` (fix; two failed fix attempts ⇒ ask). Red there too ⇒ compare the failures (failing test names, coverage files and metrics, TS errors, lint rules): all of the merge's failures also on the tag ⇒ `upstream` (record, do not fix — e.g. the subprocess-local Windows-path test and the bash-local `index.ts` coverage on rc.2); a failure only on the merge ⇒ `adaptation`, even when the gate was red on the tag for other reasons. Gate results and their classification go to the report, not to the merge body.

## 7. Device recipe

Build the tree from the merged head and verify it on the PC per [`scripts/openharmony/README.md`](../../../scripts/openharmony/README.md) and the metrics in `METRICS.md`. Deploy to a **second root of your own**, never the default root `/data/storage/el2/base/dsh`: that is the maintainer's install of the released harmonybrew package (the script refuses it).

```sh
R=scripts/openharmony O=~/.cache/dsh-merge-<tag>.out
export DSH_OH_ROOT=/data/storage/el2/base/dsh-dev DSH_OH_OWNER=nan
$R/build-natives.sh . $O/natives
$R/make-node.sh /mnt/linux_share/storage/Users/currentUser/hmos-clt/command-line-tools/node/bin/node $O/node
OH_BUILD_ARGS=--serial $R/pack-tree.sh . $O/natives $O       # tree/oh/dsh-commit.txt = HEAD
$R/deploy.sh $O/tree $O/node hmos
$R/smoke.sh --m3 --m6 hmos
```

The merge is committed before this section (the tree records `HEAD`; `M0 … commit=` must equal the merged head). Pass: `M1 SMOKE-SUMMARY ok=5 fail=0`, `M2 exit=0 no-usable-native-binding=no`, both M3 `verdict=ok`, and every M6 line of `METRICS.md` ok (`rg`, `fs-glob-sampling`, `pty-tools-sandbox-backend`, `TERM-SUMMARY ok=8 fail=0`, `terminal`, `sharp ok`, `web`); M5 (deploy from an empty root: the script empties the second root after checking its `.owner`) when the recipe changed since the last merge of an upstream tag. The second root needs no env file: M3 and M6 are keyless. A change on the merge branch to `deploy.sh`, `smoke.sh`, `push-env.sh`, `lib.sh` or `dsh-web.zsh` is reviewed before it runs on the device (the script stops; after the review write the head sha to `<logs>/device-reviewed`). `ssh hmos` refused means sshd on the PC is down: only the maintainer can restore it (`KNOWN-ISSUES.md` §2). The device evidence goes to the report.

## 8. Push `master`

```sh
git fetch origin
git merge-base --is-ancestor origin/master HEAD    # must hold; otherwise merge origin/master in and re-run the affected gates
DSH_GATE_CONCURRENCY=1 git push origin HEAD:master  # pre-push runs typecheck; fast-forward only; hooks on
```

The first push of a merge uploads the range's upstream objects to the fork (≈ 14 min for rc.2's 1568 commits); that is expected. Never force-push, never create tags (`dsh-v*` tags are upstream's, release tags homebrew-hmos's). Then remove the worktree and the branch, and purge the recipe's output directory unless a rebuild is planned (the script does all three).

## 9. Record and hand off

The merge record is the merge commit body (section 4): conflicts with rules, the section 3 verdicts, A / R / X with reasons, skipped tags, open questions. The run report (`~/.cache/dsh-merge-<tag>.report.md`: gates with exit codes and classifications, the device lines with `M0 … commit=`) is the evidence: link it from the local issue in `.issues-local/`. Update the local issue and the vault ledger per `CLAUDE.md`; a `CLAUDE.md` "Current project state" change is a separate `chore(local)` commit on `master` (section 5). Then tell the maintainer that `master` carries `<tag>`; `scripts/hmos-bundle check` in homebrew-hmos reports what is releasable, and `scripts/hmos-bundle run dsh` is the maintainer's release.

## 10. Stop and ask (one concrete question each)

- The tag cannot be classified, or its sha moved.
- A conflict or review hit in HMOS-owned code needs a design choice, or a change outside the delta (A non-empty in product `src/`), or R is non-empty.
- A native pin in `build-natives.sh` drifts to a new major or minor, or the ELF sweep removes a native a used profile needs.
- An `adaptation` red that two fix attempts did not clear; any red touching the device recipe.
- A device failure not in `KNOWN-ISSUES.md`, sshd on the PC down, an owner mismatch on the second root, or the host disk below the margin.
- `origin/master` moved in a way that is not a fast-forward of your base.
- Anything that would touch secrets, the maintainer's default root, or another repository.
