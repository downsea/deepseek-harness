# Agent Note: 无硬链接时的不覆盖发布

Status: proposed

[English](2026-10-24-no-clobber-publish-without-hard-links.md) | 中文

## Problem

五个 POSIX 发布点依赖 `link(2)`，把一个完整的暂存文件放到一个必须尚不存在的名字下：第一份 JSONL 会话日志（[`session-persistence-jsonl/src/index.ts`](../../../../packages/session/session-persistence-jsonl/src/index.ts)）、迁移后的 JSONL generation（[`generation.ts`](../../../../packages/session/session-persistence-jsonl/src/generation.ts)）、附件对象及其显示名别名（[`attachment-local/src/store.ts`](../../../../packages/attachment/attachment-local/src/store.ts)），以及写工具的带防护创建（[`fs-local/src/fsio.ts`](../../../../packages/fs/fs-local/src/fsio.ts)）。裸 `rename(2)` 会静默替换并发创建者的文件，所以每个发布点都用硬链接，并把 `EEXIST` 当作冲突。

有些文件系统拒绝硬链接。在鸿蒙 PC 的终端沙箱（MOR-M1，HarmonyOS 7.0.0.111，API 26）上，所有可写目录里的 `link(2)` 都以 `EPERM` 失败；而 `open(path, 'wx')` 与 `copyFile(…, COPYFILE_EXCL)` 正常报告 `EEXIST`，`rename(2)` 原子替换，`fsync` / `fdatasync` 与目录 `fsync` 都成功。在该设备上，每个新会话在第一次 append 时失败，每次附件保存都失败，写工具无法新建文件。

同一附件路径上还有一个相关失败：首次写入前，`attachment-local` 会把 `DSH_HOME` 的每个祖先一直同步到 `/`。同一沙箱拒绝打开 `/storage/Users`（`EPERM`）以及 `/storage`、`/`、`/data/storage/el2`（`EACCES`），因此即使 `DSH_HOME` 位于可写的 `/data/storage/el2/base` 之下，这一逐级同步也会失败。

## Proposal

在 [`dsh-atomic-write`](../../../../packages/util/atomic-write/README.zh.md) 中加入 `publishNoClobber(source, target, options)`，让五个发布点都经由它发布。

- **先试硬链接。** 调用先尝试 `link(2)`（或调用方注入的链接原语）。成功以及除“缺少硬链接支持”之外的所有失败保持今天的含义，因此支持硬链接的 Linux、macOS 与 Windows 文件系统行为不变。
- **回退触发条件。** 只有 `EPERM`、`EACCES`、`ENOTSUP`、`EOPNOTSUPP` 与 `ENOSYS` 选用回退。在鸿蒙 PC 上，home 文件系统（hmdfs）以 `EPERM` 拒绝硬链接，应用数据文件系统（hmfs，`/data/storage/el2/base` 之下）以 `EACCES` 拒绝，而两者都允许同一目录内的 rename。这两个错误码背后真正的权限故障仍会失败，因为每种回退都在同一目录中创建或 rename，会遇到同样的拒绝。`EEXIST` 仍是冲突。排除 `EXDEV`：每个调用方都在目标旁暂存，跨设备报告是调用方缺陷，rename 会重复它。
- **必填的回退选择。** `fallback` 是必填的可辨识值。`{ kind: 'writer-lock', lockFile }` 在 `withFileLock(lockFile)` 下经 `lstat` 确认目标不存在后 rename，目标已存在时报告与硬链接相同字段的 `EEXIST`。`{ kind: 'exclusive-reservation' }` 用一个 `wx` 空文件占住目标，再把暂存文件 rename 覆盖上去。
- **必填的源文件归属。** `source: 'consume'` 允许回退直接 rename 暂存文件。`source: 'keep'` 把源文件复制为目标旁一个已同步的 `COPYFILE_EXCL` 同级文件并 rename 该副本，从而保留源文件名。
- **显式结果。** 调用返回 `'hard-link'` 或 `'rename'`，调用方据此知道其暂存名是否仍存在。失败的调用保留源文件。

### 逐点选择

| 发布点 | 回退 | 锁文件 | 原因 |
|---|---|---|---|
| 第一份会话日志 | `writer-lock` | 日志路径 | 读取方在列出与恢复会话时解析日志；空占位文件会被读成损坏的会话，崩溃后还会永久留下。后端拥有会话目录中的每个名字，且 generation 文件名按严格格式解析，因此 `<log>.lock` 不会冲突。 |
| JSONL generation | `writer-lock` | 当前 generation 路径 | 与第一份日志同目录、同读取方；`EEXIST` 之后的胜者检查本来就会校验竞争目标。 |
| 附件对象 | `writer-lock` | 对象路径 | 对象以十六进制摘要命名。并发去重的写入方若看到空占位文件会报告 `ATTACHMENT_CORRUPT`，崩溃后该摘要会被永久污染。 |
| 附件别名 | `writer-lock`，`source: 'keep'` | 源对象路径 | 别名来自调用方的显示名，所以 `<alias>.lock` 可能是另一个别名，其内容若读作已退出持有者的 PID，会被接管逻辑删除。改为锁住十六进制命名的源对象，串行化同一对象的所有别名。源对象必须保留，因此回退发布一份已同步的副本。 |
| 带防护的文件创建 | `exclusive-reservation` | — | 目录归用户所有。锁同级文件可能与真实文件冲突，例如目标 `yarn` 对应的 `yarn.lock`；而且锁只排除 dsh 写入方，编辑器等其他程序也会在那里创建文件。占位文件排除所有创建者；代价是读取方在 rename 之前可能看到空文件。 |

单独的 `COPYFILE_EXCL` 不能作为任何发布点的回退：它直接写入排他创建的目标，读取方可能看到部分内容，崩溃会留下截断的文件。

### 回退的可观测性

回退不写日志。两条路径发布的字节、冲突结果与每个错误都相同，没有任何内容进入模型请求，且 `dsh-atomic-write` 是没有 logger 的零依赖库。`'hard-link' | 'rename'` 结果让调用方在后续消费者需要时自行报告走了哪条路径。

### 持久 home 边界

`ensureDurableHome` 仍逐级同步 `DSH_HOME` 的每个祖先，但在第一个以 `EACCES` 或 `EPERM` 拒绝打开或同步的父目录处停下，前提是路径上它下面的目录项在本次调用之前已存在。另一主体在本进程无权访问的目录中创建的目录项，其持久性由该主体负责。本次调用在那里创建的目录项无法变为持久，因此保存仍然失败。已证明的 home 之下的逐级同步对任何错误都继续失败。

## Alternatives considered

**`renameat2(RENAME_NOREPLACE)`。** 它在 Linux 3.15+ 与鸿蒙内核上提供原子的不替换 rename，但 Node 没有暴露绑定。经 `koffi` 调用会给五条存储路径和一个零依赖工具包引入原生依赖，设备上还要多一个自签原生件。

**所有发布点用同一种回退。** 全用 `exclusive-reservation` 会让读取方看到空的会话日志和附件对象，崩溃后留下永久污染。全用 `writer-lock` 会在用户工作区放 `.lock` 同级文件，可能与真实文件冲突，且非 dsh 创建者不理会它。

**各发布点手写回退。** errno 分类与冲突报告的五份副本会逐渐分歧；共享 helper 只保留一份分类和一份 `EEXIST` 报告。

**缺少硬链接支持时直接报错。** dsh 在鸿蒙 PC 上将继续不可用，而设备事实表明那里基于 rename 的发布是原子的。

**即使硬链接可用也为别名复制源文件。** 这会让支持硬链接的文件系统上每个显示名别名都多占一份磁盘。

**在第一个非本进程创建的目录处停止 home 同步。** 并发的 dsh 进程可能已创建某一层但尚未同步它，这正是现有逐级同步要覆盖的情形；仅凭存在不能证明持久。

## Acceptance criteria

- 硬链接可用时，五个发布点都以硬链接发布，现有包测试不加修改地通过。
- `link(2)` 以 `EPERM` 失败时，新 JSONL 会话能实体化并读回，generation 能迁移，附件对象与别名能存储并读回，`createIfAbsent` 能创建文件；目标已存在时仍得到该发布点的冲突结果（`EEXIST`、`ATTACHMENT_CORRUPT` 或 `FS_NOT_OBSERVED`）。
- `EIO`、`EXDEV` 等非“不支持”类链接失败不走回退，原样传播；`EACCES` 链接失败而回退同样被拒时，传播 `EACCES`。
- 某个已存在层级之上的祖先拒绝打开时，`DSH_HOME` 下的附件保存成功；拒绝打开的祖先是本次保存所创建目录的父目录时，保存失败。
- 每个改动的 `src` 文件保持逐文件 100% 覆盖。

## Risks

- 崩溃的 `writer-lock` 发布者会留下 `<lockFile>.lock`。记录的 PID 已退出时，下一个发布者接管它；PID 被复用时，后续发布者超时，直到操作者删除该文件，这与所有 `withFileLock` 使用者相同。
- `writer-lock` 的排他性只覆盖指定同一锁文件的 dsh 发布者。dsh 之外的程序若在 `lstat` 与 `rename` 之间创建同一会话日志或附件对象，会被替换；这些目录归 dsh 所有。
- 使用 `exclusive-reservation` 时，若在占位与 rename 之间崩溃，用户目标处会留下空文件，之后的带防护创建会对它报告 `FS_NOT_OBSERVED`。
- 在不支持硬链接的文件系统上，每个附件别名都是其对象的完整副本。
- 把 `EPERM` 当作缺少支持可能掩盖 `link(2)` 真正的权限拒绝；此时回退自身的 `lstat`、`open` 或 `rename` 会报告该拒绝。
