import { createHash } from 'node:crypto'
import { constants } from 'node:fs'
import { mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { saveFileVerbatim, storedFilePath } from '../src/file-store.ts'
import { publishImmutableObject } from '../src/store.ts'

// Models a filesystem without hard links (the HarmonyOS PC reports EPERM for
// every link(2)) and an app sandbox whose ancestors refuse to be opened.
const fsControl = vi.hoisted(() => ({
  linkFailure: undefined as string | undefined,
  directoryOpenFailures: new Map<string, string>(),
}))

vi.mock('node:fs/promises', async (importOriginal) => {
  const actual = await importOriginal<typeof import('node:fs/promises')>()
  const injected = (code: string, operation: string): Error => code === 'NO_CODE'
    ? new Error(`injected ${operation} failure without a code`)
    : Object.assign(new Error(`${code}: injected ${operation} failure`), { code })
  return {
    ...actual,
    async link(...args: Parameters<typeof actual.link>): ReturnType<typeof actual.link> {
      if (fsControl.linkFailure !== undefined) throw injected(fsControl.linkFailure, 'link')
      return actual.link(...args)
    },
    async open(...args: Parameters<typeof actual.open>): ReturnType<typeof actual.open> {
      const failure = args[1] === constants.O_RDONLY ? fsControl.directoryOpenFailures.get(String(args[0])) : undefined
      if (failure !== undefined) throw injected(failure, 'directory open')
      return actual.open(...args)
    },
  }
})

const bases: string[] = []

/** A fresh `<base>/outer/home/attachments/v1` root whose `outer` already exists. */
async function sandboxedRoot(): Promise<{ readonly base: string; readonly outer: string; readonly root: string }> {
  const base = resolve(await mkdtemp(join(tmpdir(), 'dsh-attachment-sandbox-')))
  bases.push(base)
  const outer = join(base, 'outer')
  await mkdir(outer)
  return { base, outer, root: join(outer, 'home', 'attachments', 'v1') }
}

function digest(data: Uint8Array): string {
  return createHash('sha256').update(data).digest('hex')
}

beforeEach(() => {
  fsControl.linkFailure = undefined
  fsControl.directoryOpenFailures.clear()
})

afterEach(async () => {
  await Promise.all(bases.splice(0).map(base => rm(base, { recursive: true, force: true })))
})

describe.skipIf(process.platform === 'win32')('local attachment store on a filesystem without hard links', () => {
  it('publishes the object and its display-name alias by rename', async () => {
    const { root } = await sandboxedRoot()
    fsControl.linkFailure = 'EPERM'
    const data = Uint8Array.of(1, 2, 3)

    const ref = await saveFileVerbatim(root, { data, name: 'report.bin' })

    const sha256 = digest(data)
    const object = join(root, 'file-objects', sha256.slice(0, 2), sha256)
    expect(new Uint8Array(await readFile(storedFilePath(root, ref)))).toEqual(data)
    expect(new Uint8Array(await readFile(object))).toEqual(data)
    expect((await stat(object)).mode & 0o777).toBe(0o400)
    expect((await stat(storedFilePath(root, ref))).mode & 0o777).toBe(0o400)
    expect(await readdir(join(root, 'tmp'))).toEqual([])
    expect(await readdir(join(root, 'file-objects', sha256.slice(0, 2)))).toEqual([sha256])
    expect(await readdir(join(root, 'files', sha256.slice(0, 2), sha256))).toEqual(['report.bin'])
  })

  it('deduplicates equal bytes and keeps a display name whose name looks like a lock', async () => {
    const { root } = await sandboxedRoot()
    fsControl.linkFailure = 'EPERM'
    const data = Uint8Array.from(Buffer.from('123\n'))

    const lockLike = await saveFileVerbatim(root, { data, name: 'notes.lock' })
    const plain = await saveFileVerbatim(root, { data, name: 'notes' })
    const again = await saveFileVerbatim(root, { data, name: 'notes' })

    expect(again).toEqual(plain)
    expect(new Uint8Array(await readFile(storedFilePath(root, lockLike)))).toEqual(data)
    expect(new Uint8Array(await readFile(storedFilePath(root, plain)))).toEqual(data)
  })

  it('rejects an occupied target whose bytes differ', async () => {
    const { root } = await sandboxedRoot()
    fsControl.linkFailure = 'EPERM'
    const data = Uint8Array.of(4, 5, 6)
    const sha256 = digest(data)
    const target = join(root, 'file-objects', sha256.slice(0, 2), sha256)
    await mkdir(join(root, 'file-objects', sha256.slice(0, 2)), { recursive: true })
    await writeFile(target, Uint8Array.of(9))

    await expect(publishImmutableObject(root, target, data, sha256)).rejects.toMatchObject({ code: 'ATTACHMENT_CORRUPT' })
    expect(new Uint8Array(await readFile(target))).toEqual(Uint8Array.of(9))
    expect(await readdir(join(root, 'tmp'))).toEqual([])
  })

  it('wraps a link failure that does not report missing hard-link support', async () => {
    const { root } = await sandboxedRoot()
    fsControl.linkFailure = 'EIO'
    const data = Uint8Array.of(7)
    const sha256 = digest(data)
    const target = join(root, 'file-objects', sha256.slice(0, 2), sha256)

    await expect(publishImmutableObject(root, target, data, sha256)).rejects.toMatchObject({
      code: 'ATTACHMENT_WRITE_FAILED',
      cause: { code: 'EIO' },
    })
    await expect(stat(target)).rejects.toMatchObject({ code: 'ENOENT' })
  })
})

describe.skipIf(process.platform === 'win32')('local attachment store below an inaccessible ancestor', () => {
  it.each(['EACCES', 'EPERM'])('ends the home durability walk at a pre-existing level whose parent reports %s', async (code) => {
    const { base, root } = await sandboxedRoot()
    fsControl.directoryOpenFailures.set(base, code)
    const data = Uint8Array.of(1)

    const ref = await saveFileVerbatim(root, { data })

    expect(new Uint8Array(await readFile(storedFilePath(root, ref)))).toEqual(data)
  })

  it('fails when this call created the level whose parent cannot be opened', async () => {
    const { outer, root } = await sandboxedRoot()
    fsControl.directoryOpenFailures.set(outer, 'EACCES')

    await expect(saveFileVerbatim(root, { data: Uint8Array.of(2) })).rejects.toMatchObject({ code: 'EACCES' })
  })

  it('fails when an ancestor reports a failure other than inaccessibility', async () => {
    const { base, root } = await sandboxedRoot()
    fsControl.directoryOpenFailures.set(base, 'EIO')

    await expect(saveFileVerbatim(root, { data: Uint8Array.of(3) })).rejects.toMatchObject({ code: 'EIO' })
  })

  it('fails when an ancestor failure carries no errno code', async () => {
    const { base, root } = await sandboxedRoot()
    fsControl.directoryOpenFailures.set(base, 'NO_CODE')

    await expect(saveFileVerbatim(root, { data: Uint8Array.of(5) })).rejects.toThrow('without a code')
  })

  it('fails when a directory below the durable home cannot be opened', async () => {
    const { root } = await sandboxedRoot()
    await mkdir(root, { recursive: true })
    fsControl.directoryOpenFailures.set(join(root, '..'), 'EACCES')

    await expect(saveFileVerbatim(root, { data: Uint8Array.of(4) })).rejects.toMatchObject({ code: 'EACCES' })
  })
})
