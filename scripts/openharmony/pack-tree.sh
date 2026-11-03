#!/usr/bin/env bash
# Build and pack a dsh checkout, install the tarballs into a flat npm tree for openharmony-arm64, place the
# self-signed OHOS addons, and sweep the tree's ELF files.
#
# Usage: pack-tree.sh [--no-build] <dsh-checkout> <natives-dir> <out>
#   <natives-dir>  output of build-natives.sh (uses <natives-dir>/signed/*.node and signed/rg)
#   <out>/pack/{npm,npm-vendor,npm-landlock}/*.tgz   release:pack output (same steps as .github/workflows/release.yml)
#   <out>/pack/npm-ohos/*.tgz                        the flock platform package for openharmony-arm64 (signed system.node)
#   <out>/tree/                                      the device tree (package.json + flat node_modules, no symlinks)
#   <out>/tree/oh/                                   SHA256SUMS of placed addons, ELF sweep report, device-smoke.cjs,
#                                                    openharmony.patch.yml (device overlay the launcher applies),
#                                                    m3-replay.patch.yml + m3-inspect.cjs + m3/<scenario>/ (keyless M3),
#                                                    m6-replay.patch.yml + m6-terminal.mjs + m6/<scenario>/ (keyless M6)
#   --no-build  reuse the checkout's existing build:artifacts output (release:pack still checks its record)
#
# The install mirrors scripts/release/verify-packed-install.ts: every tarball comes from file: URLs, platform
# compatibility is judged against openharmony/arm64 instead of the build host, and optional dependencies are
# omitted. --ignore-scripts keeps koffi's cnoke / node-pty's node-gyp from running.
. "$(dirname "$0")/lib.sh"
BUILD=1
[ "${1:-}" = --no-build ] && { BUILD=0; shift; }
[ $# -eq 3 ] || die "usage: pack-tree.sh [--no-build] <dsh-checkout> <natives-dir> <out>"
DSH=$(cd "$1" && pwd); NAT=$(cd "$2/signed" && pwd); mkdir -p "$3"; OUT=$(cd "$3" && pwd)
for f in require_builtin.node system.node pty.node koffi.node rg; do [ -f "$NAT/$f" ] || die "missing $NAT/$f (run build-natives.sh)"; done
# sharp has no openharmony prebuild; its loader's last fallback is @img/sharp-wasm32 (no native code, nothing to sign),
# which no install edge pulls in. Install it at the version the checkout's lockfile pins.
SHARP_WASM=$(sed -n "s/^  '@img\/sharp-wasm32@\([^']*\)':\$/\1/p" "$DSH/pnpm-lock.yaml" | sort -u)
[ "$(printf '%s\n' "$SHARP_WASM" | wc -l)" = 1 ] && [ -n "$SHARP_WASM" ] || die "expected one @img/sharp-wasm32 version in pnpm-lock.yaml, got [$SHARP_WASM]"
NSP=$DSH/native/system/packages/openharmony-arm64
[ -f "$NSP/package.json" ] || die "$DSH has no native/system/packages/openharmony-arm64 (the flock platform package)"

# Repo rule: heavy node runs wait for other sessions' vitest / tsc / tsdown / vite / tsx (bounded by OH_WAIT_MAX, lib.sh).
node_busy() { pgrep -xa node | grep -Eq 'vitest|tsc|tsdown|vite|tsx'; }
wait_node() { wait_while "node build/test running elsewhere" node_busy; }
# OH_BUILD_ARGS: extra build:artifacts arguments, e.g. --serial where the checkout's scripts/build.ts has it (two 8 GiB
# typecheck heaps at once can OOM a 9 GB build machine).
read -r -a BUILD_ARGS <<<"${OH_BUILD_ARGS:-}"

PACK=$OUT/pack
if [ $BUILD = 1 ]; then
  wait_slot; wait_node; log "build:artifacts --profile official ${BUILD_ARGS[*]}"
  (cd "$DSH" && "${CAP[@]}" pnpm run build:artifacts --profile official "${BUILD_ARGS[@]}") >"$OUT/build.log" 2>&1 \
    || { tail -40 "$OUT/build.log" >&2; die "build failed (log $OUT/build.log)"; }
fi
wait_node; log "release:pack dsh + vendor + landlock entry"
rm -rf "$PACK"; mkdir -p "$PACK"
(
  cd "$DSH"
  pnpm run release:pack --family dsh --out "$PACK/npm" --concurrency 3
  pnpm run release:pack --family vendor --out "$PACK/npm-vendor" --concurrency 3
  pnpm --dir native/system run build:ts
  mkdir -p "$NSP/bin"
  pnpm --dir native/system/packages/entry pack --pack-destination "$PACK/npm-landlock"
  # The flock platform package carries the self-signed system.node (its prepack checks format and architecture).
  cp "$NAT/system.node" "$NSP/bin/system.node"
  pnpm --dir native/system/packages/openharmony-arm64 pack --pack-destination "$PACK/npm-ohos"
) >"$OUT/pack.log" 2>&1 || { tail -40 "$OUT/pack.log" >&2; die "pack failed (log $OUT/pack.log)"; }

TREE=$OUT/tree
rm -rf "$TREE"; mkdir -p "$TREE/oh"
# Consumer manifest: compatible tarballs are dependencies, foreign-platform ones optional (then omitted).
node - "$TREE/package.json" "$SHARP_WASM" "$PACK/npm" "$PACK/npm-vendor" "$PACK/npm-landlock" <<'EOF'
const { execFileSync } = require('node:child_process'), fs = require('node:fs'), path = require('node:path'), url = require('node:url')
const [out, sharpWasm, ...dirs] = process.argv.slice(2)
const accepts = (v, cur) => { if (v === undefined) return true; let ok = v.every(t => t.startsWith('!'))
  for (const t of v) { if (t === `!${cur}`) return false; if (t === cur || (t === 'any' && v.length === 1)) ok = true } return ok }
const deps = {}, opt = {}
for (const d of dirs) for (const f of fs.readdirSync(d).filter(n => n.endsWith('.tgz')).sort()) {
  const t = path.join(d, f), m = JSON.parse(execFileSync('tar', ['-xOzf', t, 'package/package.json'], { encoding: 'utf8' }))
  ;(accepts(m.os, 'openharmony') && accepts(m.cpu, 'arm64') ? deps : opt)[m.name] = url.pathToFileURL(t).href
}
deps['@img/sharp-wasm32'] = sharpWasm
fs.writeFileSync(out, JSON.stringify({ name: 'dsh-openharmony-tree', version: '0.0.0', private: true, dependencies: deps, optionalDependencies: opt }, null, 2) + '\n')
console.error(`[oh] consumer: ${Object.keys(deps).length} dependencies, ${Object.keys(opt).length} foreign-platform optional`)
EOF
log "npm install (openharmony/arm64, --ignore-scripts --omit=optional)"
(cd "$TREE" && npm install --cache "$OUT/.npm-cache" --no-audit --no-fund --package-lock=false \
  --omit=optional --ignore-scripts --os=openharmony --cpu=arm64 --loglevel=warn) >"$OUT/npm-install.log" 2>&1 \
  || { tail -40 "$OUT/npm-install.log" >&2; die "npm install failed (log $OUT/npm-install.log)"; }
links=$(find "$TREE/node_modules" -type l | wc -l)
log "tree installed: $(find "$TREE/node_modules" -name package.json -path '*/node_modules/*/package.json' -not -path '*/node_modules/*/node_modules/*/*/package.json' | wc -l) package manifests, $links symlinks"

# Place the OHOS addons at the zero-source-change paths (SOT conclusion 13) in every installed copy.
: >"$TREE/oh/placed.txt"
place() { # <package-name> <relative path inside package> <signed file>
  local dirs d n=0
  dirs=$(find "$TREE/node_modules" -type d -path "*/node_modules/$1" -prune)
  for d in $dirs; do
    [ -f "$d/package.json" ] || continue
    mkdir -p "$(dirname "$d/$2")"; cp "$3" "$d/$2"; n=$((n + 1))
    echo "${d#"$TREE"/}/$2" >>"$TREE/oh/placed.txt"
  done
  [ $n -gt 0 ] || die "package $1 not found in tree; cannot place $(basename "$3")"
}
place node-addon-require-builtin build/napi/napi-v9-openharmony-arm64/require_builtin.node "$NAT/require_builtin.node"
place node-pty prebuilds/openharmony-arm64/pty.node "$NAT/pty.node"
place koffi build/koffi/openharmony_arm64/koffi.node "$NAT/koffi.node"
# ripgrep: @vscode/ripgrep resolves `@vscode/ripgrep-${platform}-${arch}/bin/rg` from its own location; add that
# platform package (no exports map, so the subpath resolves) beside every installed copy.
n=0
while IFS= read -r d; do
  v=$(node -p 'require(process.argv[1]).version' "$d/package.json")
  P=$(dirname "$d")/ripgrep-openharmony-arm64; rm -rf "$P"; mkdir -p "$P/bin"
  cp "$NAT/rg" "$P/bin/rg"; chmod 755 "$P/bin/rg"
  printf '{\n  "name": "@vscode/ripgrep-openharmony-arm64",\n  "version": "%s",\n  "description": "ripgrep for openharmony-arm64 (OHOS NDK build, self-signed by scripts/openharmony). Used by @vscode/ripgrep.",\n  "license": "MIT",\n  "os": ["openharmony"],\n  "cpu": ["arm64"]\n}\n' "$v" >"$P/package.json"
  echo "${P#"$TREE"/}/bin/rg" >>"$TREE/oh/placed.txt"; n=$((n + 1))
done < <(find "$TREE/node_modules" -type d -path '*/node_modules/@vscode/ripgrep' -prune)
[ $n -gt 0 ] || die "@vscode/ripgrep not found in tree; cannot place rg"
sv=$(node -p 'require(process.argv[1]).version' "$TREE/node_modules/sharp/package.json")
[ "$sv" = "$SHARP_WASM" ] || die "sharp $sv in the tree but @img/sharp-wasm32 $SHARP_WASM; the wasm fallback must match sharp's version"

# flock: unpack the packed @deepseek-ai/node-addon-system-openharmony-arm64 tarball into the tree. npm refuses it
# as a direct dependency on a non-OpenHarmony build host (EBADPLATFORM; --os only filters optional edges), and the
# entry's optional edge to it is omitted with the other optional dependencies.
FP=$TREE/node_modules/@deepseek-ai/node-addon-system-openharmony-arm64
rm -rf "$FP"; mkdir -p "$FP"
tar -xzf "$(find "$PACK/npm-ohos" -name '*.tgz' | head -1)" -C "$FP" --strip-components=1
FL=$TREE/node_modules/@deepseek-ai/node-addon-system-openharmony-arm64/bin/system.node
cmp -s "$FL" "$NAT/system.node" || die "installed flock platform package does not carry $NAT/system.node"
echo "node_modules/@deepseek-ai/node-addon-system-openharmony-arm64/bin/system.node" >>"$TREE/oh/placed.txt"

# ELF sweep: every aarch64 ELF must be a self-signed OHOS build; unsigned ELF (linux/musl/glibc prebuilds,
# other-arch binaries) cannot be loaded or executed on the device and is removed.
: >"$TREE/oh/elf-sweep.txt"
signed=0 removed=0
while IFS= read -r -d '' f; do
  [ "$(head -c4 "$f" | od -An -tx1 | tr -d ' ')" = 7f454c46 ] || continue
  rel=${f#"$TREE"/}
  if has_section "$f" .codesign; then
    check_load_align "$f" >/dev/null || die "$rel: PT_LOAD not congruent mod 4K"
    echo "signed  $rel NEEDED=[$(needed_of "$f")]" >>"$TREE/oh/elf-sweep.txt"; signed=$((signed + 1))
  else
    echo "removed $rel ($(file -b "$f" | cut -d, -f1-2))" >>"$TREE/oh/elf-sweep.txt"; rm -f "$f"; removed=$((removed + 1))
  fi
done < <(find "$TREE/node_modules" -type f -size +1k -print0)
log "ELF sweep: $signed signed kept, $removed unsigned removed (see oh/elf-sweep.txt)"
[ "$signed" -eq "$(wc -l <"$TREE/oh/placed.txt")" ] || die "signed ELF count $signed != placed $(wc -l <"$TREE/oh/placed.txt")"

(cd "$TREE" && xargs -a oh/placed.txt sha256sum) >"$TREE/oh/SHA256SUMS"
cp "$OH_HERE/device-smoke.cjs" "$OH_HERE/openharmony.patch.yml" "$OH_HERE/m3-replay.patch.yml" "$OH_HERE/m3-inspect.cjs" \
  "$OH_HERE/m6-replay.patch.yml" "$OH_HERE/m6-terminal.mjs" "$TREE/oh/"
# M3 fixtures (smoke.sh --m3): recorded sessions replayed by dsh-llm-replay; highest generation of each.
for sc in bash-tool-turn fs-write; do
  S=$DSH/snapshots/session/$sc; f=$(find "$S" -maxdepth 1 -name 'session*.jsonl' | sort -V | tail -1)
  [ -n "$f" ] || die "missing fixture $S"
  mkdir -p "$TREE/oh/m3/$sc/workspace"; cp "$f" "$TREE/oh/m3/$sc/"
  [ ! -d "$S/workspace" ] || cp -r "$S/workspace/." "$TREE/oh/m3/$sc/workspace/"
done
# M6 fixtures (smoke.sh --m6): fs-glob-sampling (glob tool -> rg --files) and pty-tools-sandbox-backend (terminal
# tools; m6-replay.patch.yml swaps the recorded in-memory backend for the real PTY stack).
for sc in fs-glob-sampling pty-tools-sandbox-backend; do
  S=$DSH/snapshots/session/$sc; f=$(find "$S" -maxdepth 1 -name 'session*.jsonl' | sort -V | tail -1)
  [ -n "$f" ] || die "missing fixture $S"
  mkdir -p "$TREE/oh/m6/$sc"; cp "$f" "$TREE/oh/m6/$sc/"
done
[ -d "$TREE/node_modules/@deepseek-ai/dsh-llm-replay/lib" ] || die "dsh-llm-replay missing from the tree (needed by smoke.sh --m3)"
git -C "$DSH" rev-parse HEAD >"$TREE/oh/dsh-commit.txt"
cat "$TREE/oh/elf-sweep.txt"
log "tree ready: $TREE ($(du -sh "$TREE" | cut -f1))"
