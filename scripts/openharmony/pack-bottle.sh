#!/usr/bin/env bash
# Assemble the release payload of one built dsh tree for the harmonybrew package.
#
# Usage: pack-bottle.sh --payload-only <tree> <node-out> <out>
#   <tree>      a pack-tree.sh tree (carries oh/, the signed addons, the flat node_modules)
#   <node-out>  a make-node.sh output (uses <node-out>/bin/node)
#   <out>       receives payload/: tree/, node/bin/node, bin/{oh-env.sh,dsh,dsh-web}, VERSION, deploy-payload.sh
#
# Prints the payload directory. The release tool in nan/dsh-superagent tools/hmos (hmos-brew-release) signs the
# tree, smokes it on the device, packs it as the bottle and renders Formula/dsh.rb; this script writes no tarball,
# no formula and nothing outside <out>.
#
# The payload is the install scripts/openharmony/deploy.sh writes to the default root. brew/deploy-payload.sh is
# the package's deployer: hmos-brew-release carries it beside libexec/dsh-payload.tar.gz and runs it from
# post_install. Its interface `deploy-payload.sh <payload.tar.gz> [<root>]` and the default root
# /data/storage/el2/base/dsh are a contract with nan/dsh-superagent tools/hmos/post_install/dsh-deploy.rb; change
# them together.
#
# Environment:
#   ROOT  deployment root the launchers name [ /data/storage/el2/base/dsh ]
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

PAYLOAD_ONLY=0
args=()
for a in "$@"; do case $a in
  --payload-only) PAYLOAD_ONLY=1 ;;
  -*) die "unknown option $a" ;;
  *) args+=("$a") ;;
esac; done
[ ${#args[@]} -eq 3 ] || die "usage: pack-bottle.sh --payload-only <tree> <node-out> <out>"
[ "$PAYLOAD_ONLY" = 1 ] || die "pack-bottle.sh assembles the release payload only; pass --payload-only"
TREE=$(cd "${args[0]}" && pwd); NODE=$(cd "${args[1]}" && pwd)/bin/node; mkdir -p "${args[2]}"; OUT=$(cd "${args[2]}" && pwd)
ROOT=${ROOT:-$OH_DEFAULT_ROOT}
HERE=$(cd "$(dirname "$0")" && pwd)

[ -f "$TREE/oh/dsh-commit.txt" ] && [ -f "$TREE/node_modules/@deepseek-ai/dsh/lib/bin.js" ] || die "$TREE is not a pack-tree.sh tree"
if [ ! -x "$NODE" ] || ! has_section "$NODE" .codesign; then die "$NODE is not a make-node.sh node"; fi
case $ROOT in "$OH_BASE"/?*) ;; *) die "ROOT must be under $OH_BASE: $ROOT" ;; esac
version=$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$TREE/node_modules/@deepseek-ai/dsh/package.json" | head -1)
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$ ]] || die "no usable version in $TREE/node_modules/@deepseek-ai/dsh/package.json"
commit=$(cat "$TREE/oh/dsh-commit.txt")
log "assembling the dsh $version ($commit) payload for $ROOT"

payload=$OUT/payload
rm -rf "$payload"
mkdir -p "$payload/tree" "$payload/node/bin" "$payload/bin"
# The tree by hard link (a copy where the output is on another filesystem); the release tool then copies a file before
# it signs it, so this tree is never modified.
cp -al "$TREE/." "$payload/tree/" 2>/dev/null || cp -a "$TREE/." "$payload/tree/"
cp "$NODE" "$payload/node/bin/node"
sed -e "s|@ROOT@|$ROOT|g" -e "s|@BASE@|$OH_BASE|g" "$HERE/brew/oh-env.sh.in" >"$payload/bin/oh-env.sh"
sed -e "s|@ROOT@|$ROOT|g" "$HERE/brew/dsh.zsh.in" >"$payload/bin/dsh"
cp "$HERE/dsh-web.zsh" "$payload/bin/dsh-web"
cp "$HERE/brew/deploy-payload.sh" "$payload/deploy-payload.sh"
printf '%s\n' "$version" >"$payload/VERSION"
chmod 755 "$payload/bin/oh-env.sh" "$payload/bin/dsh" "$payload/bin/dsh-web" "$payload/deploy-payload.sh" "$payload/node/bin/node"
log "payload $payload"
printf '%s\n' "$payload"
