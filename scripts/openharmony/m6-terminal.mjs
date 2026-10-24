// M6 terminal probe: spawn real PTY terminals through dsh-subprocess-local (the provider the Web terminal controller
// and dsh-terminal-bash use) and report echo, resize, activity, and close. Run on the device under the self-signed node:
//   <dsh>/node/bin/node <dsh>/tree/oh/m6-terminal.mjs <dsh>/tree <cwd>
// Output: `TERM <shell> <check> ok|fail <detail>` lines, then `TERM-SUMMARY ok=<n> fail=<n>`; exit status = failures.
// Activity is reported, not judged: shell lifecycle observation covers bash and zsh only, so other shells read
// `unknown` while idle, and `busy` needs a live descendant process.
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { setTimeout as sleep } from 'node:timers/promises'

const [tree, cwd] = process.argv.slice(2)
const require = createRequire(join(tree, 'package.json'))
const { Context } = await import(require.resolve('@deepseek-ai/cordis'))
const { default: LocalSubprocessRuntime } = await import(require.resolve('@deepseek-ai/dsh-subprocess-local'))

let ok = 0, fail = 0
const report = (shell, check, pass, detail) => {
  console.log(`TERM ${shell} ${check} ${pass ? 'ok' : 'fail'} ${detail}`)
  if (pass) ok++; else fail++
}
const waitFor = async (read, pattern, ms) => {
  const end = Date.now() + ms
  while (Date.now() < end) { if (pattern.test(read())) return true; await sleep(100) }
  return false
}

const ctx = new Context()
ctx.plugin(LocalSubprocessRuntime)
await ctx.events.flush?.()
const subprocess = await new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error('subprocess service did not start')), 10_000)
  const poll = () => { const s = ctx.get('subprocess'); if (s) { clearTimeout(timer); resolve(s) } else setTimeout(poll, 50) }
  poll()
})

for (const shell of ['/bin/sh', '/usr/bin/zsh']) {
  const name = shell.split('/').pop()
  let out = ''
  let handle
  try {
    handle = await subprocess.spawnTerminal({
      argv: [shell, '-i'], cwd, rows: 24, cols: 80, terminalType: 'xterm-256color', shellActivity: true, graceMs: 1000,
      env: { PS1: '$ ', PROMPT: '$ ' },
    })
  } catch (error) { report(name, 'spawn', false, `${error?.code ?? ''} ${error?.message}`); continue }
  report(name, 'spawn', true, `pid=${handle.pid}`)
  handle.output.setEncoding('utf8').on('data', (d) => { out += d })
  try { await exercise(name, handle, () => out) } catch (error) {
    report(name, 'session', false, `${error?.message} outcome=${JSON.stringify(await Promise.race([handle.done, sleep(500)]))} out=${JSON.stringify(out.slice(-200))}`)
    await handle.terminate().catch(() => {})
  }
}
console.log(`TERM-SUMMARY ok=${ok} fail=${fail}`)
process.exit(fail)

async function exercise(name, handle, read) {
  await sleep(1500)
  const idle = await handle.inspectActivity().catch((e) => ({ state: `error:${e.message}` }))
  console.log(`TERM ${name} activity-idle ${idle.state}`)
  await handle.write('echo TERM_$((6*7))_OK\r')
  report(name, 'echo', await waitFor(read, /TERM_42_OK/, 5000), JSON.stringify(read().slice(-80)))
  await handle.resize(120, 40)
  await handle.write('echo SIZE=$COLUMNS:$LINES\r')
  report(name, 'resize', await waitFor(read, /SIZE=120:40/, 5000), JSON.stringify(read().slice(-60)))
  await handle.write('sleep 5\r')
  await sleep(1000)
  const busy = await handle.inspectActivity().catch((e) => ({ state: `error:${e.message}` }))
  const fg = await handle.inspectForeground().catch((e) => `error:${e.message}`)
  console.log(`TERM ${name} activity-sleep ${busy.state} foreground=${JSON.stringify(fg)}`)
  const closed = handle.terminate().then(() => handle.done)
  const outcome = await Promise.race([closed, sleep(8000).then(() => 'timeout')])
  report(name, 'close', outcome !== 'timeout', JSON.stringify(outcome))
}
