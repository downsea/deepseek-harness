# OpenHarmony device recipe

English | [中文](README.zh.md)

These scripts turn a dsh checkout on an aarch64 Linux build machine into a tree that runs natively on a HarmonyOS PC in developer mode: native addons rebuilt with the OpenHarmony NDK, a self-signed node, and self-signed addons. They push the tree to the device over ssh and run the device smoke checks. The recipe belongs to the `downsea` fork's host-local work and is not an upstream release path.

## Prerequisites

| Side | Requirement |
|---|---|
| Build machine | aarch64 Linux; the Linux Command Line Tools with the OpenHarmony NDK and `binary-sign-tool` (default `~/tools/command-line-tools`); node 24.9 or later with pnpm; npm registry access; git |
| Device | An `ssh <alias>` login into the host terminal sandbox; developer mode; the device Command Line Tools readable from the build machine (default `/mnt/linux_share/storage/Users/currentUser/hmos-clt/command-line-tools`, read for its node and its `include/node` headers) |

Environment variables override every path: `CLT`, `NDK`, `BST` (signer), `DEVICE_CLT`, `NODE_INCLUDE`, and `DSH_OH_ROOT` (device root, default `/data/storage/el2/base/dsh`).

## Run the recipe

The working directory must sit on disk rather than a small tmpfs: the worktree, `node_modules`, and the packed tree take several gigabytes.

```sh
R=~/code/deepseek-harness/scripts/openharmony
W=~/.cache/dsh-hmos-w2
git worktree add --detach $W/wt master && (cd $W/wt && pnpm install --frozen-lockfile)
$R/build-natives.sh $W/wt $W/natives
$R/make-node.sh /mnt/linux_share/storage/Users/currentUser/hmos-clt/command-line-tools/node/bin/node $W/node
$R/pack-tree.sh $W/wt $W/natives $W/out
$R/deploy.sh $W/out/tree $W/node hmos
$R/smoke.sh --m3 hmos
```

On the device, run `sh /data/storage/el2/base/dsh/bin/dsh --profile headless --help`. The launcher always prepends `--patch <tree>/oh/openharmony.patch.yml`, so launcher options such as `--profile` must be written out instead of using the `dsh <name>` abbreviation.

## Scripts

| Script | Behavior | Fails when |
|---|---|---|
| `lib.sh` | Shared paths, the wait for running cargo or rustc, the `nice -n 10 taskset -c 0-2` cap, and `sign_elf` | — |
| `build-natives.sh <dsh> <out>` | Builds require-builtin (napi-v9), node-pty, and koffi with the NDK clang (`-static-libstdc++ -z max-page-size=4096`), builds flock through the checkout's `native/system/scripts/build.ts --target openharmony-arm64`, then signs every product | A pinned version differs from the checkout's `pnpm-lock.yaml`; NEEDED names anything besides `libc.so`; a signed file lacks `.codesign`; any LOAD segment has offset ≢ vaddr (mod 4K) |
| `make-node.sh <clt-node> <out>` | Removes only `.codesign` from the vendor-signed node and self-signs it | The source has no `.permission` section, or signing drops or changes it |
| `pack-tree.sh [--no-build] <dsh> <natives> <out>` | Runs `build:artifacts --profile official`, the three packs of `.github/workflows/release.yml`, and a `file:` tarball install modeled on `scripts/release/verify-packed-install.ts` with platform compatibility judged for `openharmony/arm64` (`npm install --ignore-scripts --omit=optional --os=openharmony --cpu=arm64`); places the addons and sweeps every ELF file | A placement target package is missing; a signed ELF has an incongruent LOAD segment; the signed ELF count differs from the placement count |
| `deploy.sh <tree> <node-out> <alias>` | Refuses while hvigor or dsh runs on the device; pushes node and tree (the new tree unpacks beside the old one and replaces it with `mv`); writes `bin/oh-env.sh` and `bin/dsh`; runs `sha256sum -c` on the device | A device checksum differs |
| `smoke.sh [--m3] <alias>` | M1 runs `device-smoke.cjs`; M2 runs `--profile headless --help`; `--m3` replays two recorded sessions | M1 or M2 fails |
| `device-smoke.cjs` | M1 on the device: loads each addon through its package's own loader and requires the mapped file to be inside the tree | Each failed check adds one to the exit status |
| `m3-inspect.cjs` | Prints the tool calls and results of the newest session log under a dsh home | No session log exists |

## Addon placement

| Addon | Path in the tree | Loaded by |
|---|---|---|
| require-builtin | `node_modules/node-addon-require-builtin/build/napi/napi-v9-openharmony-arm64/require_builtin.node` | The local-build branch of `node-addon-native-custom-loader`, with `NARB_DISABLE_NATIVE_CACHE=1` |
| node-pty | `node_modules/node-pty/prebuilds/openharmony-arm64/pty.node` | `lib/utils.js` `loadNativeModule`; no `spawn-helper` is needed |
| koffi | `node_modules/koffi/build/koffi/openharmony_arm64/koffi.node` | `src/koffi/index.cjs` |
| flock | `node_modules/@deepseek-ai/node-addon-system-openharmony-arm64/bin/system.node` | The `@deepseek-ai/node-addon-system/flock` entry; M1 loads the file by path. `pack-tree.sh` packs `native/system/packages/openharmony-arm64` with the signed build and unpacks the tarball into the tree, because npm refuses that package as a direct dependency on a Linux build host |

## Device environment

`bin/oh-env.sh` sets these values for every device run.

| Variable | Value | Reason |
|---|---|---|
| `TMPDIR` | `/data/storage/el2/base/tmp` | `/tmp` is writable but cannot execute, `dlopen`, or bind a UNIX socket |
| `NARB_DISABLE_NATIVE_CACHE` | `1` | The loader otherwise copies `.node` files into the temporary directory before loading them |
| `SHELL` | `/bin/sh` | The sandbox has no bash and no passwd entry, so `os.userInfo()` throws |
| `DSH_HOME` / `DSH_AGENTS_HOME` | `/data/storage/el2/base/dsh-home` / `dsh-agents` (defaults) | Home directories cannot hold hard links and read `0600` back as `0640` |

`openharmony.patch.yml` sets the bash tool's `shellPath` to `/bin/sh`, because the device has mksh at `/bin/sh` and no bash.

## M3 replay

`smoke.sh --m3` replays two recorded sessions from `snapshots/session/` through `dsh-llm-replay` (`m3-replay.patch.yml`), so no credential is placed on the device and no request leaves it. `bash-tool-turn` runs one bash-tool command through `shellPath`; `fs-write` creates a new file with the write tool. Each run prints `verdict=ok` only when dsh exits 0, every tool call in the newest session log succeeded, and the session lock file exists beside the log.

## Constraints

- Signing happens on the build machine; its self-signed output is byte-identical to signing on the device. The vendor-signed node refuses self-signed libraries, so only the `make-node.sh` node can run the tree.
- Everything executed on the device (the `smoke.sh` here-document, `bin/dsh`, `bin/oh-env.sh`) is POSIX sh, because the device has mksh and toybox without bash.
- A clean rerun is `deploy.sh` and `smoke.sh` after removing `/data/storage/el2/base/dsh` on the device.
