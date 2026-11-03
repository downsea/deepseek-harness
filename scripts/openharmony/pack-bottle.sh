#!/usr/bin/env bash
# Package the standard HarmonyOS deployment of one dsh tree as a harmonybrew bottle and formula.
#
# Usage: pack-bottle.sh <tree> <node-out> <out> [--publish]
#   <tree>      pack-tree.sh <out>/tree (carries oh/, the signed addons, the flat node_modules)
#   <node-out>  make-node.sh <out> (uses <node-out>/bin/node)
#   <out>       receives dsh-<version>.payload.tar.gz, dsh-<version>.arm64_ohos.bottle.tar.gz and dsh.rb
#   --publish   copy the payload and bottle to $BOTTLE_DIR, install dsh.rb into $TAP_DIR/Formula, commit the tap
#
# The payload is the install scripts/openharmony/deploy.sh writes to the default root: tree/, node/bin/node and
# bin/{oh-env.sh,dsh,dsh-web}. The bottle's keg holds that payload plus brew/deploy-payload.sh, which the formula runs
# in post_install to replace the live tree in place (see brew/deploy-payload.sh).
#
# Environment (paths are this host's; every one is overridable):
#   ROOT        deployment root the launchers name [ /data/storage/el2/base/dsh ]
#   BOTTLE_URL  file:// URL of the published bottle directory
#               [ file:///storage/Users/currentUser/.local/share/homebrew-hmos-bottles ]
#   BOTTLE_DIR  that directory as a VM path (virtiofs mount of the PC home) [ /mnt/linux_share + BOTTLE_URL's path ]
#   TAP_DIR     the downsea/hmos tap checkout on the PC home
#               [ /mnt/linux_share/storage/Users/currentUser/.harmonybrew/Homebrew/Library/Taps/downsea/homebrew-hmos ]
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
[ $# -ge 3 ] || die "usage: pack-bottle.sh <tree> <node-out> <out> [--publish]"
TREE=$(cd "$1" && pwd); NODE=$(cd "$2" && pwd)/bin/node; mkdir -p "$3"; OUT=$(cd "$3" && pwd)
PUBLISH=0
for a in "${@:4}"; do case $a in --publish) PUBLISH=1 ;; *) die "unknown option $a" ;; esac; done

ROOT=${ROOT:-$OH_DEFAULT_ROOT}
BOTTLE_URL=${BOTTLE_URL:-file:///storage/Users/currentUser/.local/share/homebrew-hmos-bottles}
BOTTLE_DIR=${BOTTLE_DIR:-/mnt/linux_share${BOTTLE_URL#file://}}
TAP_DIR=${TAP_DIR:-/mnt/linux_share/storage/Users/currentUser/.harmonybrew/Homebrew/Library/Taps/downsea/homebrew-hmos}
HERE=$(cd "$(dirname "$0")" && pwd)

[ -f "$TREE/oh/dsh-commit.txt" ] && [ -f "$TREE/node_modules/@deepseek-ai/dsh/lib/bin.js" ] || die "$TREE is not a pack-tree.sh tree"
if [ ! -x "$NODE" ] || ! has_section "$NODE" .codesign; then die "$NODE is not a make-node.sh node"; fi
case $ROOT in "$OH_BASE"/?*) ;; *) die "ROOT must be under $OH_BASE: $ROOT" ;; esac
version=$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$TREE/node_modules/@deepseek-ai/dsh/package.json" | head -1)
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$ ]] || die "no usable version in $TREE/package.json"
commit=$(cat "$TREE/oh/dsh-commit.txt")
log "packaging dsh $version ($commit) for $ROOT"

work=$OUT/.bottle-work
payload=$OUT/dsh-$version.payload.tar.gz
bottle_name=dsh-$version.arm64_ohos.bottle.tar.gz
rm -rf "$work"; mkdir -p "$work/payload" "$work/keg/dsh/$version/libexec"

# The payload: the tree by hard link (a copy where the output is on another filesystem), then node and the launchers.
mkdir -p "$work/payload/tree" "$work/payload/node/bin" "$work/payload/bin"
cp -al "$TREE/." "$work/payload/tree/" 2>/dev/null || cp -a "$TREE/." "$work/payload/tree/"
cp "$NODE" "$work/payload/node/bin/node"
sed -e "s|@ROOT@|$ROOT|g" -e "s|@BASE@|$OH_BASE|g" "$HERE/brew/oh-env.sh.in" >"$work/payload/bin/oh-env.sh"
sed -e "s|@ROOT@|$ROOT|g" "$HERE/brew/dsh.zsh.in" >"$work/payload/bin/dsh"
cp "$HERE/dsh-web.zsh" "$work/payload/bin/dsh-web"
cp "$HERE/brew/deploy-payload.sh" "$work/payload/deploy-payload.sh"
printf '%s\n' "$version" >"$work/payload/VERSION"
chmod 755 "$work/payload/bin/oh-env.sh" "$work/payload/bin/dsh" "$work/payload/bin/dsh-web" "$work/payload/deploy-payload.sh"
chmod 755 "$work/payload/node/bin/node"
tar -C "$work/payload" -czf "$payload" tree node bin VERSION deploy-payload.sh
payload_sha=$(sha256sum "$payload" | cut -d' ' -f1)
log "payload $(du -sh "$payload" | cut -f1) sha256 ${payload_sha:0:12}…"

# The keg a pour unpacks: the payload and its deployer, plus the install receipt brew records.
install -m 644 "$payload" "$work/keg/dsh/$version/libexec/dsh-payload.tar.gz"
install -m 755 "$HERE/brew/deploy-payload.sh" "$work/keg/dsh/$version/libexec/deploy-payload.sh"
cat >"$work/keg/dsh/$version/INSTALL_RECEIPT.json" <<JSON
{"homebrew_version":"downsea/hmos pack-bottle.sh","used_options":[],"unused_options":[],"built_as_bottle":true,"poured_from_bottle":false,"installed_as_dependency":false,"installed_on_request":false,"changed_files":[],"time":$(date +%s),"source_modified_time":$(date +%s),"compiler":"clang","aliases":[],"runtime_dependencies":[],"source":{"spec":"stable","versions":{"stable":"$version","head":null,"version_scheme":0}},"arch":"arm64","built_on":{"os":"Linux"}}
JSON
tar -C "$work/keg" -czf "$work/$bottle_name" "dsh"
bottle_sha=$(sha256sum "$work/$bottle_name" | cut -d' ' -f1)
mv "$work/$bottle_name" "$OUT/$bottle_name"
log "bottle $(du -sh "$OUT/$bottle_name" | cut -f1) sha256 ${bottle_sha:0:12}…"

sed -e "s|@VERSION@|$version|g" \
    -e "s|@PAYLOAD_URL@|$BOTTLE_URL/dsh-$version.payload.tar.gz|g" \
    -e "s|@PAYLOAD_SHA@|$payload_sha|g" \
    -e "s|@BOTTLE_URL@|$BOTTLE_URL|g" \
    -e "s|@BOTTLE_SHA@|$bottle_sha|g" \
    -e "s|@ROOT@|$ROOT|g" "$HERE/brew/dsh.rb.in" >"$OUT/dsh.rb"
rm -rf "$work"
log "formula $OUT/dsh.rb"

if [ $PUBLISH = 1 ]; then
  install -m 644 "$OUT/$bottle_name" "$BOTTLE_DIR/$bottle_name" || die "cannot publish to $BOTTLE_DIR"
  install -m 644 "$payload" "$BOTTLE_DIR/dsh-$version.payload.tar.gz" || die "cannot publish the payload to $BOTTLE_DIR"
  if ! install -m 644 "$OUT/dsh.rb" "$TAP_DIR/Formula/dsh.rb" 2>/dev/null; then
    log "the tap at $TAP_DIR is not writable from this machine; the bottle and payload are published"
    log "put $OUT/dsh.rb at $TAP_DIR/Formula/dsh.rb on the PC (ssh ... 'cat > ...') and commit the tap"
    exit 1
  fi
  if git -C "$TAP_DIR" diff --quiet -- Formula/dsh.rb; then
    log "dsh.rb in $TAP_DIR already pins dsh $version"
  elif ! { git -C "$TAP_DIR" add Formula/dsh.rb &&
           git -C "$TAP_DIR" commit -qm "dsh $version (bottle ${bottle_sha:0:12}, commit ${commit:0:12})"; }; then
    die "cannot commit in $TAP_DIR"
  fi
  log "published the bottle to $BOTTLE_DIR and committed dsh.rb in $TAP_DIR; push and tap update happen on the PC"
fi

log "on the PC (HiShell): brew update && brew install downsea/hmos/dsh   # or: brew upgrade downsea/hmos/dsh"
log "then: dsh --version (expects $version); dsh-web"
