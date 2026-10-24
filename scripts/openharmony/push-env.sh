#!/usr/bin/env bash
# Copy the host's ~/.env.private (the single source of every key) to the device, where bin/oh-env.sh loads it.
#
# Usage: push-env.sh <host-alias> [env-file]
#   <host-alias>  ssh alias of the device terminal sandbox (e.g. hmos)
#   [env-file]    defaults to ~/.env.private
#
# The file lands at /data/storage/el2/base/.env.private with mode 0600: the device home filesystem reads 0600 back
# as 0640 (group file_manager), el2 base keeps it. The content is never printed; only the two sha256 digests and the
# device mode are compared. Rotating a key = edit the host file, run this again.
. "$(dirname "$0")/lib.sh"
[ $# -ge 1 ] && [ $# -le 2 ] || die "usage: push-env.sh <host-alias> [env-file]"
HOST=$1; SRC=${2:-$HOME/.env.private}
DEST=/data/storage/el2/base/.env.private
[ -f "$SRC" ] || die "$SRC does not exist"
want=$(sha256sum "$SRC" | awk '{print $1}')
ssh "$HOST" "umask 077 && cat > '$DEST.new' && chmod 600 '$DEST.new' && mv '$DEST.new' '$DEST'" <"$SRC"
got=$(ssh "$HOST" "sha256sum '$DEST'" | awk '{print $1}')
mode=$(ssh "$HOST" "stat -c %a '$DEST'")
[ "$got" = "$want" ] || die "sha256 differs after copy"
[ "$mode" = 600 ] || die "device mode is $mode, expected 600"
log "pushed $(wc -l <"$SRC") lines to $HOST:$DEST (mode $mode, sha256 ${want:0:12}…)"
