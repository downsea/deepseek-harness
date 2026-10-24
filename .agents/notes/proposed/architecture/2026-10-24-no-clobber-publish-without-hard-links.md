# Agent Note: No-clobber publication without hard links

Status: proposed

English | [中文](2026-10-24-no-clobber-publish-without-hard-links.zh.md)

## Problem

Five POSIX publication points rely on `link(2)` to place a complete staged file under a name that must not already exist: the first JSONL session log ([`session-persistence-jsonl/src/index.ts`](../../../../packages/session/session-persistence-jsonl/src/index.ts)), a migrated JSONL generation ([`generation.ts`](../../../../packages/session/session-persistence-jsonl/src/generation.ts)), an attachment object and its display-name alias ([`attachment-local/src/store.ts`](../../../../packages/attachment/attachment-local/src/store.ts)), and guarded file creation by the write tools ([`fs-local/src/fsio.ts`](../../../../packages/fs/fs-local/src/fsio.ts)). A bare `rename(2)` would silently replace a concurrent creator's file, which is why each site uses a hard link and treats `EEXIST` as the collision.

Some filesystems refuse hard links. On the HarmonyOS PC terminal sandbox (MOR-M1, HarmonyOS 7.0.0.111, API 26), `link(2)` fails with `EPERM` in every writable directory, while `open(path, 'wx')` and `copyFile(…, COPYFILE_EXCL)` report `EEXIST` normally, `rename(2)` replaces atomically, and `fsync` / `fdatasync` and directory `fsync` succeed. On that device every new session fails at its first append, every attachment save fails, and the write tool cannot create a file.

A related failure sits in the same attachment path: before its first write, `attachment-local` syncs every ancestor of `DSH_HOME` up to `/`. The same sandbox refuses to open `/storage/Users` (`EPERM`) and `/storage`, `/`, and `/data/storage/el2` (`EACCES`), so the walk fails even when `DSH_HOME` sits under the writable `/data/storage/el2/base`.

## Proposal

Add `publishNoClobber(source, target, options)` to [`dsh-atomic-write`](../../../../packages/util/atomic-write/README.md) and route all five sites through it.

- **Hard link first.** The call attempts `link(2)` (or the caller's injected link primitive). Success and every failure except missing hard-link support keep today's meaning, so Linux, macOS, and Windows filesystems with hard links behave as before.
- **Fallback trigger.** Only `EPERM`, `EACCES`, `ENOTSUP`, `EOPNOTSUPP`, and `ENOSYS` select the fallback. On the HarmonyOS PC the home filesystem (hmdfs) refuses hard links with `EPERM` and the app-data filesystem (hmfs, under `/data/storage/el2/base`) with `EACCES`, while both permit a rename in the same directory. A genuine permission failure behind either code still fails, because every fallback creates or renames in the same directory and meets the same refusal. `EEXIST` stays a collision. `EXDEV` is excluded because every caller stages beside its target, so a cross-device report is a caller defect that a rename would repeat.
- **Required fallback choice.** `fallback` is a required discriminated value. `{ kind: 'writer-lock', lockFile }` renames under `withFileLock(lockFile)` after `lstat` confirms the target is absent, and reports an occupied target with the same `EEXIST` fields a hard link reports. `{ kind: 'exclusive-reservation' }` claims the target with an empty `wx` file and renames the staged file over it.
- **Required source ownership.** `source: 'consume'` lets the fallback rename the staged file itself. `source: 'keep'` copies the source to a synced `COPYFILE_EXCL` sibling of the target and renames that copy, so the source name survives.
- **Explicit result.** The call returns `'hard-link'` or `'rename'`, so a caller knows whether its staged name still exists. A failed call leaves the source in place.

### Per-site choice

| Site | Fallback | Lock file | Why |
|---|---|---|---|
| First session log | `writer-lock` | the log path | Readers parse the log on list and resume; an empty reservation would read as a corrupt session, and a crash would leave it permanently. The backend owns every name in the session directory, and generation names are parsed strictly, so `<log>.lock` cannot collide. |
| JSONL generation | `writer-lock` | the current generation path | Same directory and readers as the first log; the winner inspection after `EEXIST` already validates a competing target. |
| Attachment object | `writer-lock` | the object path | Objects are hex-named. A concurrent deduplicating writer that saw an empty reservation would report `ATTACHMENT_CORRUPT`, and a crash would poison that digest permanently. |
| Attachment alias | `writer-lock`, `source: 'keep'` | the source object path | Alias names come from the caller's display name, so `<alias>.lock` could be another alias whose content reads as an exited holder's PID, which takeover would remove. Locking on the hex-named source object serializes every alias of one object instead. The source object must survive, so the fallback publishes a synced copy. |
| Guarded file creation | `exclusive-reservation` | — | The directory belongs to the user. A lock sibling could collide with a real file such as `yarn.lock` for a target named `yarn`, and the lock excludes only dsh writers while editors and other programs also create files there. The reservation excludes every creator; the cost is that a reader can see an empty file until the rename. |

`COPYFILE_EXCL` alone is not a fallback for any site: it writes into the exclusively created target, so readers can observe partial content and a crash leaves a truncated file.

### Fallback observability

The fallback is not logged. The published bytes, the collision result, and every error are identical on both paths, nothing reaches a model request, and `dsh-atomic-write` is a zero-dependency library without a logger. The `'hard-link' | 'rename'` result lets a caller report the path if a later consumer needs it.

### Durable home boundary

`ensureDurableHome` keeps walking every ancestor of `DSH_HOME` but ends at the first parent it cannot open or sync with `EACCES` or `EPERM`, provided the child entry on the path existed before this call. An entry created by another principal inside a directory this process cannot access is that principal's durability responsibility. An entry this call created there cannot be made durable, so the save still fails. Walks below the proven home keep failing on every error.

## Alternatives considered

**`renameat2(RENAME_NOREPLACE)`.** It gives atomic no-replace rename on Linux 3.15+ and HarmonyOS's kernel, but Node exposes no binding. Calling it through `koffi` would add a native dependency to five storage paths and to a zero-dependency utility, and the device would need another self-signed native artifact.

**One fallback for every site.** `exclusive-reservation` everywhere exposes empty session logs and attachment objects to readers and leaves permanent poison after a crash. `writer-lock` everywhere places a `.lock` sibling in user workspaces, where it can collide with a real file and where non-dsh creators ignore it.

**Per-site hand-written fallbacks.** Five copies of the errno classification and collision reporting would drift; the shared helper keeps one classification and one `EEXIST` report.

**Fail loud on missing hard-link support.** dsh would stay unusable on the HarmonyOS PC, and the device facts show that rename-based publication is atomic there.

**Copying the source for the alias even when hard links work.** It would regress disk use for every display-name alias on filesystems that support hard links.

**Stopping the home walk at the first directory the process did not create.** A concurrent dsh process can create a level and not yet sync it, which is the case the existing walk was written to cover; existence alone does not prove durability.

## Acceptance criteria

- With hard links available, all five sites publish by hard link and existing package tests pass unchanged.
- With `link(2)` failing `EPERM`, a new JSONL session materializes and reads back, a generation migrates, an attachment object and alias are stored and read back, and `createIfAbsent` creates the file; an occupied target still yields the site's collision outcome (`EEXIST`, `ATTACHMENT_CORRUPT`, or `FS_NOT_OBSERVED`).
- A non-support link failure such as `EIO` or `EXDEV` propagates without a fallback; an `EACCES` link failure whose fallback is also refused propagates `EACCES`.
- An attachment save under `DSH_HOME` succeeds when an ancestor above an existing level refuses to open, and fails when the refusing ancestor is the parent of a directory the save created.
- Every changed `src` file keeps per-file 100% coverage.

## Risks

- A crashed `writer-lock` publisher leaves `<lockFile>.lock`. The next publisher takes it over when the recorded PID has exited; a reused PID makes later publishers time out until an operator removes the file, as for every `withFileLock` user.
- `writer-lock` exclusivity covers only dsh publishers naming the same lock file. A program outside dsh creating the same session log or attachment object between the `lstat` and the `rename` would be replaced; those directories are dsh-owned.
- With `exclusive-reservation`, a crash between the reservation and the rename leaves an empty file at the user's target, and a later guarded create reports `FS_NOT_OBSERVED` for it.
- On a filesystem without hard links, every attachment alias is a full copy of its object.
- Treating `EPERM` as missing support could mask a genuine permission refusal of `link(2)`; the fallback's own `lstat`, `open`, or `rename` then reports that refusal.
