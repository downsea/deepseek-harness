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
$R/push-env.sh hmos
$R/deploy.sh $W/out/tree $W/node hmos
$R/smoke.sh --m3 --m6 hmos
```

`deploy.sh` 把 `/data/storage/el2/base/dsh/bin` 加进 HiShell 的 `PATH`（`~/.zshrc` 里一个带标记的块），所以在设备的 HiShell（zsh）里运行 `dsh --profile headless --help`；Web UI 用 `dsh-web`：它在 `127.0.0.1:3080` 上提供服务（回环是 web profile 的默认值），并在设备浏览器中打开带 token 的 URL；`dsh-web --port <n>`、`--no-open`、`--profile <name>`、`--patch <file>` 与 `-- <dsh 参数>` 可调整行为，`dsh-web --help` 列出全部选项。端口已被占用时它拒绝启动，并指出常见原因：VM 上 `dsh-web` 留下的过期 `hdc rport`。启动脚本是 zsh 脚本，它加载 `bin/oh-env.sh`，后者从 `/data/storage/el2/base/.env.private` 读入 key，并清除宿主文件里设置的代理变量。启动脚本总会在参数前加上 `--patch <tree>/oh/openharmony.patch.yml`，因此 `--profile` 等启动器选项必须写全，不能用 `dsh <name>` 简写。

## brew 包

PC 上的安装就是 harmonybrew 包。`pack-bottle.sh --payload-only` 组装该包要部署的 payload —— 即 `deploy.sh` 写到默认根的那份安装：`tree/`、`node/bin/node` 与 `bin/{oh-env.sh,dsh,dsh-web}` —— 所以包升级原地替换 `/data/storage/el2/base/dsh`，`~/.zshrc` 里的 PATH 块继续有效。formula 由发布工具 `hmos-brew-release`（`nan/dsh-superagent` 的 `tools/hmos`，ADR-0006）生成：它签名 payload、在设备上冒烟、把它打成 bottle 并渲染 `Formula/dsh.rb`；其 `post_install` 运行 payload 里的 `brew/deploy-payload.sh`，该脚本先校验排队的树（`oh/SHA256SUMS`，再从暂存副本跑 `dsh --version`），然后换入；根上有 dsh 在运行时拒绝执行。

```sh
$R/pack-bottle.sh --payload-only $W/out/tree $W/node $W/bottle
```

该命令写出 `$W/bottle/payload/` 并打印它。发布 Ticket 把该目录交给 `hmos-brew-release next --tree $W/bottle/payload --pr <已合并的 PR>`；bottle、`Formula/dsh.rb` 与 Gitea release 都由该工具写出，本仓没有写 tap 或 bottle 目录的代码路径。

在 PC 上：`brew update && brew install downsea/hmos/dsh`，之后用 `brew upgrade dsh`；然后 `dsh --version` 与 `dsh-web`。`ROOT` 覆盖启动器使用的部署根。

## 脚本

| 脚本 | 行为 | 失败条件 |
|---|---|---|
| `lib.sh` | 公共路径、按绝对路径调用 ssh（`OH_SSH`）、等待正在运行的 cargo、rustc 或 box64（由 `OH_WAIT_MAX` 限时）、`nice -n 10 taskset -c 0-2` 限核、`sign_elf`，以及第二设备根与属主检查 | — |
| `build-natives.sh <dsh> <out>` | 用 NDK clang 编 require-builtin（napi-v9）、node-pty 与 koffi（`-static-libstdc++ -z max-page-size=4096`），经检出目录的 `native/system/scripts/build.ts --target openharmony-arm64` 编 flock，编 `@vscode/ripgrep` 所带版本的 crates.io ripgrep（`cargo install --locked --features pcre2 --target aarch64-unknown-linux-ohos`，为 PCRE2 JIT 链入 NDK 的 compiler-rt builtins），然后逐件签名 | 钉住的版本与检出目录的 `pnpm-lock.yaml` 不符；NEEDED 含 `libc.so` 以外的库；签名后的文件缺 `.codesign`；任一 LOAD 段 offset ≢ vaddr (mod 4K) |
| `make-node.sh <clt-node> <out>` | 只从厂商签名的 node 中删除 `.codesign`，再自签 | 源文件没有 `.permission` 段，或签名删除、改动了它 |
| `pack-tree.sh [--no-build] <dsh> <natives> <out>` | 运行 `build:artifacts --profile official` 与 `.github/workflows/release.yml` 的三次打包，再仿照 `scripts/release/verify-packed-install.ts` 用 `file:` tarball 安装，平台兼容性按 `openharmony/arm64` 判断（`npm install --ignore-scripts --omit=optional --os=openharmony --cpu=arm64`）；按 lockfile 版本加装 `@img/sharp-wasm32`；放置原生插件与 `@vscode/ripgrep-openharmony-arm64` 包，并扫描所有 ELF 文件 | 缺少放置目标包；已签 ELF 有不同余的 LOAD 段；已签 ELF 数与放置数不符 |
| `pack-bottle.sh --payload-only <tree> <node-out> <out>` | 组装发布 payload `<out>/payload/` —— `tree/`、`node/bin/node`、`bin/{oh-env.sh,dsh,dsh-web}`、`VERSION` 与 `deploy-payload.sh`；发布工具负责签名、设备冒烟、打成 bottle 并生成 formula | 输入不是 `pack-tree.sh` 的树或 `make-node.sh` 的 node |
| `deploy.sh <tree> <node-out> <alias>` | 设备上有 hvigor 或 dsh 在运行时拒绝执行；推送 node 与树（新树解包到旧树旁边，再用 `mv` 替换）；写 `bin/oh-env.sh`、`bin/dsh` 与 `bin/dsh-web`，并在 `~/.zshrc` 中加入一次 `PATH` 块；在设备上运行 `sha256sum -c`。第二设备根的行为不同（见第二设备根） | 设备侧校验和不符；属主标记不符 |
| `dsh-web.zsh` | 在设备上装为 `bin/dsh-web`：检查端口，运行 `bin/dsh --profile web --no-open`，并用 `aa start -b com.huawei.hmos.browser` 打开第一条 `dsh web:` URL | 端口已被占用；dsh web 以非零退出 |
| `push-env.sh <alias> [env-file]` | 把宿主的 `~/.env.private`（默认）以 0600 权限复制到 `/data/storage/el2/base/.env.private`，不打印内容；设备 home 会把 0600 读回为 0640。`--root <root>` 改为写入第二设备根的环境文件 | 设备侧 sha256 或权限不符；第二设备根的文件含凭据形态的名字 |
| `smoke.sh [--m3] [--m6] <alias>` | M1 运行 `device-smoke.cjs`；M2 运行 `--profile headless --help`；`--m3` 回放两段录制的会话；`--m6` 运行搜索、终端、图片与 Web 检查 | M1 或 M2 失败 |
| `device-smoke.cjs` | 设备上的 M1：经各包自己的加载器加载每个原生插件，并要求映射的文件位于树内；经树内 `@vscode/ripgrep` 解析 `rg` 并运行一次 | 每项失败使退出码加一 |
| `m6-terminal.mjs` | 设备上的 M6：经 `dsh-subprocess-local` 启动 `/bin/sh` 与 `/usr/bin/zsh` 终端，检查回显、resize 与关闭，并打印空闲时与 `sleep` 运行时的活动状态 | 每项失败使退出码加一 |
| `m3-inspect.cjs` | 打印某个 dsh home 下最新会话日志中的工具调用与结果 | 没有会话日志 |
| `sa-device-verify` | 针对一个提交在 agent 设备根上运行配方，每次调用一步，并打印证据 | 见第二设备根 |
| `delta-check.sh <tag>` | 比较合入发布的 head 所带的本地改动与 `master` 上的本地改动 | 有路径或改动行不同且未列出 |

## 原生插件放置

| 原生插件 | 树内路径 | 加载方 |
|---|---|---|
| require-builtin | `node_modules/node-addon-require-builtin/build/napi/napi-v9-openharmony-arm64/require_builtin.node` | `node-addon-native-custom-loader` 的本地构建分支，需 `NARB_DISABLE_NATIVE_CACHE=1` |
| node-pty | `node_modules/node-pty/prebuilds/openharmony-arm64/pty.node` | `lib/utils.js` 的 `loadNativeModule`；不需要 `spawn-helper` |
| koffi | `node_modules/koffi/build/koffi/openharmony_arm64/koffi.node` | `src/koffi/index.cjs` |
| ripgrep | `node_modules/@vscode/ripgrep-openharmony-arm64/bin/rg`（包由 `pack-tree.sh` 写出） | `@vscode/ripgrep` 解析 `@vscode/ripgrep-${platform}-${arch}/bin/rg` |
| sharp | `node_modules/@img/sharp-wasm32/`（WebAssembly，无需签名） | `sharp/dist/sharp.cjs` 平台 switch 之后的最后一个回退 |
| flock | `node_modules/@deepseek-ai/node-addon-system-openharmony-arm64/bin/system.node` | `@deepseek-ai/node-addon-system/flock` 入口；M1 按路径加载该文件。`pack-tree.sh` 用签名后的构建打包 `native/system/packages/openharmony-arm64`，再把 tarball 解包进树，因为在 Linux 构建机上 npm 拒绝把该包作为直接依赖 |

## 设备环境

`bin/oh-env.sh` 为每次设备运行设置以下值。

| 变量 | 值 | 原因 |
|---|---|---|
| `TMPDIR` | `/data/storage/el2/base/tmp` | `/tmp` 可写，但不能执行、不能 `dlopen`、不能绑定 UNIX socket |
| `NARB_DISABLE_NATIVE_CACHE` | `1` | 否则加载器会先把 `.node` 文件复制到临时目录再加载 |
| `SHELL` | `/bin/sh` | 沙箱没有 bash，也没有 passwd 条目，`os.userInfo()` 会抛错 |
| `DSH_HOME` / `DSH_AGENTS_HOME` | `/data/storage/el2/base/dsh-home` / `dsh-agents`（默认值） | home 目录不能建硬链接，`0600` 读回为 `0640` |

`openharmony.patch.yml` 把 bash 工具的 `shellPath` 设为 `/bin/sh`，因为设备的 `/bin/sh` 是 mksh，没有 bash。它还把 Web 工作区控制器的 `documentsDirectory` 设为 `/data/storage/el2/base/dsh-documents`，因为该控制器只在 macOS、Windows 与 Linux 上查找 Documents 目录；没有这一行的 profile 忽略它。

## M3 回放

`smoke.sh --m3` 经 `dsh-llm-replay`（`m3-replay.patch.yml`）回放 `snapshots/session/` 中两段录制的会话，因此设备上不放任何凭据，也没有请求离开设备。`bash-tool-turn` 经 `shellPath` 运行一条 bash 工具命令；`fs-write` 用 write 工具新建一个文件。只有 dsh 以 0 退出、最新会话日志中每个工具调用都成功、且日志旁有会话锁文件时，该次运行才打印 `verdict=ok`。

## M6 检查

`smoke.sh --m6` 用树内的 `rg` 搜一处固定命中；用 `m6-replay.patch.yml` 回放 `fs-glob-sampling`（glob 工具，`rg --files`）与 `pty-tools-sandbox-backend`，该 overlay 把录制时的内存终端后端换成真实的 `dsh-terminal-bash` 栈，其 shell 先打印 `PTY_M6_OK`；运行 `m6-terminal.mjs`；经 sharp 缩放一张图片；在 `127.0.0.1:$M6_PORT`（默认 3999）启动 web profile，用启动令牌登录后请求 `/`，再停掉服务。每部分各打印一行 `verdict=`；Web 部分以 HTTP 200 为通过。

## 第二设备根

非默认的 `DSH_OH_ROOT` 是给另一个属主用的、自成一体的第二设备根：Super-agent 在 `/data/storage/el2/base/dsh-sa`（属主 `superagent-dsh`）上验证发布，从不碰默认根。对第二设备根，`deploy.sh` 把 `tmp`、`home`、`agents` 与 Web 的 `documents` 都放在根下（`bin/root.patch.yml` 设置 documents 目录），让 `bin/oh-env.sh` 读入 `<root>/env` 而不是 `/data/storage/el2/base/.env.private`，只有该文件设置 `DSH_OH_WITH_OH=1` 时才加载 oh 的 `env.sh`，不改动 `~/.zshrc`，并且只在根下有进程运行时拒绝执行。首次部署写入 `<root>/.owner`；`DSH_OH_OWNER`（默认 `maintainer`）与之不符时，`deploy.sh`、`push-env.sh --root` 与 `smoke.sh` 都拒绝执行；默认根只接受 `maintainer`。

| 变量或选项 | 作用 |
|---|---|
| `DSH_OH_ROOT`、`DSH_OH_OWNER` | 设备根与其属主 |
| `push-env.sh --root <root> [--allow-credentials] <alias> <file>` | 写入 `<root>/env`，来源绝不是 `~/.env.private`；只接受 `NAME=value` 行与注释，名字含 KEY、PASSWORD、SECRET 或 TOKEN 时拒绝，除非给出 `--allow-credentials` |
| `OH_SSH` | ssh 可执行文件，默认 `/usr/bin/ssh`，因为无人值守的调用方可能屏蔽裸名 |
| `OH_WAIT_MAX`、`OH_WAIT_STEP` | 把等待 cargo、rustc、box64 或 node 构建的时间限制在该秒数内，超时以 75 退出 |
| `OH_BUILD_ARGS` | 追加给 `build:artifacts` 的参数，例如 `--serial` |
| `NARB_SRC`、`OH_OFFLINE_SOURCES=1` | 从本地 checkout 克隆 require-builtin；不从 GitHub 克隆，缺源码时直接失败 |

`sa-device-verify` 针对某个 checkout 的 `HEAD`，在 agent 设备根上运行整条配方，每次调用只跑一步（`next`，另有 `status`、`evidence`、`reset` 与 `--dry-run`），缓存放在 `~/.cache/dsh-sa-hmos`，使用不含 key 的环境文件 `~/.config/dsh-sa/device.env`。一步完成时退出码为 0，全部完成并打印证据时为 10，构建机或设备忙时为 75，某步失败时为 1，需要人介入时为 2。提交改动了设备侧脚本时，它在部署前停下，直到有人把该提交追加到 `~/.config/dsh-sa/recipe-approved`。`delta-check.sh <tag>` 检查合入发布的 head 是否带上了本地改动。指标见 [METRICS.md](METRICS.md)，隐患见 [KNOWN-ISSUES.md](KNOWN-ISSUES.md)。

## 约束

- 签名在构建机上完成；它的自签产物与在设备上签名逐字节相同。厂商签名的 node 拒绝加载自签库，所以只有 `make-node.sh` 产出的 node 能运行这棵树。
- 设备上没有 bash：`/bin/sh` 是 mksh，HiShell 的登录 shell 是 zsh（`/usr/bin/zsh`）。`bin/dsh` 在 zsh 下运行，叠加层把 bash 工具的 `shellPath` 设为 `/usr/bin/zsh`；`bin/oh-env.sh` 与 `smoke.sh` 的 here-document 保持 POSIX sh，两种 shell 都能运行。
- 干净重跑：在设备上删除 `/data/storage/el2/base/dsh` 后，再运行 `deploy.sh` 与 `smoke.sh`。
