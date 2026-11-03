#!/usr/bin/env bash
# Copy the host's ~/.env.private (the single source of every key) to the device, where bin/oh-env.sh loads it.
#
# Usage: push-env.sh <host-alias> [env-file]
#        push-env.sh --root <root> [--allow-credentials] <host-alias> <env-file>
#   <host-alias>  ssh alias of the device terminal sandbox (e.g. hmos)
#   [env-file]    defaults to ~/.env.private
#
# The file lands at /data/storage/el2/base/.env.private with mode 0600: the device home filesystem reads 0600 back
# as 0640 (group file_manager), el2 base keeps it. The content is never printed; only the two sha256 digests and the
# device mode are compared. Rotating a key = edit the host file, run this again.
#
# --root <root> serves a second root (deploy.sh): the file lands at <root>/env, which only that root's bin/oh-env.sh
# loads. The env file is required and is never ~/.env.private; it may hold only NAME=value lines and comments, and a
# credential-shaped name (KEY, PASSWORD, SECRET or TOKEN in any case, the pattern dsh scrubs from subprocess
# environments) is refused unless --allow-credentials is given. DSH_OH_OWNER must match <root>/.owner.
. "$(dirname "$0")/lib.sh"
ROOT='' ALLOW=0
while [ $# -gt 0 ]; do
  case $1 in
    --root) [ $# -ge 2 ] || die "--root needs a value"; ROOT=$2; shift 2 ;;
    --allow-credentials) ALLOW=1; shift ;;
    *) break ;;
  esac
done
[ -n "$ROOT" ] || [ "$ALLOW" = 0 ] || die "--allow-credentials applies to --root only"

if [ -z "$ROOT" ]; then
  [ $# -ge 1 ] && [ $# -le 2 ] || die "usage: push-env.sh <host-alias> [env-file] | push-env.sh --root <root> [--allow-credentials] <host-alias> <env-file>"
  HOST=$1; SRC=${2:-$HOME/.env.private}
  DEST=/data/storage/el2/base/.env.private
else
  [ $# -eq 2 ] || die "usage: push-env.sh --root <root> [--allow-credentials] <host-alias> <env-file>"
  HOST=$1; SRC=$2
  oh_second_root "$ROOT"
  [ -f "$SRC" ] || die "$SRC does not exist"
  [ "$(readlink -f "$SRC")" != "$(readlink -f "$HOME/.env.private")" ] || die "a second root never gets ~/.env.private; write a dedicated env file"
  bad=$(grep -vnE '^[[:space:]]*(#.*)?$|^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$SRC" | cut -d: -f1 | tr '\n' ' ' || true)
  [ -z "$bad" ] || die "$SRC: only NAME=value lines and comments are allowed (lines $bad)"
  creds=$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$SRC" | grep -iE 'KEY|PASSWORD|SECRET|TOKEN' | tr '\n' ' ' || true)
  if [ -n "$creds" ]; then
    [ "$ALLOW" = 1 ] || die "$SRC sets credential-shaped names ($creds); a second root's env file holds none unless --allow-credentials"
    log "pushing credential-shaped names on request: $creds"
  fi
  oh_owner "$HOST" "$ROOT" "${DSH_OH_OWNER:-maintainer}" require
  DEST=$ROOT/env
fi
[ -f "$SRC" ] || die "$SRC does not exist"
want=$(sha256sum "$SRC" | awk '{print $1}')
"$OH_SSH" "$HOST" "umask 077 && cat > '$DEST.new' && chmod 600 '$DEST.new' && mv '$DEST.new' '$DEST'" <"$SRC"
got=$("$OH_SSH" "$HOST" "sha256sum '$DEST'" | awk '{print $1}')
mode=$("$OH_SSH" "$HOST" "stat -c %a '$DEST'")
[ "$got" = "$want" ] || die "sha256 differs after copy"
[ "$mode" = 600 ] || die "device mode is $mode, expected 600"
log "pushed $(wc -l <"$SRC") lines to $HOST:$DEST (mode $mode, sha256 ${want:0:12}…)"
