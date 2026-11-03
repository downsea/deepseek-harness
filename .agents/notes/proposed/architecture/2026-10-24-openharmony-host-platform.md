# Agent Note: OpenHarmony as a host platform

Status: proposed

English | [中文](2026-10-24-openharmony-host-platform.zh.md)

## Problem

Node builds for OpenHarmony report `process.platform === 'openharmony'` (`@types/node` omits the value). On the HarmonyOS PC terminal sandbox (MOR-M1, HarmonyOS 7.0.0.111, API 26, arm64, OHOS musl `libc.so`) three host assumptions stop dsh before its first shell command:

- **flock.** `@deepseek-ai/node-addon-system/flock` refuses every platform except `linux` and `darwin`, and no platform package exists for `openharmony-arm64`. The first Session write takes its lease through this binding, so every new Session fails. On the device, `flock(2)` excludes between processes on both writable filesystems.
- **Bash.** `dsh-bash-local` and `dsh-bash-sandbox` spawn the literal `bash`. The device has no Bash; `/bin/sh` is mksh R59. Every `bash` tool call fails at spawn.
- **Account database.** `os.userInfo()` throws `ERR_SYSTEM_ERROR` (`uv_os_get_passwd` returned `ENOENT`) because the app sandbox uid has no passwd entry. `dsh-subprocess-local` calls it in `terminalEnvironment()` when `SHELL` is unset, so terminal shell discovery throws instead of reporting no default.

The web profile adds terminal sessions, and with them a fourth assumption:

- **Process inspection.** `dsh-subprocess-local` creates its process inspector before it allocates a PTY, and the inspector factory throws `terminal inspection is unsupported on platform openharmony`. Every web terminal fails before node-pty runs. On the device, `forkpty`, the window-size ioctls, `SIGWINCH`, and EIO after the slave closes behave as on Linux, and an NDK-built node-pty reads back `pty-ok`.

Hard-link publication fails on the same device; [no-clobber publication without hard links](2026-10-24-no-clobber-publish-without-hard-links.md) owns that change.

## Proposal

### Platform name

The platform is `openharmony`, the value Node reports. Platform packages, `os` fields, prebuild metadata, and runtime checks use it verbatim; no alias such as `ohos` or `harmonyos` is introduced. A module that compares `process.platform` against it widens the value to `string`, because the `@types/node` union does not contain it.

### flock platform package

- `@deepseek-ai/node-addon-system-openharmony-arm64` carries one `bin/system.node` (`os: ["openharmony"]`, `cpu: ["arm64"]`, no `libc` field). OpenHarmony has one libc, so `prebuilds.json` declares no libc variant and the entry loads `bin/system.node` directly. The C source is unchanged.
- `scripts/build.ts --target openharmony-arm64 --ohos-ndk <native dir>` cross-builds it with the NDK's `llvm/bin/clang -target aarch64-linux-ohos --sysroot=<ndk>/sysroot -D__MUSL__` and the Linux Node-API flags plus `-shared -s -Wl,-z,max-page-size=4096`. The 4 KiB page size keeps PT_LOAD offsets congruent to addresses, which the OpenHarmony binary signer requires. Node-API headers come from the building Node. The output is byte-identical to the research build that passed the device smoke.
- Platform verification accepts `openharmony` as an ELF platform whose addon declares no libc and that carries no Landlock launcher.
- `github-matrix.mjs` records a builder per platform. `openharmony-arm64` has `{ runner: 'ubuntu-24.04', cross: 'openharmony' }`: the public OpenHarmony SDK ships its NDK for x64 Linux, installed by `openharmony-rs/setup-ohos-sdk@v1.0.1` (SDK 5.0.0, `native` component). CI's native legs exclude it; a separate `cross` leg builds it and runs payload-format and packaging checks. The release prebuild leg cross-builds it and skips the runtime flock tests.
- No hosted runner can load the addon, so installed-artifact verification for this package is an on-device smoke run by the release owner before publication. The support matrix states this exception to its native-builder rule. OpenHarmony loads only signed native code; the application that deploys the addon signs it.

### Configurable shell executable

`dsh-bash-local` gains `shellPath: Volatile<string>`, default `bash`, in its Config; `dsh-bash-sandbox` inherits it. Commands run as `[shellPath, '-c', command]`, with `shellPath` as argv[0] unchanged, so the default keeps today's argv, `$0`, and shell diagnostics on every existing host.

- Validation goes through the subprocess capability seam: `ctx.subprocess.resolveExecutable(shellPath)` resolves the value in the provider's execution environment (absolute path verified, bare name looked up on the provider's PATH, relative path with separators rejected).
- The executor resolves the configured value during plugin initialization, so an unresolvable value fails load. A later live change is resolved during the next command's argv preparation, under that command's deadline and cancellation. Only a successful lookup is remembered.
- An unresolvable value rejects with `SubprocessExecutableNotFoundError` naming `shellPath`, with the provider's error as `cause`. An empty value fails at `resolve()`, like the other unusable budgets. Provider lookup failures of other kinds and cancellation pass through unchanged.
- `executeArgv` accepts only an argv preparation function; the explicit-argv overload had no remaining caller. As the `ShellExecutor` contract already states, caller cancellation before process publication rejects `execute()`.

A deployment on OpenHarmony sets `shellPath: /bin/sh` on the bash executor entry.

### Model-visible text is unchanged

`dsh-tool-bash` keeps describing the tool as `bash -c`. Making the description follow `shellPath` would add a shell-dialect fact to the `ShellExecutor` Service Definition, change the tool definition, and require a recorded-session snapshot. Under mksh, Bash-only syntax the model writes fails as an ordinary shell error that the model sees. The bash-local README records this limitation. A later change can add the dialect fact to the Service Definition if device sessions show the mismatch costs turns.

### Missing account record

`terminalEnvironment()` treats `ERR_SYSTEM_ERROR` whose `info.code` is `ENOENT` from `os.userInfo()` as "no login shell" and reports no `defaultShell`, which already lets consumers apply their platform fallback (`/bin/sh` for POSIX terminals). Any other `userInfo()` failure still rejects unchanged. `os.userInfo()` is called only there in `packages/`; `apps/desktop` has its own calls and is out of scope for a headless host.

### Terminal process inspection

`hasLinuxProcfs(platform)` in `dsh-subprocess-local` is true for `linux` and `openharmony`. The three branches that read Linux `/proc` use it: inspector selection, the session check after a terminal's root shell exits, and the zombie-only process-group check of the fallback owner. OpenHarmony therefore uses the Linux inspector, which reads `/proc/<pid>/stat`, `/proc/<pid>/task/<tid>/syscall`, `fd/0`, `fdinfo`, and `mem`. Every other platform name, including `ohos`, still fails inspector creation.

- The device's HongMeng kernel serves `/proc/self/maps` and `/proc/uptime`, and `ps -ef` lists processes. The `/proc/<pid>/stat` field layout and the per-task `syscall` file have not been read on the device.
- The Linux inspector already counts an unreadable or unparsable entry as unobserved: the foreground group is unresolved, so foreground signalling rejects; activity stays `unknown`; the input-wait probe reports false, so PTY readiness uses idle inference; an unreadable `/proc` directory makes a snapshot throw. A layout difference therefore degrades terminal observation instead of failing terminal allocation.
- OpenHarmony has no user systemd, so ordinary and terminal spawns keep the warned fallback owner (`platform openharmony has no native managed range`).
- The platform parameters of the inspector factory, the terminal handle, the spawn internals, and shell-activity preparation are `string`, following the platform-name rule.

### Web profile platform checks left unchanged

These checks reject or skip `openharmony`, and the device offers nothing they could use:

- `dsh-native-command`: `canOpenNativePath()` is false, `nativeFileManager()` is null, and the file-association query returns no applications, so Host UI shows paths as text; an explicit open or reveal request rejects. These paths drive `xdg-open`, `gio`, Finder, or Explorer, and none of them opens an application on the HarmonyOS desktop.
- `dsh-host-directory-picker-auto` resolves to the in-page `browse` picker, so the native picker's rejection is not reached.
- `dsh-api-workspace-controller` first-use initialization rejects with `system Documents directory is unavailable on openharmony`; a deployment sets `documentsDirectory`, as on a Linux host without `xdg-user-dir`.
- `dsh-api-terminal-controller` falls back to `/bin/sh` when the environment reports no default shell, and skips missing candidates such as `bash`.
- `dsh-sandbox-local` has no OpenHarmony runner chain and fails closed for confined modes; the HongMeng kernel has no Landlock, and the device cannot execute an unsigned `bwrap`.

## Alternatives considered

**Map `openharmony` to the Linux musl package.** The OHOS musl `libc.so` is not ABI-identical to upstream musl (`libc.musl-aarch64.so.1`), and the linux packages' `os: ["linux"]` would not install on OpenHarmony through npm. A Linux-musl addon would need a renamed `NEEDED` entry and still be unsigned. A separate package keeps the platform explicit.

**Keep the cross-built package out of CI and release.** Building it only on a developer machine would leave a published entry declaring an optional dependency nobody builds, or a platform package never published. A Linux cross leg is reproducible from a pinned public SDK; only its runtime check moves to the device.

**Resolve `shellPath` to an absolute path and spawn that.** One lookup would then decide the spawned file, but Bash prints `$0` in its diagnostics (`bash: line 1: …` would become `/usr/bin/bash: line 1: …`) and commands can read `$0`; existing model-visible output would change for every deployment. The lookup verifies; argv[0] stays as configured.

**Verify `shellPath` synchronously with `fs.accessSync` at construction.** That ignores the subprocess provider's execution environment (for example an SSH provider) and its scrubbed PATH, and duplicates PATH/PATHEXT search that `resolveExecutable` already owns.

**Fall back to `/bin/sh` when Bash is missing.** A silent fallback would change the dialect without a configuration change and hide a missing referent, contrary to "misconfiguration fails loud".

**Default `shellPath` per platform.** A platform-dependent default inside the plugin is a hidden tunable; the shipped profile composition (`cordis.yml`) can set the value per platform with `!!js` when OpenHarmony becomes a shipped target.

**A separate OpenHarmony process inspector.** It would copy the Linux inspector for a kernel that serves the same files. If the device shows a different `/proc` layout, a subclass can override the differing reads then.

**Use the `ps`-based macOS inspector on OpenHarmony.** It loses session ids, which root-exited activity needs, and depends on `ps` options (`lstart=`, `tpgid=`) whose support in the device's `ps` is unknown.

**Accept `openharmony` only in the inspector factory.** OpenHarmony would then read `/proc` for inspection but not for the root-exit and zombie-group decisions that read the same files. No device fact supports that difference.

## Acceptance criteria

- On OpenHarmony arm64 with the signed addon installed, `tryLockExclusive` acquires and contends as on Linux, and a headless Session takes its lease.
- `native/system` package-matrix tests accept the OpenHarmony package and reject a libc declaration, a Landlock launcher, a wrong ELF architecture, and a Mach-O payload; the flock entry test observes the selected `openharmony-arm64/bin/system.node`.
- With `shellPath: /bin/sh` a `bash` tool call runs under mksh on the device and exits 0; an unresolvable `shellPath` fails plugin load and, after a live change, the next command.
- `terminalEnvironment()` resolves without `defaultShell` for a missing account record and rejects other `userInfo()` failures.
- The CI `cross` leg passes on GitHub with the pinned SDK action.
- `createProcessInspector('openharmony')` returns the Linux inspector and `ohos` still rejects; on `openharmony` the root-exited session check and the zombie-only group check make the Linux decisions.
- On the device, a web profile terminal opens, echoes input, resizes, and closes.

## Risks

- The CI cross leg and the release cross leg have not run on GitHub; the action's SDK download (GitHub mirror with a huaweicloud fallback) is unverified there.
- CI never loads the OpenHarmony addon. A regression that keeps the ELF format valid ships unless the release owner runs the device smoke.
- The public SDK 5.0.0 NDK differs from the API 26 NDK the device build used. The output uses only `flock`, `calloc`, `free`, `__errno_location`, and Node-API symbols, but the two NDKs have not been compared byte-for-byte.
- The model is told it runs Bash while it may run mksh.
- `dependency-catalog.json` is generated from the public npm registry and cannot list the new package until it is published.
- The `/proc/<pid>/stat` layout and the per-task `syscall` file on the HongMeng kernel are unread. A difference shows as `unknown` terminal activity, idle-inferred readiness, and rejected foreground signals, not as a failed terminal.
