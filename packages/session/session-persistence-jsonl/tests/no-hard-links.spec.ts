import { Context } from '@deepseek-ai/cordis'
import { mkdtemp, readFile, readdir, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { SessionEvent, SessionHeader } from '@deepseek-ai/dsh-session'
import type { SessionPersistence } from '@deepseek-ai/dsh-session-persistence'
import * as JsonlSessionPersistence from '@deepseek-ai/dsh-session-persistence-jsonl'
import { meta, oneTurnLog } from '../../session-persistence/tests/contract.ts'
import { logPath } from '../src/format.ts'

// Models a filesystem without hard links: the HarmonyOS PC reports EPERM for
// every link(2) in every writable directory.
const linkControl = vi.hoisted(() => ({ failure: undefined as string | undefined }))

vi.mock('node:fs/promises', async (importOriginal) => {
  const actual = await importOriginal<typeof import('node:fs/promises')>()
  return {
    ...actual,
    async link(...args: Parameters<typeof actual.link>): ReturnType<typeof actual.link> {
      const code = linkControl.failure
      if (code !== undefined) throw Object.assign(new Error(`${code}: injected link failure`), { code })
      return actual.link(...args)
    },
  }
})

const roots: string[] = []
let ctx: Context
let root: string

async function writeLog(persistence: SessionPersistence, m: SessionHeader, events: readonly SessionEvent[]): Promise<void> {
  const handle = await persistence.create(m)
  try {
    await handle.append(events)
  } finally {
    await handle.close()
  }
}

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), 'dsh-jsonl-no-links-'))
  roots.push(root)
  ctx = new Context()
  await ctx.plugin(JsonlSessionPersistence, { root, compression: 'none' })
  linkControl.failure = undefined
})

afterEach(async () => {
  await ctx.fiber.dispose()
  await Promise.all(roots.splice(0).map(path => rm(path, { recursive: true, force: true })))
})

describe.skipIf(process.platform === 'win32')('JsonlSessionPersistence on a filesystem without hard links', () => {
  it('materializes the first log by rename and leaves no publication residue', async () => {
    linkControl.failure = 'EPERM'
    const m = meta('no-links', '/work')
    const events = oneTurnLog()

    await writeLog(ctx.sessionPersistence, m, events)

    const path = logPath(root, '/work', m.id, 'none')
    expect((await stat(path)).isFile()).toBe(true)
    // `session.lock` is the write lease; no staging temp or publication lock remains.
    expect((await readdir(dirname(path))).sort()).toEqual([basename(path), 'session.lock'].sort())
    const handle = await ctx.sessionPersistence.open(m.id, 'read')
    try {
      expect((await handle.read()).events).toEqual(events)
    } finally {
      await handle.close()
    }
  })

  it('refuses to materialize an id whose log already exists and keeps that log', async () => {
    linkControl.failure = 'EPERM'
    const m = meta('no-links-existing', '/work')
    await writeLog(ctx.sessionPersistence, m, oneTurnLog())
    const path = logPath(root, '/work', m.id, 'none')
    const before = await readFile(path)

    await expect(writeLog(ctx.sessionPersistence, m, oneTurnLog())).rejects.toThrow()
    expect(await readFile(path)).toEqual(before)
  })

  it('propagates a link failure that does not report missing hard-link support', async () => {
    linkControl.failure = 'EIO'
    const m = meta('no-links-io', '/work')

    await expect(writeLog(ctx.sessionPersistence, m, oneTurnLog())).rejects.toMatchObject({ code: 'EIO' })
    await expect(stat(logPath(root, '/work', m.id, 'none'))).rejects.toMatchObject({ code: 'ENOENT' })
    expect(await readdir(dirname(logPath(root, '/work', m.id, 'none')))).toEqual(['session.lock'])
  })
})
