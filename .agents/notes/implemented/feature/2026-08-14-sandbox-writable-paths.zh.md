# Agent Note: Deployment-level writable paths on the sandbox policy

Status: implemented

[English](2026-08-14-sandbox-writable-paths.md) | 中文

## Problem

`workspace-write` 恰好授予会话工作区加后端临时区域，但真实部署会运行向所有工作区之外的合法状态目录（例如 `~/.local/state/<tool>/`）追加内容的工具与 hook。在受限模式下这些写入会以 `Read-only file system` 失败，唯一出路是 `danger-full-access`——为放行一个已知状态目录放倒整个沙箱。按「插件不硬编码可调参数」规则，随部署变化的可写根集合应当是经验证的配置，而不是代码里的常量或一次模式降级。

## Decision

`SandboxExecutionPolicy` 携带可选的 `writablePaths?: readonly string[]`——仅由 `workspace-write` 消费的额外绝对根。`read-only` 保持故障安全，不授予其中任何一个；`danger-full-access` 绕过隔离，与之无关。与 `workspaceRoot` 一样，即使在不消费它的模式下，该字段也随每份解析出的策略携带。

`dsh-sandbox-policy` 拥有该旋钮：经 schema 验证的 `writablePaths` 配置列表，在加载时解析为绝对规范根（相对条目相对 `process.cwd()`，与 `workspaceRoot` 同一套解析），且仅在非空时由 `resolve()` 携带。该集合是部署级的——每次调用看到同一组根，没有逐会话覆盖事件。`sandbox:policy` 上下文仅在配置了根时才在 `workspace-write` 文本后追加一句 `Additional writable roots: …`；未配置时的渲染与先前文本逐字节相同，因此既有 snapshot 与 KV-cache 前缀不受影响，且 `read-only` 文本绝不携带这些根。

`dsh-sandbox-local` 的强制执行：bwrap profile 为每个根添加一对 `--bind-try <root> <root>`——用 `--bind-try` 而非 `--bind`，因为状态目录允许在启动时尚不存在；bwrap 会跳过缺失的源而不是让包装失败，之后的受限执行会在其存在后绑定它。Landlock profile 将这些根追加进读写 allow-list。两者都只在 `workspace-write` 分支生效。

Seatbelt 与 windows-acl 档不消费该字段。Seatbelt 的授权派生自共享的 `writableRoots` 辅助函数（同时也是 `dsh-fs-sandbox` 围栏的 allow-list），因此在那里消费被推迟到该辅助函数为两个消费方一起改变时。windows-acl seam 恰好授予两个身份（工作区 SID、私有临时 SID）；第三类授权需要为 seam 并不拥有的目录单独决定 ACE 生命周期（常驻还是可撤销），因此接线被推迟，并在该包 README 中记录为限制。不消费是响亮的而非静默的：当 `workspace-write` 策略在这些档上携带 `writablePaths` 时，提供方在其生命周期内记录一次 warning。相对配置意图，强制执行只会收窄，绝不放宽。

## Alternatives considered

**逐会话 `writablePaths` 覆盖（像模式切换那样的 `sandbox/…` 事件）。** 拒绝：动机消费方是部署形态的（hook 与工具的状态目录由主机而非会话决定），且会话可写的放宽事件会让受限 agent 通过日志放宽自己的边界。

**bwrap 用 `--bind` 而非 `--bind-try`。** 拒绝：缺失的状态目录会让每次受限启动都失败，直到有人创建它，把可选授权变成硬性启动依赖；`--bind-try` 的缺失即跳过正是想要的存在性语义。

**在同一变更中让 `writableRoots`（Seatbelt + fs 围栏）消费 `writablePaths`。** 推迟而非拒绝：这是连贯的下一步（它消除该辅助函数本就为防止的 bash／写入工具不对称），但会把变更扩大到 fs seam 的 allow-list 与测试面；在此之前，逐生命周期 warning 与 README 限制条目保持缺口可见。

**以 `danger-full-access` 作为 workaround。** 拒绝作为稳态：它为放行一个目录移除所有边界，且其渲染会向模型宣告完全没有约束。

## Consequences

`workspace-write` 部署可以在不放倒沙箱的情况下白名单化已知的外部状态目录；bwrap 与 Landlock 强制执行它们，且模型恰好在额外根存在时被告知。配置了 `writablePaths` 的 Seatbelt 与 Windows 部署会得到一条日志 warning 和不变（更窄、故障安全）的强制执行，直到这些后端接线。进程内的 `dsh-fs-sandbox` 围栏同样尚不消费这些根，因此文件工具在那里仍会拒绝 bash 允许的写入——推迟的 `writableRoots` 一步会同时关闭这两个缺口。
