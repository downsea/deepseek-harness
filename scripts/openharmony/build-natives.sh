#!/usr/bin/env bash
# Cross-build the dsh native addons for aarch64-unknown-linux-ohos with the OHOS NDK, self-sign each one,
# check PT_LOAD congruence after signing, and write a sha256 manifest.
#
# Usage: build-natives.sh <dsh-checkout> <out>
#   <out>/unsigned/*.node, unsigned/rg   NDK / cargo build output
#   <out>/signed/*.node, signed/rg       self-signed copies (what pack-tree.sh places)
#   <out>/SHA256SUMS        sha256 of signed/*
#   <out>/readings.txt      NEEDED / .codesign / PT_LOAD per signed file
#   <out>/src/              fetched third-party sources (reused on re-runs)
#   <out>/rg-target/        cargo target dir for ripgrep (reused on re-runs)
#
# Products: node-addon-require-builtin (napi-v9), @deepseek-ai/node-addon-system flock (system.node),
# node-pty (pty.node; no spawn-helper on Linux/OHOS), koffi (koffi.node), and the ripgrep executable `rg`
# that @vscode/ripgrep resolves as @vscode/ripgrep-openharmony-arm64/bin/rg.
# Versions are pinned below and checked against <dsh-checkout>/pnpm-lock.yaml; a drift fails the run.
. "$(dirname "$0")/lib.sh"
[ $# -eq 2 ] || die "usage: build-natives.sh <dsh-checkout> <out>"
DSH=$(cd "$1" && pwd); mkdir -p "$2"; OUT=$(cd "$2" && pwd)
SRC=$OUT/src UNS=$OUT/unsigned SIG=$OUT/signed
require_tools

NARB_VERSION=0.1.9 NARB_COMMIT=a58d359   # dsh-node-addon-require-builtin "release: 0.1.9"
NODE_PTY_VERSION=1.2.0-beta.15
KOFFI_VERSION=3.1.1
NAA_NARB=8.9.0   # node-addon-api used by require-builtin
NAA_PTY=7.1.1    # node-addon-api used by node-pty
VSCODE_RG_VERSION=1.18.0 RG_VERSION=15.0.0   # @vscode/ripgrep 1.18.0 ships ripgrep 15.0.0 (+pcre2)
# Node headers must match the device's node; default to the device CLT's own include dir over virtiofs.
NODE_INCLUDE="${NODE_INCLUDE:-$DEVICE_CLT/node/include/node}"
[ -f "$NODE_INCLUDE/node_api.h" ] || die "no node_api.h under $NODE_INCLUDE (set NODE_INCLUDE)"

lock=$DSH/pnpm-lock.yaml
for pin in "node-addon-require-builtin@$NARB_VERSION" "node-pty@$NODE_PTY_VERSION" "koffi@$KOFFI_VERSION" \
  "'@vscode/ripgrep@$VSCODE_RG_VERSION'"; do
  grep -q "^  $pin" "$lock" || die "$pin not in $lock; update the pins in $(basename "$0")"
done
NS_BUILD=$DSH/native/system/scripts/build.ts
NS_OHOS=$DSH/native/system/packages/openharmony-arm64
[ -f "$NS_OHOS/prebuilds.json" ] && grep -q -- '--ohos-ndk' "$NS_BUILD" \
  || die "$DSH has no native/system openharmony-arm64 target (needs the build.ts --target openharmony-arm64 support)"

fetch_pack() { # <dir> <spec>
  [ -d "$SRC/$1/package" ] && return
  rm -rf "${SRC:?}/$1"; mkdir -p "$SRC/$1"
  (cd "$SRC/$1" && npm pack -q "$2" >/dev/null && tar xzf ./*.tgz)
}
mkdir -p "$SRC" "$UNS"
fetch_pack node-addon-api-narb "node-addon-api@$NAA_NARB"
fetch_pack node-addon-api-pty "node-addon-api@$NAA_PTY"
fetch_pack node-pty "node-pty@$NODE_PTY_VERSION"
fetch_pack koffi "koffi@$KOFFI_VERSION"
# require-builtin sources: NARB_SRC (a local checkout to clone from) avoids GitHub; OH_OFFLINE_SOURCES=1 fails instead
# of cloning from GitHub when neither <out>/src/narb nor NARB_SRC exists.
if [ ! -d "$SRC/narb/.git" ]; then
  if [ -n "${NARB_SRC:-}" ]; then
    [ -d "$NARB_SRC/.git" ] || die "NARB_SRC=$NARB_SRC is not a git checkout"
    git clone -q "$NARB_SRC" "$SRC/narb"
  elif [ "${OH_OFFLINE_SOURCES:-0}" = 1 ]; then
    die "no $SRC/narb and OH_OFFLINE_SOURCES=1: seed it with NARB_SRC=<dsh-node-addon-require-builtin checkout>"
  else
    git clone -q https://github.com/deepseek-ai/dsh-node-addon-require-builtin.git "$SRC/narb"
  fi
fi
git -C "$SRC/narb" checkout -q "$NARB_COMMIT"

wait_slot
# --- require-builtin: scripts/build.ts compileArgs() for linux, OHOS clang++, libc++ static.
S=$SRC/narb/packages/native/src
NARB_SRCS=( node_api_addon.cc debug_trace.cc native_types.cc runtime_symbol.cc require_builtin_probe.cc
  runtime_context/{helper,platform,darwin_arm64,darwin_x64,linux_arm64,linux_x64,win32_arm64,win32_x64,win32_ia32}.cc
  runtime_probe/{helper,platform,getter_decoder,posix,win32_common,darwin_arm64,darwin_x64,linux_arm64,linux_x64,win32_arm64,win32_x64,win32_ia32}.cc
  runtime_context/{embedder_data,runtime_profile,runtime_profile_napi}.cc runtime_compat_napi.cc )
log "build require-builtin $NARB_VERSION"
"${CAP[@]}" "$OHOS_CXX" -ffile-prefix-map="$OUT"=. -shared -fPIC -pthread -std=c++17 -O2 -Wall -Wextra -Wno-unused-parameter \
  -fno-exceptions -fvisibility=hidden -DNAPI_VERSION=9 -DNARB_BACKEND=1 -DNARB_PRODUCT=1 \
  -DNODE_ADDON_API_DISABLE_CPP_EXCEPTIONS -DNODE_GYP_MODULE_NAME=require_builtin \
  -I "$NODE_INCLUDE" -I "$SRC/node-addon-api-narb/package" "${NARB_SRCS[@]/#/$S/}" \
  -static-libstdc++ -Wl,--exclude-libs,ALL -Wl,-z,max-page-size=4096 -s -o "$UNS/require_builtin.node"

# --- node-addon-system flock: the repository's own build entry (writes the gitignored
# native/system/packages/openharmony-arm64/bin/system.node inside the checkout). It is plain TypeScript over
# node: built-ins, run with Node's type stripping; Node-API headers come from the running node.
log "build node-addon-system flock (native/system/scripts/build.ts --target openharmony-arm64)"
"${CAP[@]}" node "$NS_BUILD" --target openharmony-arm64 --ohos-ndk "$NDK" >&2
cp "$NS_OHOS/bin/system.node" "$UNS/system.node"

# --- node-pty: binding.gyp OS!="win" 'pty' target + node_addon_api_except.
log "build node-pty $NODE_PTY_VERSION"
"${CAP[@]}" "$OHOS_CXX" -ffile-prefix-map="$OUT"=. -shared -fPIC -pthread -std=gnu++17 -O2 -fstack-protector-strong -Wall \
  -fexceptions -DNAPI_CPP_EXCEPTIONS -DNODE_GYP_MODULE_NAME=pty -DBUILDING_NODE_EXTENSION \
  -I "$NODE_INCLUDE" -I "$SRC/node-addon-api-pty/package" "$SRC/node-pty/package/src/unix/pty.cc" -lutil \
  -static-libstdc++ -Wl,--exclude-libs,ALL -Wl,-z,max-page-size=4096 -s -o "$UNS/pty.node"

# --- koffi: bundled cnoke + OHOS cmake toolchain; statx compat header (OHOS musl lacks statx()).
log "build koffi $KOFFI_VERSION"
KW=$OUT/work/koffi; rm -rf "$KW"; mkdir -p "$OUT/work"; cp -r "$SRC/koffi/package" "$KW"
(
  export PATH="$NDK/build-tools/cmake/bin:$PATH" CMAKE_BUILD_PARALLEL_LEVEL=3
  "${CAP[@]}" node "$KW/cnoke.cjs" build -P "$KW" -D "$KW/src/koffi" --release -t openharmony_arm64 \
    -d CMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/ohos.toolchain.cmake" -d OHOS_ARCH=arm64-v8a -d OHOS_STL=c++_static \
    -d OHOS_ALLOW_UNDEFINED_SYMBOLS=ON -d CMAKE_CXX_FLAGS="-include $OH_HERE/ohos-compat/statx-compat.h" \
    -d CMAKE_SHARED_LINKER_FLAGS="-Wl,--exclude-libs,ALL -Wl,-z,max-page-size=4096"
) >"$OUT/koffi-build.log" 2>&1 || { tail -30 "$OUT/koffi-build.log" >&2; die "koffi build failed"; }
k=$(find "$KW/build" -name koffi.node -newer "$KW/package.json" | head -1)
[ -n "$k" ] || die "koffi build produced no koffi.node"
cp "$k" "$UNS/koffi.node"

# --- ripgrep: the crates.io release with its own Cargo.lock and the upstream feature set (+pcre2). The OHOS
# target enables PCRE2 JIT (pcre2-sys turns it off only for musl/android/ios targets), and sljit calls
# __clear_cache, which rustc's -nodefaultlibs link leaves undefined; link the NDK's compiler-rt builtins for it.
# cargo goes through the host build slot (CARGO_BUILD_JOBS=3, CPUs 0-2).
log "build ripgrep $RG_VERSION (cargo, aarch64-unknown-linux-ohos)"
RT_BUILTINS=$(find "$NDK/llvm/lib/clang" -path '*/aarch64-linux-ohos/libclang_rt.builtins.a' | head -1)
[ -n "$RT_BUILTINS" ] || die "no aarch64-linux-ohos libclang_rt.builtins.a under $NDK/llvm/lib/clang"
(
  export CARGO_TARGET_DIR="$OUT/rg-target" CARGO_BUILD_JOBS=3 RUST_TEST_THREADS=3 \
    CC_aarch64_unknown_linux_ohos="$OHOS_CC" AR_aarch64_unknown_linux_ohos="$LLVM/llvm-ar" \
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER="$OHOS_CC" \
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_RUSTFLAGS="-C strip=symbols -C link-arg=-Wl,-z,max-page-size=4096 -C link-arg=$RT_BUILTINS"
  rustc --version
  "${CAP[@]}" cargo install --locked ripgrep --version "$RG_VERSION" --features pcre2 \
    --target aarch64-unknown-linux-ohos --root "$OUT/rg-root" --no-track --force
) >"$OUT/rg-build.log" 2>&1 || { tail -30 "$OUT/rg-build.log" >&2; die "ripgrep build failed (log $OUT/rg-build.log)"; }
cp "$OUT/rg-root/bin/rg" "$UNS/rg"

# --- sign + check every product.
rm -rf "$SIG"; mkdir -p "$SIG"
: >"$OUT/readings.txt"
for f in require_builtin system pty koffi; do
  u=$UNS/$f.node s=$SIG/$f.node
  n=$(needed_of "$u"); [ "$n" = "libc.so " ] || die "$f.node NEEDED [$n], expected only libc.so"
  sign_elf "$u" "$s"
  { echo "== $f.node size=$(stat -c %s "$s") NEEDED=[$(needed_of "$s")] codesign=yes"; check_load_align "$s"; } >>"$OUT/readings.txt"
done
n=$(needed_of "$UNS/rg"); [ "$n" = "libc.so " ] || die "rg NEEDED [$n], expected only libc.so"
sign_elf "$UNS/rg" "$SIG/rg"; chmod 755 "$SIG/rg"
{ echo "== rg size=$(stat -c %s "$SIG/rg") NEEDED=[$(needed_of "$SIG/rg")] codesign=yes $(grep -m1 '^rustc ' "$OUT/rg-build.log")"; check_load_align "$SIG/rg"; } >>"$OUT/readings.txt"
(cd "$SIG" && sha256sum ./*.node ./rg) >"$OUT/SHA256SUMS"
cat "$OUT/readings.txt" "$OUT/SHA256SUMS"
log "natives ready in $SIG"
