// M1 device smoke: load each OHOS addon placed by pack-tree.sh and exercise it once; run the placed rg once.
// Run on the device under the self-signed node, with TMPDIR under /data/storage/el2/base:
//   NARB_DISABLE_NATIVE_CACHE=1 <dsh>/node/bin/node <dsh>/tree/oh/device-smoke.cjs <dsh>/tree
// Output: one `SMOKE <name> ok|fail <detail> mapped=<file>` line per check, then `SMOKE-SUMMARY ok=<n> fail=<n>`.
// mapped= is read from /proc/self/maps and must point into the tree (a different file means a wrong variant loaded).
// Exit status is the number of failed checks.
'use strict'
const fs = require('node:fs'), path = require('node:path'), os = require('node:os'), { createRequire } = require('node:module')
const tree = path.resolve(process.argv[2] || path.join(__dirname, '..'))
const treeRequire = createRequire(path.join(tree, 'package.json'))
const mapped = (base) => (fs.readFileSync('/proc/self/maps', 'utf8').split('\n').find((l) => l.endsWith('/' + base)) || '').trim().split(/\s+/).pop()
let ok = 0, fail = 0
async function step(name, file, fn) {
  try {
    const d = await fn()
    const m = mapped(file)
    if (!m || !m.startsWith(tree + '/')) throw Object.assign(new Error(`mapped=${m || '<none>'} is not inside ${tree}`), { code: 'WRONG_VARIANT' })
    console.log(`SMOKE ${name} ok ${d} mapped=${m}`); ok++
  } catch (e) { console.log(`SMOKE ${name} fail ${(e && e.code) || ''} ${e && e.message}`); fail++ }
}
;(async () => {
  console.log(`node=${process.version} platform=${process.platform} arch=${process.arch} execPath=${process.execPath} tmpdir=${os.tmpdir()} NARB_DISABLE_NATIVE_CACHE=${process.env.NARB_DISABLE_NATIVE_CACHE || ''}`)
  // Through the package's own loader (node-addon-native-custom-loader), as dsh's resolver loads it.
  await step('require-builtin', 'require_builtin.node', () => {
    const m = treeRequire('node-addon-require-builtin')
    const info = m.getBindingInfo(); const u = m.requireBuiltin('internal/util')
    return `info=${JSON.stringify(info)} internal/util.keys=${Object.keys(u).length}`
  })
  // Direct path: the entry's flock.ts platform gate rejects openharmony until native/system learns the target.
  await step('flock', 'system.node', () => new Promise((resolve, reject) => {
    const m = treeRequire(path.join(tree, 'node_modules/@deepseek-ai/node-addon-system-openharmony-arm64/bin/system.node'))
    const f = path.join(os.tmpdir(), `oh-smoke-flock-${process.pid}`); const fd = fs.openSync(f, 'w')
    m.tryLock(fd, (errno) => { fs.closeSync(fd); fs.rmSync(f, { force: true }); errno === 0 ? resolve('errno=0') : reject(Object.assign(new Error(`errno=${errno}`), { code: 'FLOCK' })) })
  }))
  // Through node-pty's public API (lib/utils.js loadNativeModule finds prebuilds/openharmony-arm64).
  await step('pty', 'pty.node', () => new Promise((resolve, reject) => {
    const pty = treeRequire('node-pty'); let out = ''
    const t = pty.spawn('/bin/sh', ['-c', 'echo pty-ok'], { name: 'xterm', cols: 80, rows: 24, cwd: os.tmpdir(), env: { TERM: 'xterm', PATH: process.env.PATH || '/bin' } })
    const timer = setTimeout(() => reject(new Error(`timeout out=${JSON.stringify(out)}`)), 8000)
    t.onData((d) => { out += d })
    t.onExit(({ exitCode, signal }) => { clearTimeout(timer); out.includes('pty-ok') && exitCode === 0 ? resolve(`exit=${exitCode} sig=${signal} out=${JSON.stringify(out.trim())}`) : reject(new Error(`exit=${exitCode} out=${JSON.stringify(out)}`)) })
  }))
  await step('koffi', 'koffi.node', () => { const k = treeRequire('koffi'); return `version=${k.version}` })
  // ripgrep is an executable, not an addon: resolve it the way tool-fs-search does (@vscode/ripgrep's rgPath),
  // require the path inside the tree, and run it once.
  try {
    const { rgPath } = await import(treeRequire.resolve('@vscode/ripgrep'))
    if (!rgPath.startsWith(tree + '/')) throw Object.assign(new Error(`rgPath=${rgPath} is not inside ${tree}`), { code: 'WRONG_VARIANT' })
    const v = require('node:child_process').execFileSync(rgPath, ['--version'], { encoding: 'utf8' }).split('\n')[0]
    console.log(`SMOKE rg ok ${v} path=${rgPath}`); ok++
  } catch (e) { console.log(`SMOKE rg fail ${(e && e.code) || ''} ${e && e.message}`); fail++ }
  console.log(`SMOKE-SUMMARY ok=${ok} fail=${fail}`)
  process.exitCode = fail
})()
