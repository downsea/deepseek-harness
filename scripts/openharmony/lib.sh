# shellcheck shell=bash
# Shared helpers for the OpenHarmony device recipe (VM side; bash). Source me.
# Every toolchain path is overridable from the environment.
set -euo pipefail

OH_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLT="${CLT:-$HOME/tools/command-line-tools}"
NDK="${NDK:-$CLT/sdk/default/openharmony/native}"
LLVM="$NDK/llvm/bin"
OHOS_CC="$LLVM/aarch64-unknown-linux-ohos-clang"
OHOS_CXX="$LLVM/aarch64-unknown-linux-ohos-clang++"
READELF="$LLVM/llvm-readelf"
OBJCOPY="$LLVM/llvm-objcopy"
BST="${BST:-$CLT/sdk/default/openharmony/toolchains/lib/binary-sign-tool}"
# Device CLT as seen from the VM through virtiofs (VM path = /mnt/linux_share + host absolute path).
DEVICE_CLT="${DEVICE_CLT:-/mnt/linux_share/storage/Users/currentUser/hmos-clt/command-line-tools}"

log() { printf '[oh] %s\n' "$*" >&2; }
die() { printf '[oh] FAIL: %s\n' "$*" >&2; exit 1; }

# Host rule: clang/cmake/make are not gated by the cargo build slot; wait while cargo/rustc runs,
# then run capped (nice + CPUs 0-2, -j3).
wait_slot() {
  while pgrep -x cargo >/dev/null || pgrep -x rustc >/dev/null; do
    log "cargo/rustc busy, waiting 60s"; sleep 60
  done
}
CAP=(nice -n 10); command -v taskset >/dev/null && CAP+=(taskset -c 0-2)

require_tools() {
  local t
  for t in "$OHOS_CC" "$OHOS_CXX" "$READELF" "$OBJCOPY" "$BST"; do
    [ -x "$t" ] || die "missing tool $t (set CLT/NDK/BST)"
  done
}

has_section() { "$READELF" -SW "$1" | grep -q " $2 "; }

# PT_LOAD offset ≡ vaddr (mod 4K) for every LOAD segment; prints one line per segment, fails on any mismatch.
check_load_align() {
  "$READELF" -lW "$1" | awk -v f="$1" '
    $1=="LOAD"{n++; o=strtonum($2); v=strtonum($3); ok=((o%4096)==(v%4096)); if(!ok) bad++
      printf "  LOAD off=%s vaddr=%s %s\n", $2, $3, ok?"ok":"MISALIGNED"}
    END{ if(n==0){print "  no LOAD segment in " f; exit 1} exit bad?1:0 }'
}

# Self-sign one ELF into <dst>: strip only .codesign (never .permission), sign with -selfSign 1, then
# require .codesign present and every LOAD segment 4K-congruent. Signer output goes to <dst>.sign.log.
sign_elf() {
  local src=$1 dst=$2 tmp
  tmp="$dst.in"
  cp "$src" "$tmp"
  if has_section "$tmp" .codesign; then "$OBJCOPY" --remove-section .codesign "$tmp"; fi
  "$BST" sign -inFile "$tmp" -outFile "$dst" -selfSign 1 >"$dst.sign.log" 2>&1 \
    || { cat "$dst.sign.log" >&2; rm -f "$tmp"; die "binary-sign-tool failed on $src"; }
  rm -f "$tmp"
  has_section "$dst" .codesign || die "$dst has no .codesign after signing"
  log "signed $(basename "$dst") ($(grep -c CompareElf "$dst.sign.log" || true) CompareElf warnings)"
  check_load_align "$dst" >&2 || die "$dst: PT_LOAD offset/vaddr not congruent mod 4K after signing"
}

needed_of() { "$READELF" -d "$1" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' '; }
