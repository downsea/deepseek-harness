#!/usr/bin/env bash
# Device smoke over ssh: M1 (addons and rg load or run from the deployed tree), M2 (dsh --profile headless --help),
# with --m3 a keyless session-persistence probe, and with --m6 the web, search and terminal probe. The device-side
# part is POSIX sh (the device has mksh/toybox, no bash).
#
# Usage: smoke.sh [--m3] [--m6] <host-alias>
# Output lines prefixed M1/M2/M3/M6; exit status is non-zero when M1 or M2 fails; M3 and M6 print their own
# verdict lines.
#
# --m3 and --m6 replay recorded sessions through dsh-llm-replay (tree/oh/m3-replay.patch.yml): no credential is
# placed on the device and no request leaves it. --m6 also starts `dsh --profile web` on 127.0.0.1:$M6_PORT
# (default 3999) for one HTTP check and stops it again.
#
# Second root (DSH_OH_ROOT other than the default, deploy.sh): DSH_OH_OWNER (default "maintainer") must match
# <root>/.owner; the web check refuses an occupied port and stops only a server started from this root. Runs keep
# their scratch under the root's TMPDIR (bin/oh-env.sh), so nothing outside the root is written.
set -euo pipefail
M3=0 M6=0
while [ $# -gt 1 ]; do
  case $1 in --m3) M3=1 ;; --m6) M6=1 ;; *) break ;; esac; shift
done
[ $# -eq 1 ] || { echo "usage: smoke.sh [--m3] [--m6] <host-alias>" >&2; exit 2; }
HOST=$1
DEFAULT_ROOT=/data/storage/el2/base/dsh
ROOT="${DSH_OH_ROOT:-$DEFAULT_ROOT}"
PORT="${M6_PORT:-3999}"
OWNER="${DSH_OH_OWNER:-maintainer}"
# ssh by absolute path (an unattended caller may block the bare name); OH_SSH overrides.
if [ -z "${OH_SSH:-}" ]; then if [ -x /usr/bin/ssh ]; then OH_SSH=/usr/bin/ssh; else OH_SSH=ssh; fi; fi
SCOPED=0
if [ "$ROOT" != "$DEFAULT_ROOT" ]; then
  SCOPED=1
  [[ $ROOT =~ ^/data/storage/el2/base/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "smoke.sh: DSH_OH_ROOT must be /data/storage/el2/base/<name>" >&2; exit 2; }
  [[ $OWNER =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "smoke.sh: bad DSH_OH_OWNER" >&2; exit 2; }
  [[ $PORT =~ ^[0-9]+$ ]] || { echo "smoke.sh: bad M6_PORT" >&2; exit 2; }
elif [ "$OWNER" != maintainer ]; then
  echo "smoke.sh: $ROOT is the maintainer's root; DSH_OH_OWNER=$OWNER smokes its own DSH_OH_ROOT" >&2; exit 2
fi

"$OH_SSH" "$HOST" "ROOT='$ROOT' M3=$M3 M6=$M6 PORT=$PORT SCOPED=$SCOPED OWNER='$OWNER' sh -s" <<'DEVICE'
set -u
if [ "$SCOPED" = 1 ]; then
  o=$(cat "$ROOT/.owner" 2>/dev/null)
  [ "$o" = "$OWNER" ] || { echo "M0 FAIL: $ROOT/.owner is '$o', not '$OWNER'"; exit 3; }
fi
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
"$ROOT/bin/dsh" --profile headless --help >"$OUT/m2.out" 2>"$OUT/m2.err"; m2=$?
end=$(date +%s)
if grep -q 'No usable native binding' "$OUT/m2.err"; then nb=yes; else nb=no; fi
echo "M2 exit=$m2 no-usable-native-binding=$nb seconds=$((end - start)) stdout-lines=$(wc -l <"$OUT/m2.out") stderr-lines=$(wc -l <"$OUT/m2.err")"
head -5 "$OUT/m2.out" | sed 's/^/M2 stdout: /'
head -40 "$OUT/m2.err" | sed 's/^/M2 stderr: /'
{ [ $m2 -eq 0 ] && [ $nb = no ]; } || rc=1

if [ "$M3" = 1 ]; then
  # M3: replay two recorded headless sessions (no key, no network): bash-tool-turn runs one bash-tool command
  # through the overlay's shellPath (/usr/bin/zsh); fs-write creates a new file with the write tool. Each run must
  # persist a session log (lease taken) and exit 0.
  PATCH="$OUT/m3-replay.patch.yml"
  sed "s|name: '@deepseek-ai/dsh-llm-replay'|name: '$ROOT/tree/node_modules/@deepseek-ai/dsh-llm-replay/lib/index.js'|" \
    "$ROOT/tree/oh/m3-replay.patch.yml" >"$PATCH"
  for sc in bash-tool-turn fs-write; do
    W="$TMPDIR/oh-m3-$sc"; H="$W.home"; rm -rf "$W" "$H"; mkdir -p "$W" "$H"
    cp -R "$ROOT/tree/oh/m3/$sc/workspace/." "$W/" 2>/dev/null
    F=$(ls "$ROOT/tree/oh/m3/$sc"/session*.jsonl | tail -1)
    ( cd "$W" && DSH_HOME="$H" DSH_PERMISSION_MODE=danger-full-access DSH_SNAPSHOT_FILE="$F" \
      timeout 180 "$ROOT/bin/dsh" --patch "$PATCH" --profile headless "replay $sc" >"$OUT/m3.out" 2>"$OUT/m3.err" ); m3=$?
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

if [ "$M6" = 1 ]; then
  RG="$ROOT/tree/node_modules/@vscode/ripgrep-openharmony-arm64/bin/rg"
  # Search: the placed rg runs and finds a match.
  W="$TMPDIR/oh-m6-rg"; rm -rf "$W"; mkdir -p "$W/sub"; echo 'm6 needle line' >"$W/sub/hit.txt"
  echo "M6 rg version: $("$RG" --version | head -1)"
  hit=$("$RG" -n --no-config needle "$W" 2>&1); rgx=$?
  echo "M6 rg exit=$rgx hit=$hit"
  if [ $rgx -eq 0 ] && echo "$hit" | grep -q 'hit.txt:1:m6 needle line'; then v=ok; else v=fail; fi
  echo "M6 rg verdict=$v"

  # Replays: glob tool (rg --files through @vscode/ripgrep) and the terminal tools on the real PTY stack.
  PATCH="$OUT/m6-replay.patch.yml"
  cat "$ROOT/tree/oh/m3-replay.patch.yml" "$ROOT/tree/oh/m6-replay.patch.yml" \
    | sed "s|name: '@deepseek-ai/dsh-llm-replay'|name: '$ROOT/tree/node_modules/@deepseek-ai/dsh-llm-replay/lib/index.js'|" >"$PATCH"
  for sc in fs-glob-sampling pty-tools-sandbox-backend; do
    W="$TMPDIR/oh-m6-$sc"; H="$W.home"; rm -rf "$W" "$H"; mkdir -p "$W" "$H"
    for f in archive/a.ts docs/guide.md src/index.ts top.txt; do mkdir -p "$(dirname "$W/tree/$f")"; echo fixture >"$W/tree/$f"; done
    F=$(ls "$ROOT/tree/oh/m6/$sc"/session*.jsonl | tail -1)
    ( cd "$W" && DSH_HOME="$H" DSH_PERMISSION_MODE=danger-full-access DSH_SNAPSHOT_FILE="$F" \
      timeout 180 "$ROOT/bin/dsh" --patch "$PATCH" --profile headless "replay $sc" >"$OUT/m6.out" 2>"$OUT/m6.err" ); m6=$?
    echo "M6 $sc exit=$m6"
    grep -v '^dsh: reasoning' "$OUT/m6.err" | head -20 | sed "s/^/M6 $sc stderr: /"
    "$NODE" "$ROOT/tree/oh/m3-inspect.cjs" "$H" >"$OUT/m6.inspect" 2>&1
    sed "s/^M3-/M6-/; s/^/M6 $sc /" "$OUT/m6.inspect"
    case $sc in
      fs-glob-sampling) need='result isError=false "tree/' ; n=1 ;;
      *) need='result isError=false .*PTY_M6_OK' ; n=2 ;;
    esac
    got=$(grep -c "M3-TOOL $need" "$OUT/m6.inspect")
    if [ $m6 -eq 0 ] && [ "$got" -ge $n ]; then v=ok; else v=fail; fi
    echo "M6 $sc verdict=$v (exit=$m6 matching-results=$got/$n)"
  done

  # Terminal: echo, resize, activity and close through dsh-subprocess-local, as the Web terminal controller uses it.
  W="$TMPDIR/oh-m6-term"; mkdir -p "$W"
  timeout 120 "$NODE" "$ROOT/tree/oh/m6-terminal.mjs" "$ROOT/tree" "$W" >"$OUT/m6t.out" 2>&1; t=$?
  sed 's/^/M6 /' "$OUT/m6t.out" | head -40
  echo "M6 terminal verdict=$([ $t -eq 0 ] && echo ok || echo fail) (failures=$t)"

  # Image attachments: sharp loads through its @img/sharp-wasm32 fallback and resizes once.
  ( cd "$ROOT/tree" && "$NODE" -e '
    const s = require("sharp")
    s({ create: { width: 64, height: 48, channels: 3, background: "#f00" } }).png().toBuffer()
      .then((b) => s(b).resize(16).jpeg().toBuffer({ resolveWithObject: true }))
      .then((r) => console.log(`sharp ok vips=${s.versions.vips} out=${r.info.format} ${r.info.width}x${r.info.height}`))
      .catch((e) => { console.log(`sharp fail ${e.message.split("\n")[0]}`); process.exitCode = 1 })' ) 2>&1 | sed 's/^/M6 /'

  # Web: start the web profile on loopback, sign in with the startup token, fetch / and stop the server. A second root
  # refuses an occupied port instead of signing in to (and later stopping) somebody else's server.
  if [ "$SCOPED" = 1 ] && "$NODE" -e '
    const c = require("node:net").connect(Number(process.argv[1]), "127.0.0.1")
    c.on("connect", () => { c.destroy(); process.exit(0) }).on("error", () => process.exit(1))' "$PORT" 2>/dev/null; then
    echo "M6 web 127.0.0.1:$PORT is already in use; nothing started"
    echo "M6 web verdict=fail"
  else
  W="$TMPDIR/oh-m6-web"; H="$W.home"; rm -rf "$W" "$H"; mkdir -p "$W" "$H"
  ( cd "$W" && DSH_HOME="$H" exec timeout 300 "$ROOT/bin/dsh" --profile web --host 127.0.0.1 --port "$PORT" --no-open \
    >"$OUT/web.out" 2>"$OUT/web.err" ) &
  url=''; i=0
  while [ $i -lt 90 ] && [ -z "$url" ]; do sleep 1; i=$((i + 1)); url=$(sed -n 's/^dsh web: //p' "$OUT/web.out"); done
  echo "M6 web startup-seconds=$i url=${url%%\?*}"
  anon=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")
  login=$(curl -s -c "$OUT/jar" -o /dev/null -w '%{http_code}' "$url")
  code=$(curl -s -b "$OUT/jar" -o "$OUT/index.html" -w '%{http_code}' "http://127.0.0.1:$PORT/")
  echo "M6 web anonymous=$anon token-login=$login root=$code bytes=$(wc -c <"$OUT/index.html") title=$(grep -o '<title>[^<]*' "$OUT/index.html" | head -1)"
  pat="lib/bin.js .*--port $PORT"
  [ "$SCOPED" = 0 ] || pat="$ROOT/tree/node_modules/@deepseek-ai/dsh/lib/bin.js .*--port $PORT"
  pid=$(ps -ef | grep -v grep | grep "$pat" | awk '{print $2}' | head -1)
  [ -z "$pid" ] || kill "$pid"; wait
  head -20 "$OUT/web.err" | sed 's/^/M6 web stderr: /'
  if [ "$code" = 200 ]; then v=ok; else v=fail; fi
  echo "M6 web verdict=$v"
  fi
fi
rm -rf "$OUT"
exit $rc
DEVICE
