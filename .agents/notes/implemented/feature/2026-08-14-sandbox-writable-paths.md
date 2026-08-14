# Agent Note: Deployment-level writable paths on the sandbox policy

Status: implemented

English | [中文](2026-08-14-sandbox-writable-paths.zh.md)

## Problem

`workspace-write` grants exactly the session workspace plus backend temp areas, but real deployments run tools and hooks that append to legitimate state directories outside every workspace (for example `~/.local/state/<tool>/`). Under the confined modes those writes fail with `Read-only file system`, and the only escape is `danger-full-access` — dropping the whole sandbox to permit one known state directory. Per the no-hardcoded-tunables rule, a deployment-varying set of writable roots belongs in validated config, not in code or in a mode downgrade.

## Decision

`SandboxExecutionPolicy` carries an optional `writablePaths?: readonly string[]` — additional absolute roots only `workspace-write` consumes. `read-only` stays fail-safe and grants none of them; `danger-full-access` bypasses confinement, so they are irrelevant there. Like `workspaceRoot`, the field rides every resolved policy even under modes that do not consume it.

`dsh-sandbox-policy` owns the knob: a schema-validated `writablePaths` config list, resolved to absolute canonical roots at load (relative entries against `process.cwd()`, same resolution as `workspaceRoot`) and carried by `resolve()` only when non-empty. The set is deployment-level — every call sees the same roots, with no per-session override event. The `sandbox:policy` context appends one `Additional writable roots: …` sentence to the `workspace-write` text only when roots are configured; the unconfigured render is byte-identical to the previous text, so existing snapshots and KV-cache prefixes are untouched, and the `read-only` text never carries the roots.

`dsh-sandbox-local` enforcement: the bwrap profile adds one `--bind-try <root> <root>` pair per root — `--bind-try`, not `--bind`, because a state directory is allowed to not exist yet at launch; bwrap skips a missing source instead of failing the wrap, and the next confined execution binds it once it exists. The Landlock profile appends the roots to the read-write allow-list. Both apply only in the `workspace-write` branch.

Seatbelt and the windows-acl rung do not consume the field. Seatbelt derives its grant from the shared `writableRoots` helper (also the `dsh-fs-sandbox` fence's allow-list), so consuming there is deferred until that helper changes for both consumers together. The windows-acl seam grants exactly two identities (workspace SID, private-temp SID); a third grant class needs its own ACE lifecycle decision (standing versus revocable) for directories the seam does not own, so wiring is deferred and the limitation is documented in that package's README. Non-consumption is loud, not silent: the provider logs one warning per lifetime when a `workspace-write` policy carries `writablePaths` on those rungs. Enforcement only ever narrows relative to the configured intent, never widens.

## Alternatives considered

**Per-session `writablePaths` override (a `sandbox/…` event like the mode switch).** Rejected: the motivating consumers are deployment-shaped (hook and tool state homes fixed by the host, not by a session), and a session-writable widening event would let a confined agent widen its own boundary through the log.

**`--bind` instead of `--bind-try` for bwrap.** Rejected: a missing state directory would fail every confined launch until someone creates it, turning an optional grant into a hard boot dependency; `--bind-try`'s skip-if-missing is the wanted existence semantics.

**Consuming `writablePaths` in `writableRoots` (Seatbelt + fs fence) in the same change.** Deferred, not rejected: it is the coherent next step (it removes the bash/write-tool asymmetry the helper exists to prevent), but it widens the change into the fs seam's allow-list and test surface; until then the per-lifetime warning and README limitations keep the gap visible.

**`danger-full-access` as the workaround.** Rejected as the steady state: it removes every boundary to permit one directory, and its render advertises no confinement at all to the model.

## Consequences

A `workspace-write` deployment can whitelist known external state directories without dropping the sandbox; bwrap and Landlock enforce them, and the model is told about the extra roots exactly when they exist. Seatbelt and Windows deployments configuring `writablePaths` get a logged warning and unchanged (narrower, fail-safe) enforcement until those backends are wired. The in-process `dsh-fs-sandbox` fence also does not consume the roots yet, so file tools still deny what bash permits there — the deferred `writableRoots` step closes both gaps together.
