/**
 * Zero-dependency atomic file replacement and writer coordination.
 * `writeFileAtomic` writes a random-suffix sibling with exclusive create and
 * the caller's permission bits, then renames it over the target, so readers
 * observe either the old or the new complete content and a replaced file ends
 * up with exactly the stated mode. `withFileLock` serializes cross-process
 * writers of one file through a `wx`-created `<file>.lock` sibling, so a
 * read-modify-write cycle can never resurrect a state another writer just
 * replaced; readers stay lock-free because the rename commit is atomic. A lock
 * whose recorded holder process no longer exists is taken over.
 * `publishNoClobber` publishes a complete staged file under a name that must
 * not already exist: a hard link where the filesystem supports one, otherwise
 * a rename guarded by the caller-selected reservation.
 * @module @deepseek-ai/dsh-atomic-write
 */

import { createHash, randomBytes } from 'node:crypto'
import { constants as fsConstants } from 'node:fs'
import { copyFile, link, lstat, mkdir, open, readFile, rename, rm, writeFile } from 'node:fs/promises'
import { constants as osConstants } from 'node:os'
import { dirname } from 'node:path'
import { setTimeout as wait } from 'node:timers/promises'

const WINDOWS_TRANSIENT_RENAME_ERRORS: ReadonlySet<string> = new Set(['EACCES', 'EBUSY', 'EPERM'])
const WINDOWS_RENAME_RETRY_INITIAL_MS = 20
const WINDOWS_RENAME_RETRY_MAX_MS = 200
const WINDOWS_RENAME_RETRY_LIMIT = 8

/** Whether Windows reported temporary interference with an atomic replacement. */
function isTransientWindowsRenameError(error: unknown): boolean {
  if (process.platform !== 'win32') return false
  return WINDOWS_TRANSIENT_RENAME_ERRORS.has((error as NodeJS.ErrnoException | null)?.code ?? '')
}

/** Replace the target after bounded retries for transient Windows interference. */
async function renameAtomicTemp(temp: string, filename: string): Promise<void> {
  let delay = WINDOWS_RENAME_RETRY_INITIAL_MS
  for (let retries = 0;; retries += 1) {
    try {
      await rename(temp, filename)
      return
    } catch (error) {
      if (!isTransientWindowsRenameError(error)) throw error
      if (retries >= WINDOWS_RENAME_RETRY_LIMIT) throw error
    }
    await new Promise(resolve => setTimeout(resolve, delay))
    delay = Math.min(delay * 2, WINDOWS_RENAME_RETRY_MAX_MS)
  }
}

/**
 * Filesystem options for {@link writeFileAtomic}; `mode` is required so the
 * permission decision stays visible at every call site.
 */
export interface WriteFileAtomicOptions {
  /**
   * Permission bits stamped on the fresh temp inode and carried through the
   * rename (subject to the process umask, like every fresh inode).
   */
  mode: number
  /**
   * Permission bits for parent directories this call creates (subject to the
   * umask; existing directories keep their mode). Omission uses the mkdir
   * default — pass `0o700` when the tree holds user-private data.
   */
  dirMode?: number
}

/**
 * Replace `filename` with `content` in one atomic step, creating parent
 * directories. The content is first written to a random-suffix sibling opened
 * with exclusive create (`wx`): the open refuses to follow a symlink planted
 * at the temp path, and the fresh inode carries `options.mode` through the
 * rename, so replacing a wider-permission file narrows it without a chmod
 * race. The rename also replaces a symlinked target itself instead of writing
 * through to its referent, and the same-directory sibling keeps the rename on
 * one filesystem. Windows replacement retries transient `EACCES`, `EBUSY`,
 * and `EPERM` failures for a bounded interval while the complete temp file
 * remains the rename source. On any remaining failure the temp file is
 * removed and the failure rethrown. Crash durability (fsync) is out of scope.
 * @param filename - final path receiving the content.
 * @param content - complete next file content.
 * @param options - permission bits for the replacement inode.
 */
export async function writeFileAtomic(filename: string, content: string | Uint8Array, options: WriteFileAtomicOptions): Promise<void> {
  await mkdir(dirname(filename), {
    recursive: true,
    ...options.dirMode === undefined ? {} : { mode: options.dirMode },
  })
  // TODO(settings-atomic-durability): Use a replacement that fsyncs the file
  // and parent directory and preserves owner-only permissions on Windows.
  const temp = `${filename}.${randomBytes(6).toString('hex')}.tmp`
  try {
    await writeFile(temp, content, { mode: options.mode, flag: 'wx' })
    await renameAtomicTemp(temp, filename)
  } catch (error) {
    await rm(temp, { force: true })
    throw error
  }
}

/** Whether an exclusive create found an existing lock. */
async function isLockContention(error: unknown, lockPath: string): Promise<boolean> {
  const code = (error as NodeJS.ErrnoException | null)?.code
  if (code === 'EEXIST') return true
  if (code !== 'EPERM') return false
  try {
    await lstat(lockPath)
    return true
  } catch {
    // Keep the original EPERM authoritative when lock existence is unproven.
    return false
  }
}

/** Whether the holder a `<pid>\n` record names is proven gone: a signal probe finds no such process. */
function holderExited(record: string): boolean {
  // Any other content is being written or was cut short, which proves nothing about its holder.
  if (!/^\d+\n$/.test(record)) return false
  const pid = Number(record.trim())
  // PID 0 addresses the caller's process group, and the probe accepts only positive int32 PIDs.
  if (pid === 0 || pid > 0x7fffffff) return false
  // This process is running; a runtime whose probe cannot see itself must not take over its own lock.
  if (pid === process.pid) return false
  try {
    process.kill(pid, 0)
    return false
  } catch (error) {
    // EPERM means the process exists under another user.
    return (error as NodeJS.ErrnoException).code === 'ESRCH'
  }
}

/** The lock file's content, or undefined when it cannot be read. */
async function readLockRecord(lockPath: string): Promise<string | undefined> {
  try {
    return await readFile(lockPath, 'utf8')
  } catch (error) {
    // A lock that vanished, or that Windows is still deleting, proves nothing about a holder.
    void error
    return undefined
  }
}

/**
 * Remove the lock when its recorded holder exited. Contenders that read the
 * same record serialize on a claim file named after it. Under the claim, the
 * claimant re-reads the lock and probes its PID again, and removes it only
 * when it still holds that record and that PID is still gone: the record's
 * holder can no longer release it, and no other contender can remove it
 * without the claim, so a removal never deletes a lock another contender
 * acquired after the dead holder's, including one whose holder reused the PID.
 * @returns Whether this call removed the dead holder's lock.
 */
async function takeOverExitedLock(lockPath: string): Promise<boolean> {
  const record = await readLockRecord(lockPath)
  if (record === undefined || !holderExited(record)) return false
  const claim = `${lockPath}.takeover-${createHash('sha256').update(record).digest('hex').slice(0, 16)}`
  try {
    await writeFile(claim, `${process.pid}\n`, { mode: 0o600, flag: 'wx' })
  } catch (error) {
    // Another contender owns the claim for this record, or Windows still deletes the claim it released.
    const code = (error as NodeJS.ErrnoException).code
    if (code === 'EEXIST' || code === 'EPERM') return false
    throw error
  }
  try {
    if (await readLockRecord(lockPath) !== record || !holderExited(record)) return false
    try {
      await rm(lockPath, { force: true })
    } catch (error) {
      // Windows can refuse the removal while other software briefly holds the file; the next attempt retries.
      void error
      return false
    }
    return true
  } finally {
    await rm(claim, { force: true }).catch((error: unknown) => {
      // A claim left behind names a record that is no longer the lock, so it blocks no later takeover.
      void error
    })
  }
}

/**
 * Retry cadence for a contended lock. These stay robustness invariants of the
 * cross-process write protocol rather than deployment tunables: they govern how
 * often a contender asks, which no caller has a reason to vary.
 */
const LOCK_RETRY_INITIAL_MS = 20
const LOCK_RETRY_MAX_MS = 200

/**
 * How long a contender waits when the caller states no limit — sized for the
 * render-and-rename cycle every call site had when this package was written.
 * Expiry fails the contender rather than guessing whether the existing lock
 * still has an owner. How long is *worth* waiting is a property of the
 * operation the lock holder runs, which is why {@link FileLockOptions.waitMs}
 * exists; the value here is the floor for an operation that does file work
 * alone.
 */
const DEFAULT_LOCK_WAIT_MS = 2_000

/** Options for one {@link withFileLock} acquisition. */
export interface FileLockOptions {
  /** Cancel acquisition and contention waits; the operation owns cancellation after it starts. */
  signal?: AbortSignal
  /**
   * Maximum time to wait for the lock, in milliseconds. State one when the
   * holder's operation legitimately runs longer than file work — a credential
   * mutation that refreshes a token performs a network round trip while
   * holding the lock, and leaving the default in place would fail every other
   * writer of the same file for the duration. Waiting is productive: a
   * contender that acquires the lock afterwards re-reads the committed state.
   */
  waitMs?: number
}

/**
 * Hold the cross-process writer lock for `filename` around one operation. The
 * lock is a `wx`-created sibling (`<filename>.lock`); paired with the
 * rename-based commit of {@link writeFileAtomic}, readers stay lock-free and
 * only writers contend. `EEXIST` is contention directly; an `EPERM` is
 * contention only when a fresh `lstat` confirms the lock path exists, covering
 * Windows exclusive-create behavior. Windows retries one unconfirmed EPERM
 * because the holder can release before the probe; a repeated unconfirmed
 * permission error is rethrown. The lock records its holder's PID. A contender
 * removes the lock and retries at once when no process with that PID exists
 * (`ESRCH`); any other lock, including one whose holder exists under another
 * user (`EPERM`) or whose record is incomplete, is waited for. Contention backs
 * off exponentially and times out after the deadline. A holder whose PID a
 * live process reused keeps its lock until an operator removes it. Takeover
 * proves only that the recorded process exited: an operation that starts other
 * writers must stop them with it or leave its successor a way to find them.
 * PIDs are compared on the contender's host, so writers on other hosts or in
 * other PID namespaces sharing the file are unsupported and could both hold
 * the lock. The parent directory must exist.
 * @param filename - the file whose writers this lock serializes.
 * @param operation - the read-render-commit cycle to run while holding the lock.
 * @param options - acquisition options; omitted waits {@link DEFAULT_LOCK_WAIT_MS}.
 * @returns the operation's result; the lock releases on both outcomes.
 */
export async function withFileLock<T>(
  filename: string,
  operation: () => Promise<T>,
  options?: FileLockOptions,
): Promise<T> {
  const lockPath = `${filename}.lock`
  const deadline = Date.now() + (options?.waitMs ?? DEFAULT_LOCK_WAIT_MS)
  let delay = LOCK_RETRY_INITIAL_MS
  let retriedUnconfirmedPermissionError = false
  for (;;) {
    options?.signal?.throwIfAborted()
    try {
      await writeFile(lockPath, `${process.pid}\n`, { mode: 0o600, flag: 'wx' })
      break
    } catch (error) {
      if (!await isLockContention(error, lockPath)) {
        // Windows can release the competing lock between exclusive create and lstat.
        if (process.platform !== 'win32'
          || (error as NodeJS.ErrnoException | null)?.code !== 'EPERM'
          || retriedUnconfirmedPermissionError) throw error
        retriedUnconfirmedPermissionError = true
      } else if (await takeOverExitedLock(lockPath)) continue
    }
    if (Date.now() >= deadline) {
      throw new Error(`atomic-write: timed out waiting for the writer lock at ${lockPath}`)
    }
    await wait(delay, undefined, { signal: options?.signal })
    delay = Math.min(delay * 2, LOCK_RETRY_MAX_MS)
  }
  try {
    options?.signal?.throwIfAborted()
    return await operation()
  } finally {
    await rm(lockPath, { force: true })
  }
}

/**
 * `link(2)` error codes that can report a filesystem without hard-link
 * support rather than a collision. `EPERM` is what Linux and the HarmonyOS PC
 * home filesystem (hmdfs) report for a filesystem that refuses hard links;
 * `EACCES` is what the HarmonyOS PC app-data filesystem (hmfs, under
 * `/data/storage/el2/base`) reports for the same refusal while it still
 * permits a rename in that directory; `ENOTSUP` / `EOPNOTSUPP` and `ENOSYS`
 * are the other codes a filesystem or kernel uses for an unimplemented
 * operation. A genuine permission failure behind `EPERM` or `EACCES` still
 * fails: every fallback creates or renames in the same directory and reports
 * the same refusal. `EXDEV` is excluded: every caller stages next to the
 * target, so a cross-device report is a caller defect that a rename would
 * repeat.
 */
const HARD_LINK_UNSUPPORTED_ERRORS: ReadonlySet<string> = new Set(['EPERM', 'EACCES', 'ENOTSUP', 'EOPNOTSUPP', 'ENOSYS'])

/** Whether a `link(2)` failure reports missing hard-link support. */
function isHardLinkUnsupported(error: unknown): boolean {
  return HARD_LINK_UNSUPPORTED_ERRORS.has((error as NodeJS.ErrnoException | null)?.code ?? '')
}

/**
 * How {@link publishNoClobber} keeps the target name exclusive when the
 * filesystem refuses hard links.
 *
 * - `writer-lock` holds {@link withFileLock} on `lockFile`, confirms the
 *   target is absent, and renames the staged file onto it. Readers observe
 *   either no file or the complete content. Exclusivity holds among
 *   publishers of the target that name the same `lockFile`; a crash leaves
 *   only the `<lockFile>.lock` sibling, which the next publisher takes over
 *   once its recorded process has exited. `lockFile` must be a name whose
 *   `.lock` sibling the caller owns: an unrelated file at that name would be
 *   waited for, or removed when its content reads as an exited holder's PID.
 * - `exclusive-reservation` claims the target name with an empty
 *   exclusive-create (`wx`) file and renames the staged file over it.
 *   Exclusivity holds against every creator, including programs that do not
 *   use this function, but a reader can observe the empty reservation until
 *   the rename, and a crash in that window leaves the empty file in place.
 *   It suits a directory whose names the caller does not own.
 */
export type NoClobberFallback =
  | { readonly kind: 'writer-lock'; readonly lockFile: string }
  | { readonly kind: 'exclusive-reservation' }

/** Options for one {@link publishNoClobber} call; both choices are required so each caller states them. */
export interface PublishNoClobberOptions {
  /** Exclusivity mechanism used when the filesystem refuses hard links. */
  fallback: NoClobberFallback
  /**
   * Whether the source name must survive publication. `'consume'` lets the
   * fallback rename the source itself; `'keep'` makes the fallback copy the
   * source to a synced sibling of the target and rename that copy.
   */
  source: 'consume' | 'keep'
  /** Hard-link primitive; defaults to `node:fs/promises` `link`. */
  link?: (existingPath: string, newPath: string) => Promise<void>
}

/**
 * How {@link publishNoClobber} published the target: `'hard-link'` leaves
 * the source name in place; `'rename'` consumed the source when the options
 * said `'consume'`.
 */
export type NoClobberPublication = 'hard-link' | 'rename'

/** The `EEXIST` failure a hard link reports for an occupied target. */
function targetExistsError(source: string, target: string): NodeJS.ErrnoException {
  return Object.assign(new Error(`EEXIST: file already exists, link '${source}' -> '${target}'`), {
    code: 'EEXIST',
    errno: -osConstants.errno.EEXIST,
    syscall: 'link',
    path: source,
    dest: target,
  })
}

/** Rename `source` onto `target` while holding the writer lock of `lockFile`, failing with `EEXIST` when the target exists. */
async function renameUnderWriterLock(source: string, target: string, lockFile: string, reported: string): Promise<void> {
  await withFileLock(lockFile, async () => {
    try {
      await lstat(target)
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
      await rename(source, target)
      return
    }
    throw targetExistsError(reported, target)
  })
}

/** Claim `target` with an empty exclusive-create file, then rename `source` over the claim. */
async function renameOverReservation(source: string, target: string): Promise<void> {
  const reservation = await open(target, 'wx', 0o600)
  let reserved
  try {
    reserved = await reservation.stat({ bigint: true })
  } finally {
    await reservation.close()
  }
  try {
    await rename(source, target)
  } catch (error) {
    // Remove the reservation only while the target is still this call's empty inode.
    try {
      const current = await lstat(target, { bigint: true })
      if (current.ino === reserved.ino && current.dev === reserved.dev) await rm(target, { force: true })
    } catch (cleanupError) {
      if ((cleanupError as NodeJS.ErrnoException).code !== 'ENOENT') {
        throw new AggregateError([error, cleanupError], `atomic-write: failed to release the reservation at ${target}`)
      }
    }
    throw error
  }
}

/** Copy `source` to a synced exclusive sibling of `target` so a rename can publish it without moving `source`. */
async function stageCopy(source: string, target: string): Promise<string> {
  const copy = `${target}.${randomBytes(6).toString('hex')}.tmp`
  try {
    await copyFile(source, copy, fsConstants.COPYFILE_EXCL)
    const handle = await open(copy, 'r')
    try {
      await handle.sync()
    } finally {
      await handle.close()
    }
  } catch (error) {
    await rm(copy, { force: true })
    throw error
  }
  return copy
}

/**
 * Publish the complete file at `source` under `target` without replacing an
 * existing `target`. A hard link is attempted first, so filesystems that
 * support one behave exactly as a bare `link(2)`. Only when the link fails
 * with a code that can report missing hard-link support (`EPERM`, `EACCES`,
 * `ENOTSUP`, `EOPNOTSUPP`, `ENOSYS`) does the selected
 * {@link NoClobberFallback} publish by rename. An occupied target fails with `EEXIST` on every path, any other
 * link failure propagates unchanged, and a failed call leaves `source` in
 * place. `source` must be complete and synced before the call, and sit on
 * the same filesystem as `target`; the caller syncs the parent directory
 * afterwards.
 * @param source - complete staged file the caller owns.
 * @param target - final name that must not exist yet.
 * @param options - fallback mechanism and source ownership.
 * @returns whether the target was published by hard link or by rename.
 */
export async function publishNoClobber(
  source: string,
  target: string,
  options: PublishNoClobberOptions,
): Promise<NoClobberPublication> {
  try {
    await (options.link ?? link)(source, target)
    return 'hard-link'
  } catch (error) {
    if (!isHardLinkUnsupported(error)) throw error
  }
  const staged = options.source === 'keep' ? await stageCopy(source, target) : source
  try {
    const fallback = options.fallback
    switch (fallback.kind) {
      case 'writer-lock':
        await renameUnderWriterLock(staged, target, fallback.lockFile, source)
        break
      case 'exclusive-reservation':
        await renameOverReservation(staged, target)
        break
      /* v8 ignore next 4 -- closed-union exhaustiveness guard */
      default: {
        const unhandled: never = fallback
        throw new Error(`atomic-write: unhandled no-clobber fallback ${JSON.stringify(unhandled)}`)
      }
    }
  } catch (error) {
    if (options.source === 'keep') await rm(staged, { force: true })
    throw error
  }
  return 'rename'
}
