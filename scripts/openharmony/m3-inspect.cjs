// M3 reader: print the tool calls/results of the newest session log under $DSH_HOME/sessions.
// Usage: node m3-inspect.cjs <dsh-home>   (prints M3-LOG / M3-TOOL / M3-SUMMARY lines; exit 1 without a tool call or with a failed one)
// The log is a sequence of zstd frames (one per append batch); each frame is decompressed on its own.
// Frame walk follows RFC 8878 (same as session-persistence-jsonl's scanZstdFrames); a torn tail is ignored.
function frames(buf) {
  const out = []
  let o = 0
  while (o + 4 <= buf.length && buf.readUInt32LE(o) === 0xfd2fb528) {
    const start = o, d = buf[o + 4]; o += 5
    const fcs = d >>> 6, single = (d & 0x20) !== 0, dict = [0, 1, 2, 4][d & 3]
    o += (single ? 0 : 1) + dict + (fcs === 0 ? (single ? 1 : 0) : 1 << fcs)
    for (;;) {
      if (o + 3 > buf.length) return out
      const h = buf.readUIntLE(o, 3); o += 3
      o += ((h >>> 1) & 3) === 1 ? 1 : h >>> 3
      if (h & 1) break
    }
    if (d & 4) o += 4
    if (o > buf.length) return out
    out.push(buf.subarray(start, o))
  }
  return out
}
'use strict'
const fs = require('node:fs'), path = require('node:path'), zlib = require('node:zlib')
const home = process.argv[2]
const files = (fs.readdirSync(path.join(home, 'sessions'), { recursive: true }) || [])
  .filter((f) => /session(\.v\d+)?\.jsonl(\.zstd)?$/.test(f)).map((f) => path.join(home, 'sessions', f))
  .sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs)
if (files.length === 0) { console.log('M3-LOG none'); process.exit(1) }
const file = files[0], raw = fs.readFileSync(file)
let text = raw.toString()
if (file.endsWith('.zstd')) text = frames(raw).map((f) => zlib.zstdDecompressSync(f).toString()).join('')
const events = text.split('\n').filter(Boolean).map((l) => JSON.parse(l))
console.log(`M3-LOG ${file} bytes=${raw.length} events=${events.length}`)
let calls = 0, errors = 0
for (const e of events) {
  if (e.type === 'tool/call') calls++
  if (e.type === 'tool/call') console.log(`M3-TOOL call ${e.data.name} ${String(e.data.arguments).slice(0, 120)}`)
  if (e.type === 'tool/result') {
    const m = e.data.message || {}, t = (m.content || []).map((c) => c.text || '').join(' ')
    if (m.isError !== false) errors++
    console.log(`M3-TOOL result isError=${m.isError} ${JSON.stringify(t.slice(0, 160))}`)
  }
}
console.log(`M3-SUMMARY calls=${calls} errors=${errors}`)
process.exitCode = calls > 0 && errors === 0 ? 0 : 1
