# Known issues and the release review inventory

What epic 016 learned the hard way (2026-10-24…26, oh-vm + MOR-M1, HarmonyOS 7.0.0.111, API 26), and what every upstream release must be checked against. Metrics are in [METRICS.md](METRICS.md). Source: the operator's untracked `.issues-local/2026-10-24-dsh-hmos-native/` (`00-epic-sot.md` §3, §7, `04-recipe-w2.md` §4, `05-web-w3b.md`, `06-adaptation-report.md` §6) and dsh-superagent epic 006 research `02-adaptation-unit.md` §4.

A device failure that matches nothing here is new: stop and ask (skill `hmos-upstream-merge`), do not retry blindly.

## 1. Release review inventory

The HMOS delta touches few files, and upstream rarely edits them; the real risks of a release are next to the delta. For every merged range `<last-tag>..<tag>`, review these paths and patterns and write a verdict per hit (none / check in gates / check on device / ask).

| Area | Where | Why it matters |
|---|---|---|
| Hard-link publish (5 sites) | `packages/session/session-persistence-jsonl/src/index.ts` (new-session publish), `.../generation.ts`, `packages/attachment/attachment-local/src/store.ts` (2), `packages/fs/fs-local/src/fsio.ts` (write tool) | the device cannot `link()`: `EPERM` on home (hmdfs), **`EACCES` on el2 base (hmfs)**. the HMOS `atomic-write` commits publish without hard links; a new `link()` site breaks M3 |
| fsync to the root | `attachment-local/src/store.ts` `ensureDurableHome` | fsync upward crosses the sandbox boundary (EPERM/EACCES) |
| Hard-coded `bash` | `packages/shell/bash-local/src/index.ts`, `packages/shell/bash-sandbox/src/index.ts` | the device has no bash; `shellPath` is a Config since the HMOS platform-support commit, set to `/usr/bin/zsh` by `openharmony.patch.yml` |
| `os.userInfo()` | `packages/subprocess/subprocess-local/src/index.ts` | throws `ENOENT` without `SHELL` (no passwd entry); guarded since the HMOS platform-support commit |
| procfs gates | `hasLinuxProcfs()` in `subprocess-local` (HMOS delta) | any new `process.platform === 'linux'` procfs check skips openharmony |
| flock platform | `native/system` (`flock.ts` platform gate, `scripts/build.ts --target openharmony-arm64`, `packages/openharmony-arm64`) | first session write needs flock |
| Native pins | `build-natives.sh` (`node-addon-require-builtin@0.1.9`, `node-pty@1.2.0-beta.15`, `koffi@3.1.1`, `@vscode/ripgrep@1.18.0` / ripgrep 15.0.0, `@img/sharp-wasm32` from the lockfile) | the script fails on drift; a new major/minor pin is a human question |
| Brew payload launchers | `scripts/openharmony/brew/oh-env.sh.in`, `scripts/openharmony/brew/dsh.zsh.in` | they mirror the default-root `bin/oh-env.sh` and `bin/dsh` that `deploy.sh` writes; a change to one must land in the other, or the pushed install and the brew install drift |
| Release steps the recipe mirrors | `.github/workflows/release.yml` (pack steps), `scripts/release/verify-packed-install.ts` (platform acceptance, copied inline in `pack-tree.sh`) | a changed pack step silently diverges from the tree the recipe builds |
| Build memory | `build:artifacts`, `typecheck` (`scripts/build.ts`) | from upstream #7435 (0.2.2-alpha.2) host and client typechecks run with 8 GiB heaps; `--serial` exists |
| Replay fixtures | `snapshots/session/{bash-tool-turn,fs-write,fs-glob-sampling,pty-tools-sandbox-backend}`, `packages/test-support/llm-replay` | M3/M6 depend on them |
| Glob / search argv | `packages/fs/tool-fs-search` | upstream changed `rg --files` arguments in 0.2.2 (`--glob=!**` pruning); M6 glob replay is the check |
| Platform allow-lists | `assertBundlePlatform` / `NODE_PLATFORMS` (from 0.2.2-alpha.2) | omits `openharmony`; harmless today (only `cua-bundle` declares platforms, `["darwin"]`), latent for any future platform-declaring bundle |

Grep set for added lines in the range (under `packages/ native/ apps/`):

```sh
git diff <last-tag> <tag> -- packages native apps | grep -E '^\+' | grep -nE '\blink(Sync)?\(|process\.platform|userInfo\(|/proc/|statx|\bbash\b'
```

On the range from the previous merge base (`dsh-v0.2.1-rc.3` + 1533 commits) to `dsh-v0.2.2-alpha.2` (637 commits) this returned 31 `process.platform` lines; the relevant one was `assertBundlePlatform` above. Over the whole tree it is noisy (~140 hits on `dsh-v0.2.2-rc.1..rc.2`, almost all tests and READMEs), so `upstream-merge.sh` applies it only to `src/` of the delta packages (spec files left out, lines the same file also removes left out) and asks a decision for each hit there plus every native pin the tag's lockfile no longer has; the other rows get their verdict from the gates and the device run.

## 2. Device gotchas

| Symptom | Cause | What to do |
|---|---|---|
| `EACCES … link …tmp -> session.v4.jsonl.zstd` in M3 | a new hard-link site, or the `atomic-write` fallback lost `EACCES` | adaptation bug: keep the no-hard-link publish |
| Process killed on JIT / `Signal 5` | node lost its `.permission` section | sign by stripping only `.codesign`, never `.permission` (`make-node.sh` checks it) |
| A library refuses to load under the CLT node | vendor-signed processes refuse self-signed libraries | always run the tree with the `make-node.sh` node |
| `.node` fails to load from tmp; UDS bind fails | `/tmp` cannot exec, dlopen or bind UNIX sockets | `TMPDIR` under el2 base (the root's `tmp/`); `NARB_DISABLE_NATIVE_CACHE=1`; UDS path ≤ 108 bytes |
| 0600 file reads back 0640 | the home filesystem | keep state and the env file in el2 base |
| Unsigned ELF cannot exec | the device runs only signed ELF | the ELF sweep removes unsigned prebuilds; every native must come from `build-natives.sh` |
| `EBADPLATFORM` installing the flock platform package | npm refuses an `os: openharmony` direct dependency on a Linux host | the recipe unpacks the tarball into the tree (by design) |
| koffi does not compile | OHOS musl lacks `statx()` | `ohos-compat/statx-compat.h` + `OHOS_ALLOW_UNDEFINED_SYMBOLS=ON` |
| `__clear_cache` undefined linking rg | PCRE2 JIT on the OHOS target; rustc links with `-nodefaultlibs` | link the NDK's `libclang_rt.builtins.a` (in `build-natives.sh`) |
| sharp has no native build | no openharmony prebuild | `@img/sharp-wasm32` at the lockfile's version; must equal sharp's version |
| Terminal never reported idle | device procfs has `tty_nr`/`tpgid` 0 and no `task/<tid>/syscall` | known, not blocking (upstream-worthy issue) |
| `/bin/sh` scripts fail on bash syntax | `/bin/sh` is mksh; HiShell logs in with zsh | device-side scripts stay POSIX sh; the bash tool uses `/usr/bin/zsh` |
| `ssh hmos`: `Connection refused` | the PC rebooted or the HiShell tab with sshd closed; nothing restarts it | **needs a human** (`restore-ssh.sh` in HiShell; a stale `~/.harmonybrew/var/sshd.pid` can make it think sshd runs) |
| `EADDRINUSE 127.0.0.1:3080` for the device web | a stale `hdc rport tcp:3080` from the VM's dsh-web | `smoke.sh --m6` uses port 3999 (`M6_PORT`), and a second root checks the port first; never touch hdc forwards |
| Readings disturbed | another session drives the device (evals, the maintainer's dsh, hvigor) | `deploy.sh` refuses while hvigor or dsh runs (on a second root: a process under that root); wait until the device is idle before smoking |
| Developer mode lost | OTA may reset it (unverified) | needs a human |

## 3. Build machine gotchas (oh-vm, 9 GB RAM, shared)

| Symptom | Cause | What to do |
|---|---|---|
| `pnpm run lint` killed | tsgolint reaches ~7 GB RSS | run changed-path oxlint: `pnpm exec tsx scripts/run-oxlint.ts <paths>` |
| typecheck / `build:artifacts` OOM (`Killed`, exit 137, heap out of memory) | 8 GiB compiler heaps (from 0.2.2-alpha.2) next to anything else | run it alone; `build:artifacts --serial` where available (`OH_BUILD_ARGS=--serial` for `pack-tree.sh`); an OOM is `environment`, not a code defect |
| Worktree does not fit | `/tmp` is a 4.9 GB tmpfs | work trees and the tree live under `~/.cache` |
| Host disk full = zeroed files | the guest disk is a sparse image on the PC's disk | check `~/.bin/disk-guard.sh --check` (the host mount `/mnt/linux_share/storage/Users/currentUser` is the number that matters, not `df /`) before a build |
| A build waits forever | the cargo build slot or another session's node build | `OH_WAIT_MAX` bounds every wait of the recipe scripts, which then exit 75 |
| `build-natives.sh` clones from GitHub | `src/narb` missing | set `NARB_SRC` to a local checkout; `OH_OFFLINE_SOURCES=1` fails instead of cloning |
| Headless exits 0 although a tool failed | upstream behaviour | M3 checks tool results, not only the exit code |
| `doc-sync` reds unrelated to the change | e.g. `python/sdk/uv.lock` commit-hash check | classify by re-running on the pristine tag |
| `doc-sync`: `documentation build` / `doc graphs` exit 134 | V8 heap abort with the default heap on this machine (rc.2 merge, 9.2 GB peak) | `NODE_OPTIONS=--max-old-space-size=4096 DSH_GATE_CONCURRENCY=1 pnpm run doc-sync` |
| session-persistence-jsonl: ~370 failures in a fresh worktree | `--ignore-scripts` skipped the host flock addon | `pnpm run build:native-system` (`build.ts --host-addon-only`) after the install |
| `node --test` in `native/system` fails | the bare form picks up `test/fixtures/` and needs a musl `landlock-run` | `node --test ./test/flock.test.js ./test/package-matrix.test.js ./test/release-packing.test.js` |
| four flock tests: `spawn …/test/bin/glibc/flock-oracle ENOENT` | a fresh worktree has no C flock oracle | `node ./scripts/build-test-oracle.mjs` in `native/system` first (its musl variant fails without `musl-gcc`; the glibc one is what oh-vm uses) |
| Committing the merge takes minutes and rewrites upstream files | lefthook pre-commit lints and fixes every staged path of the range | `LEFTHOOK=0` for the merge commit only; later commits run the hooks |
| Coverage / Windows-path reds in subprocess-local and bash-local (rc.2) | upstream: red on the pristine tag too | `upstream-merge.sh` compares the failures with the pristine tag's; only a failure the tag lacks is an adaptation |
| The first push of a merge takes ~15 min | the fork receives the range's upstream objects (rc.2: 1568 commits) | expected; the pre-push typecheck is ~1 min of it |
