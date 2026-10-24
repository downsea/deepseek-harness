#!/usr/bin/env bash
# Device smoke over ssh: M1 (addons load from the deployed tree), M2 (dsh --profile headless --help), and with
# --m3 a keyless session-persistence probe. The device-side part is POSIX sh (the device has mksh/toybox, no bash).
#
# Usage: smoke.sh [--m3] <host-alias>
# Output lines prefixed M1/M2/M3; exit status is non-zero when M1 or M2 fails; M3 prints its own verdict lines.
#
# --m3 replays two recorded sessions through dsh-llm-replay (tree/oh/m3-replay.patch.yml): no credential is
# placed on the device and no request leaves it.
set -euo pipefail
M3=0
[ "${1:-}" = --m3 ] && { M3=1; shift; }
[ $# -eq 1 ] || { echo "usage: smoke.sh [--m3] <host-alias>" >&2; exit 2; }
HOST=$1
ROOT="${DSH_OH_ROOT:-/data/storage/el2/base/dsh}"

ssh "$HOST" "ROOT='$ROOT' M3=$M3 sh -s" <<'DEVICE'
set -u
. "$ROOT/bin/oh-env.sh"
NODE="$ROOT/node/bin/node"
OUT="$TMPDIR/oh-smoke.$$"; mkdir -p "$OUT"
rc=0
echo "M0 device: $(uname -sr 2>/dev/null) node=$("$NODE" -v) root=$ROOT commit=$(cat "$ROOT/tree/oh/dsh-commit.txt")"

# M1: every placed addon loads from the tree and works once.
"$NODE" "$ROOT/tree/oh/device-smoke.cjs" "$ROOT/tree" >"$OUT/m1.out" 2>&1; m1=$?
sed 's/^/M1 /' "$OUT/m1.out"
[ $m1 -eq 0 ] || rc=1

# M2: headless --help exits 0 and never reports a missing native binding.
start=$(date +%s)
sh "$ROOT/bin/dsh" --profile headless --help >"$OUT/m2.out" 2>"$OUT/m2.err"; m2=$?
end=$(date +%s)
if grep -q 'No usable native binding' "$OUT/m2.err"; then nb=yes; else nb=no; fi
echo "M2 exit=$m2 no-usable-native-binding=$nb seconds=$((end - start)) stdout-lines=$(wc -l <"$OUT/m2.out") stderr-lines=$(wc -l <"$OUT/m2.err")"
head -5 "$OUT/m2.out" | sed 's/^/M2 stdout: /'
head -40 "$OUT/m2.err" | sed 's/^/M2 stderr: /'
{ [ $m2 -eq 0 ] && [ $nb = no ]; } || rc=1

if [ "$M3" = 1 ]; then
  # M3: replay two recorded headless sessions (no key, no network): bash-tool-turn runs one bash-tool command
  # through the overlay's shellPath (/bin/sh); fs-write creates a new file with the write tool. Each run must
  # persist a session log (lease taken) and exit 0.
  PATCH="$OUT/m3-replay.patch.yml"
  sed "s|name: '@deepseek-ai/dsh-llm-replay'|name: '$ROOT/tree/node_modules/@deepseek-ai/dsh-llm-replay/lib/index.js'|" \
    "$ROOT/tree/oh/m3-replay.patch.yml" >"$PATCH"
  for sc in bash-tool-turn fs-write; do
    W="$TMPDIR/oh-m3-$sc"; H="$W.home"; rm -rf "$W" "$H"; mkdir -p "$W" "$H"
    cp -R "$ROOT/tree/oh/m3/$sc/workspace/." "$W/" 2>/dev/null
    F=$(ls "$ROOT/tree/oh/m3/$sc"/session*.jsonl | tail -1)
    ( cd "$W" && DSH_HOME="$H" DSH_PERMISSION_MODE=danger-full-access DSH_SNAPSHOT_FILE="$F" \
      timeout 180 sh "$ROOT/bin/dsh" --patch "$PATCH" --profile headless "replay $sc" >"$OUT/m3.out" 2>"$OUT/m3.err" ); m3=$?
    echo "M3 $sc exit=$m3 stdout=$(head -c 80 "$OUT/m3.out" | tr '\n' ' ') workspace=[$(ls "$W" | tr '\n' ' ')]"
    grep -v '^dsh: reasoning' "$OUT/m3.err" | head -40 | sed "s/^/M3 $sc stderr: /"
    "$NODE" "$ROOT/tree/oh/m3-inspect.cjs" "$H" >"$OUT/m3.inspect" 2>&1; ins=$?
    sed "s/^/M3 $sc /" "$OUT/m3.inspect"
    find "$H/sessions" -type f 2>/dev/null | sed "s|^$H/|M3 $sc file: |"
    lock=$(find "$H/sessions" -name session.lock 2>/dev/null | wc -l)
    if [ $m3 -eq 0 ] && [ $ins -eq 0 ] && [ "$lock" -gt 0 ]; then v=ok; else v=fail; fi
    echo "M3 $sc verdict=$v (exit=$m3 tools-ok=$([ $ins -eq 0 ] && echo yes || echo no) lock-files=$lock)"
  done
fi
rm -rf "$OUT"
exit $rc
DEVICE
