import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { renameSync } from 'node:fs'
import { mkdtemp, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { publishNoClobber, type NoClobberFallback } from '../src/index.ts'

type FallbackKind = NoClobberFallback['kind']

/** The fallback of one kind, locking on the target name for `writer-lock`. */
function fallbackFor(kind: FallbackKind, target: string): NoClobberFallback {
  return kind === 'writer-lock' ? { kind, lockFile: target } : { kind }
}

const state = vi.hoisted(() => ({
  copyFailure: undefined as string | undefined,
  lstatFailures: [] as Array<{ readonly path: string; readonly code: string }>,
  renameFailure: undefined as string | undefined,
  beforeRename: undefined as ((target: string) => Promise<void>) | undefined,
  renameAttempts: 0,
}))

vi.mock('node:fs/promises', async (importOriginal) => {
  const actual = await importOriginal<typeof import('node:fs/promises')>()
  const injected = (code: string, operation: string): Error =>
    Object.assign(new Error(`${code}: injected ${operation} failure`), { code })
  return {
    ...actual,
    copyFile: (async (...args: Parameters<typeof actual.copyFile>) => {
      if (state.copyFailure !== undefined) throw injected(state.copyFailure, 'copyFile')
      return actual.copyFile(...args)
    }),
    lstat: (async (...args: Parameters<typeof actual.lstat>) => {
      const index = state.lstatFailures.findIndex(failure => failure.path === String(args[0]))
      if (index !== -1) {
        const [failure] = state.lstatFailures.splice(index, 1)
        throw injected(failure?.code ?? 'EIO', 'lstat')
      }
      return actual.lstat(...args)
    }) as typeof actual.lstat,
    rename: (async (...args: Parameters<typeof actual.rename>) => {
      state.renameAttempts += 1
      await state.beforeRename?.(String(args[1]))
      if (state.renameFailure !== undefined) throw injected(state.renameFailure, 'rename')
      return actual.rename(...args)
    }),
  }
})

const roots: string[] = []

async function tempRoot(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), 'dsh-no-clobber-'))
  roots.push(root)
  return root
}

/** A hard-link primitive that reports the given errno, as a filesystem without hard links does. */
function refusingLink(code: string): (existingPath: string, newPath: string) => Promise<void> {
  return async () => {
    throw Object.assign(new Error(`${code}: injected link failure`), { code })
  }
}

async function exists(path: string): Promise<boolean> {
  try {
    await stat(path)
    return true
  } catch (error) {
    // Only absence answers the question; other failures fail the test.
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return false
    throw error
  }
}

async function staged(root: string, content = 'staged'): Promise<{ readonly source: string; readonly target: string }> {
  const source = join(root, 'stage.tmp')
  await writeFile(source, content, { mode: 0o600 })
  return { source, target: join(root, 'target') }
}

beforeEach(() => {
  state.copyFailure = undefined
  state.lstatFailures = []
  state.renameFailure = undefined
  state.beforeRename = undefined
  state.renameAttempts = 0
})

afterEach(async () => {
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })))
})

describe('publishNoClobber with hard links', () => {
  it('publishes by hard link and keeps the source name', async () => {
    const root = await tempRoot()
    const { source, target } = await staged(root)

    await expect(publishNoClobber(source, target, { fallback: { kind: 'writer-lock', lockFile: target }, source: 'consume' })).resolves.toBe('hard-link')
    expect(await readFile(target, 'utf8')).toBe('staged')
    expect(await exists(source)).toBe(true)
    expect(state.renameAttempts).toBe(0)
  })

  it('rejects an occupied target with EEXIST and leaves both files untouched', async () => {
    const root = await tempRoot()
    const { source, target } = await staged(root)
    await writeFile(target, 'existing')

    await expect(publishNoClobber(source, target, { fallback: { kind: 'writer-lock', lockFile: target }, source: 'consume' }))
      .rejects.toMatchObject({ code: 'EEXIST' })
    expect(await readFile(target, 'utf8')).toBe('existing')
    expect(await readFile(source, 'utf8')).toBe('staged')
  })

  it.each(['EXDEV', 'EIO'])('propagates a %s link failure without falling back', async (code) => {
    const root = await tempRoot()
    const { source, target } = await staged(root)

    await expect(publishNoClobber(source, target, { fallback: { kind: 'writer-lock', lockFile: target }, source: 'consume', link: refusingLink(code) }))
      .rejects.toMatchObject({ code })
    expect(await exists(target)).toBe(false)
    expect(await exists(source)).toBe(true)
    expect(state.renameAttempts).toBe(0)
  })

  it('propagates a link failure that carries no errno code', async () => {
    const root = await tempRoot()
    const { source, target } = await staged(root)
    const failure = new Error('link failed without a code')

    await expect(publishNoClobber(source, target, {
      fallback: { kind: 'writer-lock', lockFile: target },
      source: 'consume',
      link: async () => { throw failure },
    })).rejects.toBe(failure)
    expect(state.renameAttempts).toBe(0)
  })
})

describe.each<FallbackKind>(['writer-lock', 'exclusive-reservation'])('publishNoClobber %s fallback', (kind) => {
  it.each(['EPERM', 'EACCES', 'ENOTSUP', 'EOPNOTSUPP', 'ENOSYS'])('publishes by rename after a %s link failure', async (code) => {
    const root = await tempRoot()
    const { source, target } = await staged(root)

    await expect(publishNoClobber(source, target, { fallback: fallbackFor(kind, target), source: 'consume', link: refusingLink(code) }))
      .resolves.toBe('rename')
    expect(await readFile(target, 'utf8')).toBe('staged')
    expect(await exists(source)).toBe(false)
    expect(await readdir(root)).toEqual(['target'])
  })

  it('rejects a genuine permission failure after an EACCES link failure and keeps the source', async () => {
    const root = await tempRoot()
    const { source, target } = await staged(root)
    state.renameFailure = 'EACCES'

    await expect(publishNoClobber(source, target, { fallback: fallbackFor(kind, target), source: 'consume', link: refusingLink('EACCES') }))
      .rejects.toMatchObject({ code: 'EACCES' })
    expect(await readFile(source, 'utf8')).toBe('staged')
    expect(await exists(target)).toBe(false)
  })

  it('rejects an occupied target with EEXIST and leaves both files untouched', async () => {
    const root = await tempRoot()
    const { source, target } = await staged(root)
    await writeFile(target, 'existing')

    await expect(publishNoClobber(source, target, { fallback: fallbackFor(kind, target), source: 'consume', link: refusingLink('EPERM') }))
      .rejects.toMatchObject({ code: 'EEXIST' })
    expect(await readFile(target, 'utf8')).toBe('existing')
    expect(await readFile(source, 'utf8')).toBe('staged')
    expect((await readdir(root)).sort()).toEqual(['stage.tmp', 'target'])
  })

  it('lets exactly one of two concurrent publishers create the target', async () => {
    const root = await tempRoot()
    const first = join(root, 'first.tmp')
    const second = join(root, 'second.tmp')
    const target = join(root, 'target')
    await writeFile(first, 'first')
    await writeFile(second, 'second')

    const results = await Promise.allSettled([
      publishNoClobber(first, target, { fallback: fallbackFor(kind, target), source: 'consume', link: refusingLink('EPERM') }),
      publishNoClobber(second, target, { fallback: fallbackFor(kind, target), source: 'consume', link: refusingLink('EPERM') }),
    ])

    expect(results.filter(result => result.status === 'fulfilled')).toHaveLength(1)
    expect(results.find(result => result.status === 'rejected')).toMatchObject({ reason: { code: 'EEXIST' } })
    expect(['first', 'second']).toContain(await readFile(target, 'utf8'))
  })

  it('keeps the source name and removes its copy when asked to keep the source', async () => {
    const root = await tempRoot()
    const { source, target } = await staged(root)

    await expect(publishNoClobber(source, target, { fallback: fallbackFor(kind, target), source: 'keep', link: refusingLink('EPERM') }))
      .resolves.toBe('rename')
    expect(await readFile(target, 'utf8')).toBe('staged')
    expect(await readFile(source, 'utf8')).toBe('staged')
    expect((await readdir(root)).sort()).toEqual(['stage.tmp', 'target'])
  })

  it('removes the source copy when a kept-source publication finds the target occupied', async () => {
    const root = await tempRoot()
    const { source, target } = await staged(root)
    await writeFile(target, 'existing')

    await expect(publishNoClobber(source, target, { fallback: fallbackFor(kind, target), source: 'keep', link: refusingLink('EPERM') }))
      .rejects.toMatchObject({ code: 'EEXIST' })
    expect(await readFile(target, 'utf8')).toBe('existing')
    expect((await readdir(root)).sort()).toEqual(['stage.tmp', 'target'])
  })

  it('propagates a rename failure and leaves the source in place', async () => {
    const root = await tempRoot()
    const { source, target } = await staged(root)
    state.renameFailure = 'EIO'

    await expect(publishNoClobber(source, target, { fallback: fallbackFor(kind, target), source: 'consume', link: refusingLink('EPERM') }))
      .rejects.toMatchObject({ code: 'EIO' })
    expect(await readFile(source, 'utf8')).toBe('staged')
    expect(await readdir(root)).toEqual(['stage.tmp'])
  })
})

describe('publishNoClobber source copies', () => {
  it('propagates a copy failure without leaving a partial copy', async () => {
    const root = await tempRoot()
    const { source, target } = await staged(root)
    state.copyFailure = 'ENOSPC'

    await expect(publishNoClobber(source, target, { fallback: { kind: 'writer-lock', lockFile: target }, source: 'keep', link: refusingLink('EPERM') }))
      .rejects.toMatchObject({ code: 'ENOSPC' })
    expect(await readdir(root)).toEqual(['stage.tmp'])
  })
})

describe('publishNoClobber writer-lock fallback', () => {
  it('propagates a target inspection failure other than absence', async () => {
    const root = await tempRoot()
    const { source, target } = await staged(root)
    state.lstatFailures.push({ path: target, code: 'EACCES' })

    await expect(publishNoClobber(source, target, { fallback: { kind: 'writer-lock', lockFile: target }, source: 'consume', link: refusingLink('EPERM') }))
      .rejects.toMatchObject({ code: 'EACCES' })
    expect(await readdir(root)).toEqual(['stage.tmp'])
  })

  it('reports an occupied target as a link collision naming both paths', async () => {
    const root = await tempRoot()
    const { source, target } = await staged(root)
    await writeFile(target, 'existing')

    await expect(publishNoClobber(source, target, { fallback: { kind: 'writer-lock', lockFile: target }, source: 'consume', link: refusingLink('EPERM') }))
      .rejects.toMatchObject({ code: 'EEXIST', syscall: 'link', path: source, dest: target })
  })

  it('locks the caller-named file instead of the target', async () => {
    const root = await tempRoot()
    const { source, target } = await staged(root)
    const lockFile = join(root, 'owned-key')
    await writeFile(`${target}.lock`, 'an unrelated file\n')

    await expect(publishNoClobber(source, target, {
      fallback: { kind: 'writer-lock', lockFile },
      source: 'consume',
      link: refusingLink('EPERM'),
    })).resolves.toBe('rename')
    expect(await readFile(`${target}.lock`, 'utf8')).toBe('an unrelated file\n')
    expect((await readdir(root)).sort()).toEqual(['target', 'target.lock'])
  })

  it('takes over the lock a crashed publisher left behind', async () => {
    const root = await tempRoot()
    const { source, target } = await staged(root)
    const child = spawn(process.execPath, ['-e', ''], { stdio: 'ignore' })
    await once(child, 'exit')
    await writeFile(`${target}.lock`, `${child.pid}\n`)

    await expect(publishNoClobber(source, target, { fallback: { kind: 'writer-lock', lockFile: target }, source: 'consume', link: refusingLink('EPERM') }))
      .resolves.toBe('rename')
    expect(await readdir(root)).toEqual(['target'])
  })
})

describe('publishNoClobber exclusive-reservation fallback', () => {
  it('replaces the empty reservation in one rename', async () => {
    const root = await tempRoot()
    const { source, target } = await staged(root)
    const observed: string[] = []
    state.beforeRename = async (path) => { observed.push(await readFile(path, 'utf8')) }

    await publishNoClobber(source, target, { fallback: { kind: 'exclusive-reservation' }, source: 'consume', link: refusingLink('EPERM') })
    expect(observed).toEqual([''])
    expect(await readFile(target, 'utf8')).toBe('staged')
  })

  it('keeps a target another writer put in place of the reservation when the rename fails', async () => {
    const root = await tempRoot()
    const { source, target } = await staged(root)
    state.renameFailure = 'EIO'
    // Allocate the competitor inode before the reservation is replaced: a filesystem
    // that reuses a freed inode would otherwise make the replacement indistinguishable.
    state.beforeRename = async (path) => {
      const competitor = join(root, 'competitor')
      await writeFile(competitor, 'other writer')
      renameSync(competitor, path)
    }

    await expect(publishNoClobber(source, target, { fallback: { kind: 'exclusive-reservation' }, source: 'consume', link: refusingLink('EPERM') }))
      .rejects.toMatchObject({ code: 'EIO' })
    expect(await readFile(target, 'utf8')).toBe('other writer')
    expect(await readFile(source, 'utf8')).toBe('staged')
  })

  it('accepts a reservation that vanished before the failed rename is cleaned up', async () => {
    const root = await tempRoot()
    const { source, target } = await staged(root)
    state.renameFailure = 'EIO'
    state.beforeRename = async (path) => { await rm(path) }

    await expect(publishNoClobber(source, target, { fallback: { kind: 'exclusive-reservation' }, source: 'consume', link: refusingLink('EPERM') }))
      .rejects.toMatchObject({ code: 'EIO' })
    expect(await readdir(root)).toEqual(['stage.tmp'])
  })

  it('reports both failures when the reservation cannot be inspected after a failed rename', async () => {
    const root = await tempRoot()
    const { source, target } = await staged(root)
    state.renameFailure = 'EIO'
    state.lstatFailures.push({ path: target, code: 'EACCES' })

    const failure = await publishNoClobber(source, target, {
      fallback: { kind: 'exclusive-reservation' },
      source: 'consume',
      link: refusingLink('EPERM'),
    }).then(() => undefined, (error: unknown) => error)

    if (!(failure instanceof AggregateError)) throw new Error('expected an aggregate reservation failure')
    expect(failure.errors).toMatchObject([{ code: 'EIO' }, { code: 'EACCES' }])
    expect(await readFile(source, 'utf8')).toBe('staged')
  })
})
