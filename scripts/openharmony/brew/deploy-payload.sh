#!/bin/sh
# Deploy the payload a harmonybrew dsh package carries into the standard deployment root.
#
# Usage: deploy-payload.sh <payload.tar.gz> [<root>]
#   <root>  the standard deployment root; default /data/storage/el2/base/dsh
#
# The payload holds tree/, node/bin/node, bin/{oh-env.sh,dsh,dsh-web}, VERSION and this script: the same install
# scripts/openharmony/deploy.sh writes for the default root. A package upgrade therefore replaces that install in
# place and the ~/.zshrc PATH block keeps pointing at it. The queued tree is verified (oh/SHA256SUMS and
# `dsh --version` from the staged copy) before the live tree is touched, the old tree stays until the installed
# launcher answers, and a dsh process running from the root blocks the deploy, as it does in deploy.sh.
set -eu

payload=${1:?usage: deploy-payload.sh <payload.tar.gz> [<root>]}
root=${2:-/data/storage/el2/base/dsh}
base=${root%/*}
stage=$root/.payload-new

die() { printf '[dsh-payload] FAIL: %s\n' "$*" >&2; exit 1; }
log() { printf '[dsh-payload] %s\n' "$*" >&2; }

[ -f "$payload" ] || die "no payload at $payload"
case $root in /data/storage/el2/base/?*) ;; *) die "root must be under /data/storage/el2/base: $root" ;; esac

# A running dsh holds the tree's files open and the new tree must not replace them under it.
# shellcheck disable=SC2009  # the terminal sandbox has no pgrep to rely on (deploy.sh greps ps too)
if ps -ef 2>/dev/null | grep -F "$root/" | grep -v grep >/dev/null; then
  die "a dsh process from $root runs; stop it (and dsh-web) and run the install again"
fi

log "unpack into $stage"
rm -rf "$stage"
mkdir -p "$stage"
tar -xzf "$payload" -C "$stage"
version=$(cat "$stage/VERSION")
[ -f "$stage/tree/oh/SHA256SUMS" ] || die "payload has no tree/oh/SHA256SUMS"
[ -f "$stage/node/bin/node" ] || die "payload has no node/bin/node"
[ -f "$stage/deploy-payload.sh" ] || die "payload has no deploy-payload.sh"

log "verify the queued tree (placed addons, then dsh --version from the staged copy)"
( cd "$stage/tree" && sha256sum -c oh/SHA256SUMS ) || die "the queued tree fails oh/SHA256SUMS"
(
  # shellcheck disable=SC1091  # rendered from brew/oh-env.sh.in at pack time
  . "$stage/bin/oh-env.sh"
  DSH_OH_ROOT=$root "$stage/node/bin/node" "$stage/tree/node_modules/@deepseek-ai/dsh/lib/bin.js" --version
) >"$stage/version.txt" 2>&1 || { tail -20 "$stage/version.txt" >&2; die "the queued tree does not run"; }
grep -qF -- "$version" "$stage/version.txt" || { cat "$stage/version.txt" >&2; die "the queued tree does not report $version"; }

log "replace the tree at $root"
mkdir -p "$root/bin" "$root/node/bin"
rm -rf "$root/tree.old"
had_tree=0
[ ! -d "$root/tree" ] || { had_tree=1; mv "$root/tree" "$root/tree.old"; }
mv "$stage/tree" "$root/tree" || die "could not move the new tree into $root"
cp "$stage/node/bin/node" "$root/node/bin/node.new"
chmod 755 "$root/node/bin/node.new"
mv "$root/node/bin/node.new" "$root/node/bin/node"
for f in oh-env.sh dsh dsh-web; do
  cp "$stage/bin/$f" "$root/bin/$f.new"
  chmod 755 "$root/bin/$f.new"
  mv "$root/bin/$f.new" "$root/bin/$f"
done

# The same marker deploy.sh uses, so the two installers agree on one block and never add a second PATH entry.
if [ -n "${HOME:-}" ]; then
  zshrc=$HOME/.zshrc
  if grep -q '^# >>> dsh (openharmony deploy.sh) >>>' "$zshrc" 2>/dev/null; then
    grep -qF "path=($root/bin \$path)" "$zshrc" || log "note: the ~/.zshrc dsh block names another root; left unchanged"
  else
    {
      printf '%s\n' '# >>> dsh (openharmony deploy.sh) >>>'
      # shellcheck disable=SC2016  # $path is zsh's array name, expanded by the shell that reads the block
      printf 'path=(%s/bin $path)\n' "$root"
      printf 'export DSH_HOME=%s/dsh-home\n' "$base"
      printf '%s\n' '# <<< dsh <<<'
    } >>"$zshrc"
    log "added the $root/bin PATH block to ~/.zshrc"
  fi
fi

log "check the installed launcher"
if out=$("$root/bin/dsh" --version 2>&1) && printf '%s\n' "$out" | grep -qF -- "$version"; then
  rm -rf "$root/tree.old" "$stage"
  log "deployed dsh $version to $root"
  printf '%s\n' "$out"
  exit 0
fi
printf '%s\n' "$out" >&2
if [ "$had_tree" = 1 ]; then
  rm -rf "$root/tree"
  mv "$root/tree.old" "$root/tree"
  die "the installed launcher does not report $version; the previous tree is back in place"
fi
die "the installed launcher does not report $version; $root holds the new tree without a previous one to restore"
