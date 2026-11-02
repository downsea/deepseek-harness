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
$R/push-env.sh hmos
$R/deploy.sh $W/out/tree $W/node hmos
$R/smoke.sh --m3 --m6 hmos
```

`deploy.sh` puts `/data/storage/el2/base/dsh/bin` on the HiShell `PATH` (a marked block in `~/.zshrc`), so in HiShell (zsh) on the device run `dsh --profile headless --help`, or `dsh-web` for the Web UI: it serves on `127.0.0.1:3080` (loopback is the web profile's default) and opens the tokened URL in the device browser; `dsh-web --port <n>`, `--no-open`, `--profile <name>`, `--patch <file>`, and `-- <dsh args>` adjust it, and `dsh-web --help` lists them. It refuses an occupied port and names the usual cause, a stale `hdc rport` from the VM's `dsh-web`. The launcher is a zsh script that loads `bin/oh-env.sh`, which loads the keys from `/data/storage/el2/base/.env.private` and unsets the proxy variables the host file sets. The launcher always prepends `--patch <tree>/oh/openharmony.patch.yml`, so launcher options such as `--profile` must be written out instead of using the `dsh <name>` abbreviation.

## Scripts

| Script | Behavior | Fails when |
|---|---|---|
| `lib.sh` | Shared paths, ssh by absolute path (`OH_SSH`), the wait for running cargo, rustc or box64 (bounded by `OH_WAIT_MAX`), the `nice -n 10 taskset -c 0-2` cap, `sign_elf`, and the second-root and owner checks | — |
| `build-natives.sh <dsh> <out>` | Builds require-builtin (napi-v9), node-pty, and koffi with the NDK clang (`-static-libstdc++ -z max-page-size=4096`), builds flock through the checkout's `native/system/scripts/build.ts --target openharmony-arm64`, builds the crates.io ripgrep release that `@vscode/ripgrep` ships (`cargo install --locked --features pcre2 --target aarch64-unknown-linux-ohos`, linked with the NDK's compiler-rt builtins for PCRE2 JIT), then signs every product | A pinned version differs from the checkout's `pnpm-lock.yaml`; NEEDED names anything besides `libc.so`; a signed file lacks `.codesign`; any LOAD segment has offset ≢ vaddr (mod 4K) |
| `make-node.sh <clt-node> <out>` | Removes only `.codesign` from the vendor-signed node and self-signs it | The source has no `.permission` section, or signing drops or changes it |
| `pack-tree.sh [--no-build] <dsh> <natives> <out>` | Runs `build:artifacts --profile official`, the three packs of `.github/workflows/release.yml`, and a `file:` tarball install modeled on `scripts/release/verify-packed-install.ts` with platform compatibility judged for `openharmony/arm64` (`npm install --ignore-scripts --omit=optional --os=openharmony --cpu=arm64`); adds `@img/sharp-wasm32` at the lockfile's version; places the addons and the `@vscode/ripgrep-openharmony-arm64` package, and sweeps every ELF file | A placement target package is missing; a signed ELF has an incongruent LOAD segment; the signed ELF count differs from the placement count |
| `deploy.sh <tree> <node-out> <alias>` | Refuses while hvigor or dsh runs on the device; pushes node and tree (the new tree unpacks beside the old one and replaces it with `mv`); writes `bin/oh-env.sh`, `bin/dsh`, and `bin/dsh-web`, and adds the `PATH` block to `~/.zshrc` once; runs `sha256sum -c` on the device. A second root differs (see Second device root) | A device checksum differs; the owner marker differs |
| `dsh-web.zsh` | Installed as `bin/dsh-web` on the device: checks the port, runs `bin/dsh --profile web --no-open`, and opens the first `dsh web:` URL with `aa start -b com.huawei.hmos.browser` | The port is already in use; dsh web exits non-zero |
| `push-env.sh <alias> [env-file]` | Copies the host's `~/.env.private` (default) to `/data/storage/el2/base/.env.private` with mode 0600 without printing it; the device home reads 0600 back as 0640. `--root <root>` writes a second root's env file instead | The device sha256 or mode differs; a second root's file holds a credential-shaped name |
| `smoke.sh [--m3] [--m6] <alias>` | M1 runs `device-smoke.cjs`; M2 runs `--profile headless --help`; `--m3` replays two recorded sessions; `--m6` runs the search, terminal, image and Web checks | M1 or M2 fails |
| `device-smoke.cjs` | M1 on the device: loads each addon through its package's own loader and requires the mapped file to be inside the tree; resolves `rg` through `@vscode/ripgrep` inside the tree and runs it | Each failed check adds one to the exit status |
| `m6-terminal.mjs` | M6 on the device: spawns `/bin/sh` and `/usr/bin/zsh` terminals through `dsh-subprocess-local`, checks echo, resize and close, and prints the activity state while idle and while `sleep` runs | Each failed check adds one to the exit status |
| `m3-inspect.cjs` | Prints the tool calls and results of the newest session log under a dsh home | No session log exists |
| `sa-device-verify` | Runs the recipe for one commit against the agent root, one step per call, and prints the evidence | See Second device root |
| `delta-check.sh <tag>` | Compares the delta a release-merge head carries with the delta on `master` | A path or changed line differs and is not listed |

## Addon placement

| Addon | Path in the tree | Loaded by |
|---|---|---|
| require-builtin | `node_modules/node-addon-require-builtin/build/napi/napi-v9-openharmony-arm64/require_builtin.node` | The local-build branch of `node-addon-native-custom-loader`, with `NARB_DISABLE_NATIVE_CACHE=1` |
| node-pty | `node_modules/node-pty/prebuilds/openharmony-arm64/pty.node` | `lib/utils.js` `loadNativeModule`; no `spawn-helper` is needed |
| koffi | `node_modules/koffi/build/koffi/openharmony_arm64/koffi.node` | `src/koffi/index.cjs` |
| ripgrep | `node_modules/@vscode/ripgrep-openharmony-arm64/bin/rg` (package written by `pack-tree.sh`) | `@vscode/ripgrep` resolves `@vscode/ripgrep-${platform}-${arch}/bin/rg` |
| sharp | `node_modules/@img/sharp-wasm32/` (WebAssembly, nothing to sign) | The last fallback in `sharp/dist/sharp.cjs` after the platform switch |
| flock | `node_modules/@deepseek-ai/node-addon-system-openharmony-arm64/bin/system.node` | The `@deepseek-ai/node-addon-system/flock` entry; M1 loads the file by path. `pack-tree.sh` packs `native/system/packages/openharmony-arm64` with the signed build and unpacks the tarball into the tree, because npm refuses that package as a direct dependency on a Linux build host |

## Device environment

`bin/oh-env.sh` sets these values for every device run.

| Variable | Value | Reason |
|---|---|---|
| `TMPDIR` | `/data/storage/el2/base/tmp` | `/tmp` is writable but cannot execute, `dlopen`, or bind a UNIX socket |
| `NARB_DISABLE_NATIVE_CACHE` | `1` | The loader otherwise copies `.node` files into the temporary directory before loading them |
| `SHELL` | `/bin/sh` | The sandbox has no bash and no passwd entry, so `os.userInfo()` throws |
| `DSH_HOME` / `DSH_AGENTS_HOME` | `/data/storage/el2/base/dsh-home` / `dsh-agents` (defaults) | Home directories cannot hold hard links and read `0600` back as `0640` |

`openharmony.patch.yml` sets the bash tool's `shellPath` to `/bin/sh`, because the device has mksh at `/bin/sh` and no bash. It also sets the Web workspace controller's `documentsDirectory` to `/data/storage/el2/base/dsh-documents`, because the controller looks up the Documents directory only on macOS, Windows and Linux; profiles without that row ignore it.

## M3 replay

`smoke.sh --m3` replays two recorded sessions from `snapshots/session/` through `dsh-llm-replay` (`m3-replay.patch.yml`), so no credential is placed on the device and no request leaves it. `bash-tool-turn` runs one bash-tool command through `shellPath`; `fs-write` creates a new file with the write tool. Each run prints `verdict=ok` only when dsh exits 0, every tool call in the newest session log succeeded, and the session lock file exists beside the log.

## M6 checks

`smoke.sh --m6` runs `rg` from the tree against a fixed match; replays `fs-glob-sampling` (glob tool, `rg --files`) and `pty-tools-sandbox-backend` with `m6-replay.patch.yml`, which replaces the recorded in-memory terminal backend with the real `dsh-terminal-bash` stack whose shell prints `PTY_M6_OK`; runs `m6-terminal.mjs`; resizes one image through sharp; and starts the web profile on `127.0.0.1:$M6_PORT` (default 3999), signs in with the startup token, requests `/`, and stops the server. Each part prints its own `verdict=` line; the Web part passes on HTTP 200.

## Second device root

A `DSH_OH_ROOT` other than the default is a second, self-contained root for another owner: the Super-agent verifies releases on `/data/storage/el2/base/dsh-sa` (owner `superagent-dsh`) and never touches the default root. For a second root, `deploy.sh` keeps `tmp`, `home`, `agents` and the Web `documents` under the root (`bin/root.patch.yml` sets the documents directory), makes `bin/oh-env.sh` load `<root>/env` instead of `/data/storage/el2/base/.env.private`, loads oh's `env.sh` only when that file sets `DSH_OH_WITH_OH=1`, leaves `~/.zshrc` alone, and refuses only while a process under the root runs. The first deploy writes `<root>/.owner`; `deploy.sh`, `push-env.sh --root` and `smoke.sh` refuse when `DSH_OH_OWNER` (default `maintainer`) differs, and the default root accepts only `maintainer`.

| Variable or option | Effect |
|---|---|
| `DSH_OH_ROOT`, `DSH_OH_OWNER` | The root and its owner |
| `push-env.sh --root <root> [--allow-credentials] <alias> <file>` | Writes `<root>/env`, never from `~/.env.private`; accepts only `NAME=value` lines and comments, and refuses names containing KEY, PASSWORD, SECRET or TOKEN unless `--allow-credentials` is given |
| `OH_SSH` | The ssh binary, default `/usr/bin/ssh`, because an unattended caller may block the bare name |
| `OH_WAIT_MAX`, `OH_WAIT_STEP` | Bound every wait for cargo, rustc, box64 or node builds to that many seconds, then exit 75 |
| `OH_BUILD_ARGS` | Extra `build:artifacts` arguments, such as `--serial` |
| `NARB_SRC`, `OH_OFFLINE_SOURCES=1` | Clone require-builtin from a local checkout; fail instead of cloning from GitHub |

`sa-device-verify` runs the whole recipe for the `HEAD` of a checkout against the agent root, one step per call (`next`, plus `status`, `evidence`, `reset` and `--dry-run`), with caches under `~/.cache/dsh-sa-hmos` and the key-free env file `~/.config/dsh-sa/device.env`. It exits 0 when a step is done, 10 when all steps are done and the evidence is printed, 75 when the machine or the device is busy, 1 when a step failed, and 2 when a human is needed. It stops before deploying a commit that changes the device-side scripts until a human appends that commit to `~/.config/dsh-sa/recipe-approved`. `delta-check.sh <tag>` checks that a release-merge head carries the delta. The metrics are in [METRICS.md](METRICS.md) and the hazards in [KNOWN-ISSUES.md](KNOWN-ISSUES.md).

## Constraints

- Signing happens on the build machine; its self-signed output is byte-identical to signing on the device. The vendor-signed node refuses self-signed libraries, so only the `make-node.sh` node can run the tree.
- The device has no bash: `/bin/sh` is mksh and HiShell's login shell is zsh (`/usr/bin/zsh`). `bin/dsh` runs under zsh and the overlay sets the bash tool's `shellPath` to `/usr/bin/zsh`; `bin/oh-env.sh` and the `smoke.sh` here-document stay POSIX sh so either shell can run them.
- A clean rerun is `deploy.sh` and `smoke.sh` after removing `/data/storage/el2/base/dsh` on the device.
