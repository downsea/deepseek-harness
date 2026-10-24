#!/usr/bin/zsh
# dsh-web: start the dsh Web UI on the HarmonyOS PC and open it in the device browser.
# deploy.sh installs this file as <root>/bin/dsh-web next to the bin/dsh launcher; run it from HiShell (zsh).
#
#   dsh-web                    serve on 127.0.0.1:3080 and open the tokened URL in the device browser
#   dsh-web --port 3090        serve on another port
#   dsh-web --no-open          serve only; open the printed URL yourself
#   dsh-web --profile <name>   start another web-type profile (default web)
#   dsh-web --patch <file>     layer one more patch overlay (repeatable, applied in order)
#   dsh-web -- <dsh args...>   pass the remaining arguments to dsh web unchanged
#
# The Web UI listens on loopback only; dsh rejects wildcard binds. The device browser is opened with an explicit
# bundle (`aa start -b com.huawei.hmos.browser`), because the implicit view-URL want is refused on this device.
emulate -L zsh
setopt err_return no_unset pipe_fail

root=${0:A:h:h}
port=3080
open=1
profile=web
patches=()
extra=()

while (( $# )); do
  case $1 in
    --port)    port=$2; shift 2 ;;
    --no-open) open=0; shift ;;
    --profile) profile=$2; shift 2 ;;
    --patch)   [[ -f $2 ]] || { print -u2 -- "dsh-web: --patch file does not exist: $2"; return 2 }
               patches+=(--patch ${2:A}); shift 2 ;;
    --)        shift; extra=("$@"); break ;;
    -h|--help) sed -n '2,11s/^# \{0,1\}//p' $0; return 0 ;;
    *)         print -u2 -- "dsh-web: unknown option $1 (put dsh options after --)"; return 2 ;;
  esac
done

# A listener that accepts but never answers is usually a stale `hdc rport tcp:<port>` left by the VM's dsh-web.
if $root/node/bin/node -e '
  const c = require("node:net").connect(Number(process.argv[1]), "127.0.0.1")
  c.on("connect", () => { c.destroy(); process.exit(0) }).on("error", () => process.exit(1))
' $port 2>/dev/null; then
  print -u2 -- "dsh-web: 127.0.0.1:$port is already in use. If no dsh web runs on this device, a stale hdc reverse"
  print -u2 -- "  forward from the VM usually holds it: on the VM run 'hdc fport ls' and 'hdc fport rm tcp:$port tcp:$port',"
  print -u2 -- "  or pick another port with --port."
  return 1
fi

$root/bin/dsh $patches --profile $profile --port $port --no-open $extra | while IFS= read -r line; do
  print -r -- $line
  if (( open )) && [[ $line == 'dsh web: '* ]]; then
    open=0
    if aa start -b com.huawei.hmos.browser -a MainAbility -U ${line#dsh web: } >/dev/null 2>&1; then
      print -r -- 'dsh-web: opened in the device browser'
    else
      print -r -- 'dsh-web: could not open the device browser; open the URL above'
    fi
  fi
done
