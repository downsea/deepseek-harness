/** The configured shell executable: argv placement, load-time and live-update verification. */
import { describe, expect, it, onTestFinished, vi } from 'vitest'
import { Context } from '@deepseek-ai/cordis'
import LocalSubprocessRuntime from '@deepseek-ai/dsh-subprocess-local'
import { SubprocessExecutableNotFoundError } from '@deepseek-ai/dsh-subprocess'
import { LocalBashExecutor } from '../src/index.ts'
import { liveConfig } from '../../../settings/settings/tests/live-config.ts'

async function subprocessContext(): Promise<Context> {
  const ctx = new Context()
  onTestFinished(() => ctx.fiber.dispose())
  await ctx.plugin(LocalSubprocessRuntime)
  return ctx
}

describe.skipIf(process.platform === 'win32')('LocalBashExecutor shellPath', () => {
  it('runs commands through bash by default and through a configured POSIX shell as argv[0]', async () => {
    const ctx = await subprocessContext()
    const live = await liveConfig(ctx, LocalBashExecutor)
    const bash = await (await ctx.shell.execute(ctx.shell.resolve({ command: 'echo "$0"' }))).result()
    expect(bash).toMatchObject({ exitCode: 0, stdout: { text: 'bash\n' } })
    await live.update({ shellPath: '/bin/sh' })
    const sh = await (await ctx.shell.execute(ctx.shell.resolve({ command: 'echo "$0"' }))).result()
    expect(sh).toMatchObject({ exitCode: 0, stdout: { text: '/bin/sh\n' } })
  })

  it('fails plugin load when the configured shell does not resolve', async () => {
    const ctx = await subprocessContext()
    const load = ctx.plugin(LocalBashExecutor, { shellPath: '/nonexistent/dsh-shell' })
    await expect(load).rejects.toThrow(SubprocessExecutableNotFoundError)
    await expect(load).rejects.toThrow('bash-local: shellPath "/nonexistent/dsh-shell" does not name an executable')
    await expect(ctx.plugin(LocalBashExecutor, { shellPath: 'dsh-no-such-shell' })).rejects.toThrow(/shellPath "dsh-no-such-shell".*not found on PATH/)
    await expect(ctx.plugin(LocalBashExecutor, { shellPath: '' })).rejects.toThrow('shellPath must be a non-empty')
  })

  it('verifies a changed shellPath during the next command preparation and remembers only successes', async () => {
    const ctx = await subprocessContext()
    const live = await liveConfig(ctx, LocalBashExecutor)
    const lookup = vi.spyOn(ctx.subprocess, 'resolveExecutable')
    await (await ctx.shell.execute(ctx.shell.resolve({ command: 'true' }))).result()
    expect(lookup).not.toHaveBeenCalled()

    await live.update({ shellPath: '/nonexistent/dsh-shell' })
    const missing = ctx.shell.execute(ctx.shell.resolve({ command: 'true' }))
    const error = await missing.then(() => undefined, (reason: unknown) => reason)
    expect(error).toBeInstanceOf(SubprocessExecutableNotFoundError)
    expect((error as Error).cause).toBeInstanceOf(SubprocessExecutableNotFoundError)
    await expect(ctx.shell.execute(ctx.shell.resolve({ command: 'true' }))).rejects.toThrow('shellPath "/nonexistent/dsh-shell"')
    expect(lookup).toHaveBeenCalledTimes(2)

    await live.update({ shellPath: '/bin/sh' })
    await (await ctx.shell.execute(ctx.shell.resolve({ command: 'true' }))).result()
    await (await ctx.shell.execute(ctx.shell.resolve({ command: 'true' }))).result()
    expect(lookup).toHaveBeenCalledTimes(3)

    await live.update({ shellPath: '' })
    expect(() => ctx.shell.resolve({ command: 'true' })).toThrow('bash-local: shellPath must be a non-empty')
  })

  it('passes provider lookup failures and cancellation through unchanged', async () => {
    const ctx = await subprocessContext()
    const live = await liveConfig(ctx, LocalBashExecutor)
    await live.update({ shellPath: 'sh' })
    const failure = new Error('remote lookup failed')
    vi.spyOn(ctx.subprocess, 'resolveExecutable').mockRejectedValueOnce(failure)
    await expect(ctx.shell.execute(ctx.shell.resolve({ command: 'true' }))).rejects.toBe(failure)

    const reason = new Error('caller cancelled')
    await expect(ctx.shell.execute(ctx.shell.resolve({ command: 'true', signal: AbortSignal.abort(reason) }))).rejects.toBe(reason)
  })
})
