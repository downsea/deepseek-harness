# OpenHarmony 设备配方

[English](README.md) | 中文

这些脚本在 aarch64 Linux 构建机上，把一份 dsh 检出目录做成能在开发者模式的鸿蒙 PC 上原生运行的树：用 OpenHarmony NDK 重编的原生插件、自签 node 与自签原生插件。脚本经 ssh 把树推到设备并运行设备冒烟检查。本配方属于 `downsea` fork 的宿主本地工作，不是上游发布路径。

## 前提

| 侧 | 要求 |
|---|---|
| 构建机 | aarch64 Linux；带 OpenHarmony NDK 与 `binary-sign-tool` 的 Linux 命令行工具（默认 `~/tools/command-line-tools`）；node 24.9 或更高版本及 pnpm；能访问 npm registry；git |
| 设备 | 能 `ssh <alias>` 登录宿主终端沙箱；开发者模式；构建机能读到设备命令行工具（默认 `/mnt/linux_share/storage/Users/currentUser/hmos-clt/command-line-tools`，读取其中的 node 与 `include/node` 头文件） |

所有路径都可用环境变量覆盖：`CLT`、`NDK`、`BST`（签名器）、`DEVICE_CLT`、`NODE_INCLUDE` 与 `DSH_OH_ROOT`（设备根目录，默认 `/data/storage/el2/base/dsh`）。

## 运行配方

工作目录必须在磁盘上，不能放在容量小的 tmpfs：worktree、`node_modules` 与打包后的树合计数 GB。

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

在设备上运行 `sh /data/storage/el2/base/dsh/bin/dsh --profile headless --help`。启动脚本总会在参数前加上 `--patch <tree>/oh/openharmony.patch.yml`，因此 `--profile` 等启动器选项必须写全，不能用 `dsh <name>` 简写。

## 脚本

| 脚本 | 行为 | 失败条件 |
|---|---|---|
| `lib.sh` | 公共路径、等待正在运行的 cargo 或 rustc、`nice -n 10 taskset -c 0-2` 限核，以及 `sign_elf` | — |
| `build-natives.sh <dsh> <out>` | 用 NDK clang 编 require-builtin（napi-v9）、node-pty 与 koffi（`-static-libstdc++ -z max-page-size=4096`），经检出目录的 `native/system/scripts/build.ts --target openharmony-arm64` 编 flock，然后逐件签名 | 钉住的版本与检出目录的 `pnpm-lock.yaml` 不符；NEEDED 含 `libc.so` 以外的库；签名后的文件缺 `.codesign`；任一 LOAD 段 offset ≢ vaddr (mod 4K) |
| `make-node.sh <clt-node> <out>` | 只从厂商签名的 node 中删除 `.codesign`，再自签 | 源文件没有 `.permission` 段，或签名删除、改动了它 |
| `pack-tree.sh [--no-build] <dsh> <natives> <out>` | 运行 `build:artifacts --profile official` 与 `.github/workflows/release.yml` 的三次打包，再仿照 `scripts/release/verify-packed-install.ts` 用 `file:` tarball 安装，平台兼容性按 `openharmony/arm64` 判断（`npm install --ignore-scripts --omit=optional --os=openharmony --cpu=arm64`）；放置原生插件并扫描所有 ELF 文件 | 缺少放置目标包；已签 ELF 有不同余的 LOAD 段；已签 ELF 数与放置数不符 |
| `deploy.sh <tree> <node-out> <alias>` | 设备上有 hvigor 或 dsh 在运行时拒绝执行；推送 node 与树（新树解包到旧树旁边，再用 `mv` 替换）；写 `bin/oh-env.sh` 与 `bin/dsh`；在设备上运行 `sha256sum -c` | 设备侧校验和不符 |
| `smoke.sh [--m3] <alias>` | M1 运行 `device-smoke.cjs`；M2 运行 `--profile headless --help`；`--m3` 回放两段录制的会话 | M1 或 M2 失败 |
| `device-smoke.cjs` | 设备上的 M1：经各包自己的加载器加载每个原生插件，并要求映射的文件位于树内 | 每项失败使退出码加一 |
| `m3-inspect.cjs` | 打印某个 dsh home 下最新会话日志中的工具调用与结果 | 没有会话日志 |

## 原生插件放置

| 原生插件 | 树内路径 | 加载方 |
|---|---|---|
| require-builtin | `node_modules/node-addon-require-builtin/build/napi/napi-v9-openharmony-arm64/require_builtin.node` | `node-addon-native-custom-loader` 的本地构建分支，需 `NARB_DISABLE_NATIVE_CACHE=1` |
| node-pty | `node_modules/node-pty/prebuilds/openharmony-arm64/pty.node` | `lib/utils.js` 的 `loadNativeModule`；不需要 `spawn-helper` |
| koffi | `node_modules/koffi/build/koffi/openharmony_arm64/koffi.node` | `src/koffi/index.cjs` |
| flock | `node_modules/@deepseek-ai/node-addon-system-openharmony-arm64/bin/system.node` | `@deepseek-ai/node-addon-system/flock` 入口；M1 按路径加载该文件。`pack-tree.sh` 用签名后的构建打包 `native/system/packages/openharmony-arm64`，再把 tarball 解包进树，因为在 Linux 构建机上 npm 拒绝把该包作为直接依赖 |

## 设备环境

`bin/oh-env.sh` 为每次设备运行设置以下值。

| 变量 | 值 | 原因 |
|---|---|---|
| `TMPDIR` | `/data/storage/el2/base/tmp` | `/tmp` 可写，但不能执行、不能 `dlopen`、不能绑定 UNIX socket |
| `NARB_DISABLE_NATIVE_CACHE` | `1` | 否则加载器会先把 `.node` 文件复制到临时目录再加载 |
| `SHELL` | `/bin/sh` | 沙箱没有 bash，也没有 passwd 条目，`os.userInfo()` 会抛错 |
| `DSH_HOME` / `DSH_AGENTS_HOME` | `/data/storage/el2/base/dsh-home` / `dsh-agents`（默认值） | home 目录不能建硬链接，`0600` 读回为 `0640` |

`openharmony.patch.yml` 把 bash 工具的 `shellPath` 设为 `/bin/sh`，因为设备的 `/bin/sh` 是 mksh，没有 bash。

## M3 回放

`smoke.sh --m3` 经 `dsh-llm-replay`（`m3-replay.patch.yml`）回放 `snapshots/session/` 中两段录制的会话，因此设备上不放任何凭据，也没有请求离开设备。`bash-tool-turn` 经 `shellPath` 运行一条 bash 工具命令；`fs-write` 用 write 工具新建一个文件。只有 dsh 以 0 退出、最新会话日志中每个工具调用都成功、且日志旁有会话锁文件时，该次运行才打印 `verdict=ok`。

## 约束

- 签名在构建机上完成；它的自签产物与在设备上签名逐字节相同。厂商签名的 node 拒绝加载自签库，所以只有 `make-node.sh` 产出的 node 能运行这棵树。
- 在设备上执行的部分（`smoke.sh` 的 here-document、`bin/dsh`、`bin/oh-env.sh`）都是 POSIX sh，因为设备只有 mksh 与 toybox，没有 bash。
- 干净重跑：在设备上删除 `/data/storage/el2/base/dsh` 后，再运行 `deploy.sh` 与 `smoke.sh`。
