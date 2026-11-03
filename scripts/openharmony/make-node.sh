#!/usr/bin/env bash
# Produce a self-signed node from the vendor-signed CLT node.
# Strips only .codesign; the .permission section (JIT / anonymous-executable-memory exemption) must
# survive, or the device kills the process on JIT. Signing on the VM is byte-identical to signing on the device.
#
# Usage: make-node.sh <clt-node> <out>
#   <clt-node>  e.g. /mnt/linux_share/storage/Users/currentUser/hmos-clt/command-line-tools/node/bin/node
#   <out>/bin/node, <out>/SHA256SUMS
. "$(dirname "$0")/lib.sh"
[ $# -eq 2 ] || die "usage: make-node.sh <clt-node> <out>"
SRCNODE=$1; mkdir -p "$2/bin"; OUT=$(cd "$2" && pwd)
[ -f "$SRCNODE" ] || die "no node at $SRCNODE"
[ -x "$READELF" ] && [ -x "$OBJCOPY" ] && [ -x "$BST" ] || die "missing llvm-readelf / llvm-objcopy / binary-sign-tool"

has_section "$SRCNODE" .permission || die "$SRCNODE has no .permission section; a node without it cannot JIT on the device"
perm_sha() { local d; d=$(mktemp -d -p "$OUT"); "$OBJCOPY" --dump-section .permission="$d/p" "$1" "$d/o"; sha256sum "$d/p" | cut -d' ' -f1; rm -rf "$d"; }
perm_before=$(perm_sha "$SRCNODE")
sign_elf "$SRCNODE" "$OUT/bin/node"
chmod +x "$OUT/bin/node"
has_section "$OUT/bin/node" .permission || die ".permission section lost after signing"
perm_after=$(perm_sha "$OUT/bin/node")
[ "$perm_before" = "$perm_after" ] || die ".permission content changed by signing"
log ".permission kept (sha256 $perm_after)"
(cd "$OUT" && sha256sum bin/node) >"$OUT/SHA256SUMS"
cat "$OUT/SHA256SUMS"
