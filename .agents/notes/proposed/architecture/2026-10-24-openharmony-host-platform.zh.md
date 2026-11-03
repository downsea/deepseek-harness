# Agent Note: 以 OpenHarmony 作为宿主平台

Status: proposed

[English](2026-10-24-openharmony-host-platform.md) | 中文

## 问题

OpenHarmony 上的 Node 构建报告 `process.platform === 'openharmony'`（`@types/node` 没有收录这个值）。在 HarmonyOS PC 终端沙箱（MOR-M1，HarmonyOS 7.0.0.111，API 26，arm64，OHOS musl `libc.so`）上，有三处宿主假设让 dsh 在执行第一条 shell 命令之前就失败：

- **flock。** `@deepseek-ai/node-addon-system/flock` 拒绝 `linux` 与 `darwin` 以外的所有平台，也不存在 `openharmony-arm64` 平台包。第一次写 Session 时要通过这个绑定取得 lease，因此每个新 Session 都会失败。在该设备上，`flock(2)` 在两类可写文件系统上都能在进程之间互斥。
- **Bash。** `dsh-bash-local` 与 `dsh-bash-sandbox` 直接 spawn 字面量 `bash`。设备上没有 Bash；`/bin/sh` 是 mksh R59。每次 `bash` 工具调用都在 spawn 时失败。
- **账户数据库。** 由于应用沙箱的 uid 没有 passwd 条目，`os.userInfo()` 抛出 `ERR_SYSTEM_ERROR`（`uv_os_get_passwd` 返回 `ENOENT`）。`dsh-subprocess-local` 在 `SHELL` 未设置时于 `terminalEnvironment()` 中调用它，于是终端 shell 发现会抛错，而不是报告没有默认 shell。

web profile 引入终端会话，随之带来第四处假设：

- **进程检查。** `dsh-subprocess-local` 在分配 PTY 之前先创建进程检查器，而检查器工厂抛出 `terminal inspection is unsupported on platform openharmony`。每个 web 终端都在 node-pty 运行之前失败。在该设备上，`forkpty`、窗口尺寸 ioctl、`SIGWINCH` 以及 slave 关闭后读到 EIO 的行为都与 Linux 一致，用 NDK 构建的 node-pty 能读回 `pty-ok`。

同一设备上硬链接发布也会失败；该改动由[无硬链接的不覆盖发布](2026-10-24-no-clobber-publish-without-hard-links.zh.md)负责。

## 提案

### 平台名

平台名是 Node 报告的 `openharmony`。平台包、`os` 字段、prebuild 元数据与运行时检查都原样使用它，不引入 `ohos` 或 `harmonyos` 之类的别名。把 `process.platform` 与它比较的模块要先把值放宽为 `string`，因为 `@types/node` 的联合类型不包含它。

### flock 平台包

- `@deepseek-ai/node-addon-system-openharmony-arm64` 只携带一个 `bin/system.node`（`os: ["openharmony"]`、`cpu: ["arm64"]`，无 `libc` 字段）。OpenHarmony 只有一种 libc，因此 `prebuilds.json` 不声明 libc 变体，入口直接加载 `bin/system.node`。C 源码不变。
- `scripts/build.ts --target openharmony-arm64 --ohos-ndk <native 目录>` 用 NDK 的 `llvm/bin/clang -target aarch64-linux-ohos --sysroot=<ndk>/sysroot -D__MUSL__` 交叉编译它，沿用 Linux 的 Node-API 编译选项并加上 `-shared -s -Wl,-z,max-page-size=4096`。4 KiB 页大小让 PT_LOAD 的文件偏移与地址同余，这是 OpenHarmony 二进制签名工具的要求。Node-API 头文件取自执行构建的 Node。产物与通过设备冒烟的研究构建逐字节相同。
- 平台校验把 `openharmony` 当作 ELF 平台接受：其 addon 不声明 libc，且不携带 Landlock 启动器。
- `github-matrix.mjs` 为每个平台记录构建者。`openharmony-arm64` 是 `{ runner: 'ubuntu-24.04', cross: 'openharmony' }`：公开的 OpenHarmony SDK 只为 x64 Linux 提供 NDK，由 `openharmony-rs/setup-ohos-sdk@v1.0.1`（SDK 5.0.0，`native` 组件）安装。CI 的原生构建腿不包含它；单独的 `cross` 腿负责构建它，并运行产物格式与打包检查。发布的 prebuild 腿交叉编译它，并跳过运行时 flock 测试。
- 没有托管 runner 能加载这个 addon，所以该包的安装后产物验证改为发布负责人在发布前做的设备冒烟。支持矩阵写明了这是其「原生构建者」规则的例外。OpenHarmony 只加载已签名的原生代码，由部署 addon 的应用对其签名。

### 可配置的 shell 可执行文件

`dsh-bash-local` 在 Config 中新增 `shellPath: Volatile<string>`，默认 `bash`；`dsh-bash-sandbox` 继承该字段。命令以 `[shellPath, '-c', command]` 运行，`shellPath` 原样作为 argv[0]，因此默认值在所有现有宿主上保持当前的 argv、`$0` 与 shell 诊断信息。

- 校验经由 subprocess capability seam：`ctx.subprocess.resolveExecutable(shellPath)` 在提供方的执行环境里解析该值（绝对路径做校验，裸名称在提供方的 PATH 上查找，含分隔符的相对路径被拒绝）。
- 执行器在插件初始化时解析所配置的值，因此无法解析的值会让加载失败。之后的热更新在下一条命令的 argv 准备阶段解析，受该命令的 deadline 与取消约束。只记住成功的查找。
- 无法解析的值以指名 `shellPath` 的 `SubprocessExecutableNotFoundError` reject，并把提供方的错误作为 `cause`。空值与其他不可用的预算一样，在 `resolve()` 时失败。其他类型的提供方查找失败与取消原样传递。
- `executeArgv` 只接受 argv 准备函数；显式 argv 的重载已没有调用方。正如 `ShellExecutor` 契约已经规定的，进程发布前的调用方取消会让 `execute()` reject。

在 OpenHarmony 上的部署在 bash 执行器条目上设置 `shellPath: /bin/sh`。

### 模型可见文本不变

`dsh-tool-bash` 继续把工具描述为 `bash -c`。让描述跟随 `shellPath` 需要在 `ShellExecutor` Service Definition 上增加 shell 方言事实、改变工具定义，并需要录制会话快照。在 mksh 下，模型写出的 Bash 专有语法会以普通 shell 错误失败，模型能看到这个错误。bash-local 的 README 记录了这一限制。如果设备会话表明这种不一致浪费回合，后续改动可以把方言事实加进 Service Definition。

### 缺失账户记录

`terminalEnvironment()` 把 `os.userInfo()` 抛出的、`info.code` 为 `ENOENT` 的 `ERR_SYSTEM_ERROR` 视为「没有登录 shell」，不报告 `defaultShell`；消费方已据此应用各自的平台回退（POSIX 终端为 `/bin/sh`）。`userInfo()` 的其他失败仍原样 reject。`packages/` 中只有这一处调用 `os.userInfo()`；`apps/desktop` 有自己的调用，不在无头宿主的范围内。

### 终端进程检查

`dsh-subprocess-local` 中的 `hasLinuxProcfs(platform)` 对 `linux` 与 `openharmony` 为真。读取 Linux `/proc` 的三个分支都使用它：检查器选择、终端根 shell 退出后的会话检查，以及 fallback 所有者对只剩僵尸成员的进程组的检查。因此 OpenHarmony 使用 Linux 检查器，读取 `/proc/<pid>/stat`、`/proc/<pid>/task/<tid>/syscall`、`fd/0`、`fdinfo` 与 `mem`。其他平台名（包括 `ohos`）创建检查器时仍然失败。

- 设备的 HongMeng 内核提供 `/proc/self/maps` 与 `/proc/uptime`，`ps -ef` 能列出进程。`/proc/<pid>/stat` 的字段布局与每个 task 的 `syscall` 文件尚未在设备上读取过。
- Linux 检查器已经把无法读取或无法解析的条目算作未观察到：前台进程组无法解析，因此前台信号发送会 reject；活动状态保持 `unknown`；输入等待探测返回 false，因此 PTY 就绪判断改用空闲推断；`/proc` 目录不可读时快照抛错。所以布局差异只会降低终端观察能力，不会让终端分配失败。
- OpenHarmony 没有 user systemd，所以普通 spawn 与终端 spawn 继续使用带警告的 fallback 所有者（`platform openharmony has no native managed range`）。
- 检查器工厂、终端句柄、spawn internals 与 shell-activity 准备的平台参数类型为 `string`，遵循平台名规则。

### 保持不变的 web profile 平台检查

以下检查拒绝或跳过 `openharmony`，而设备上也没有它们可用的东西：

- `dsh-native-command`：`canOpenNativePath()` 为 false，`nativeFileManager()` 为 null，文件关联查询不返回任何应用，因此 Host UI 把路径显示为文本；显式的打开或定位请求会 reject。这些路径驱动 `xdg-open`、`gio`、Finder 或 Explorer，它们都无法在 HarmonyOS 桌面上打开应用。
- `dsh-host-directory-picker-auto` 解析为页内的 `browse` 选择器，因此不会走到原生选择器的拒绝。
- `dsh-api-workspace-controller` 的首次使用初始化以 `system Documents directory is unavailable on openharmony` reject；部署方设置 `documentsDirectory`，与没有 `xdg-user-dir` 的 Linux 宿主相同。
- `dsh-api-terminal-controller` 在执行环境不报告默认 shell 时回退到 `/bin/sh`，并跳过 `bash` 等缺失的候选。
- `dsh-sandbox-local` 没有 OpenHarmony 的 runner 链，对受限模式 fail closed；HongMeng 内核没有 Landlock，设备也无法执行未签名的 `bwrap`。

## 备选方案

**把 `openharmony` 映射到 Linux musl 包。** OHOS musl 的 `libc.so` 与上游 musl（`libc.musl-aarch64.so.1`）并非 ABI 相同，而且 linux 包的 `os: ["linux"]` 无法经 npm 安装到 OpenHarmony 上。Linux-musl addon 还需要改写 `NEEDED` 条目，且仍未签名。独立的包让平台保持显式。

**让交叉编译的包不进 CI 与发布。** 只在开发者机器上构建，会让已发布的入口声明一个无人构建的可选依赖，或者产生一个从不发布的平台包。Linux 交叉编译腿可以从固定版本的公开 SDK 复现；只有运行时检查转到设备上。

**把 `shellPath` 解析为绝对路径并 spawn 它。** 这样一次查找就决定了被 spawn 的文件，但 Bash 会在诊断中打印 `$0`（`bash: line 1: …` 会变成 `/usr/bin/bash: line 1: …`），命令也能读取 `$0`；所有部署的现有模型可见输出都会改变。查找只做校验；argv[0] 保持所配置的值。

**在构造时用 `fs.accessSync` 同步校验 `shellPath`。** 这会忽略 subprocess 提供方的执行环境（例如 SSH 提供方）及其清理后的 PATH，还会重复 `resolveExecutable` 已负责的 PATH/PATHEXT 搜索。

**缺少 Bash 时回退到 `/bin/sh`。** 静默回退会在没有配置变更的情况下改变方言，并掩盖缺失的引用对象，违背「错误配置要大声失败」。

**按平台给出 `shellPath` 默认值。** 插件内部依赖平台的默认值是隐藏的可调参数；当 OpenHarmony 成为发货目标时，发货的 profile 组合（`cordis.yml`）可以用 `!!js` 按平台设置该值。

**单独的 OpenHarmony 进程检查器。** 它会为一个提供相同文件的内核复制一份 Linux 检查器。如果设备显示出不同的 `/proc` 布局，届时可以用子类覆盖有差异的读取。

**在 OpenHarmony 上使用基于 `ps` 的 macOS 检查器。** 它没有会话 id，而根 shell 退出后的活动判断需要会话 id；它还依赖设备 `ps` 是否支持 `lstart=`、`tpgid=` 选项，这一点未知。

**只在检查器工厂中接受 `openharmony`。** 那样 OpenHarmony 在检查时读取 `/proc`，而在读取同样文件的根退出与僵尸进程组判断中却不读。没有设备事实支持这种差别。

## 验收标准

- 在安装了已签名 addon 的 OpenHarmony arm64 上，`tryLockExclusive` 的获取与争用行为与 Linux 相同，无头 Session 能取得 lease。
- `native/system` 的 package-matrix 测试接受 OpenHarmony 包，并拒绝 libc 声明、Landlock 启动器、错误的 ELF 架构与 Mach-O 产物；flock 入口测试观察到选中的 `openharmony-arm64/bin/system.node`。
- 设置 `shellPath: /bin/sh` 后，设备上的 `bash` 工具调用在 mksh 下运行并以 0 退出；无法解析的 `shellPath` 让插件加载失败，热更新后则让下一条命令失败。
- 账户记录缺失时 `terminalEnvironment()` resolve 且不带 `defaultShell`，`userInfo()` 的其他失败则 reject。
- CI 的 `cross` 腿在 GitHub 上用固定版本的 SDK action 通过。
- `createProcessInspector('openharmony')` 返回 Linux 检查器，`ohos` 仍被拒绝；在 `openharmony` 上，根退出后的会话检查与僵尸进程组检查做出与 Linux 相同的判断。
- 在设备上，web profile 的终端能打开、回显输入、调整尺寸并关闭。

## 风险

- CI 的交叉编译腿与发布的交叉编译腿都还没在 GitHub 上运行过；该 action 在那里的 SDK 下载（GitHub 镜像，失败时回落到 huaweicloud）未经验证。
- CI 从不加载 OpenHarmony addon。保持 ELF 格式有效的回归，除非发布负责人跑设备冒烟，否则会被发布出去。
- 公开 SDK 5.0.0 的 NDK 与设备构建所用的 API 26 NDK 不同。产物只用到 `flock`、`calloc`、`free`、`__errno_location` 与 Node-API 符号，但两个 NDK 的产物尚未逐字节比对。
- 模型被告知运行的是 Bash，实际可能是 mksh。
- `dependency-catalog.json` 由公开 npm registry 生成，新包发布之前无法列入。
- HongMeng 内核上的 `/proc/<pid>/stat` 布局与每个 task 的 `syscall` 文件尚未读取。若有差异，表现为终端活动 `unknown`、就绪靠空闲推断、前台信号被拒绝，而不是终端失败。
