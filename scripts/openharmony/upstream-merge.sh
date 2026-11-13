#!/usr/bin/env bash
# upstream-merge.sh: the mechanical part of skill hmos-upstream-merge (.agents/skills/hmos-upstream-merge/SKILL.md):
# merge one upstream dsh-v* release tag into master in a worktree of its own, keep the HMOS delta, run the gates and
# the device recipe on a second root, and push master fast-forward. Where judgment is needed it stops (exit 2) with the
# worktree kept and a report an agent can act on; a later run resumes in that worktree.
#
# Usage: upstream-merge.sh [--no-push] [--base REF] <tag>
#   <tag>        an upstream dsh-v* release tag (lightweight or annotated)
#   --no-push    everything except the push; success ends in state merged-unpushed
#   --base REF   merge onto REF instead of origin/master (rehearsal only; implies --no-push)
# Run from a checkout of the fork (origin = downsea/deepseek-harness); an `upstream` remote is added when missing.
#
# Environment:
#   DSH_MERGE_ROOT       where the run lives (default ~/.cache): worktree <root>/dsh-merge-<tag>, report
#                        <root>/dsh-merge-<tag>.report.md, logs <root>/dsh-merge-<tag>.logs/ (kept), recipe output
#                        <root>/dsh-merge-<tag>.out and pristine tag worktree <root>/dsh-merge-<tag>.pristine (removed)
#   DSH_OH_ROOT          device root for the recipe (default /data/storage/el2/base/dsh-dev; the maintainer's
#                        /data/storage/el2/base/dsh is refused); DSH_OH_OWNER (default: the user), DSH_OH_HOST (default hmos)
#   DSH_MERGE_WAIT_MAX   seconds one machine-budget wait may take before the run gives up with 75 (default 1800);
#                        DSH_MERGE_WAIT_STEP re-check interval (default 60). Also passed to the recipe as OH_WAIT_MAX.
#   DSH_MERGE_DISK_GUARD the host-share water-level check (default ~/.bin/disk-guard.sh; --check must exit 0)
#   CARGO_SLOT_HELD      set by a caller that holds the machine's build slot (hmos-bundle run): the slot is not probed
#
# Exit: 0 done (pushed, merged-unpushed, already-merged) · 2 needs an agent or a human (worktree kept, report written) ·
# 1 failed (a tool error) · 75 busy (machine budget after a bounded wait; nothing to undo, re-run later).
# The last stdout line is always
#   dsh-merge: state=<STATE> tag=<tag> exit=<N> worktree=<path|-> report=<path|-> head=<sha12|->
# Progress goes to stderr. Contract: homebrew-hmos issue 005 (`hmos-bundle run dsh --merge` calls this script).
# shellcheck disable=SC2016,SC2329 # backticks in single quotes are report markdown; on_exit runs from the EXIT trap
set -euo pipefail

UPSTREAM_URL=https://github.com/deepseek-ai/deepseek-harness.git
UPSTREAM_SLUG=deepseek-ai/deepseek-harness
OH_DEFAULT_ROOT=/data/storage/el2/base/dsh
# Repository-owned paths (CLAUDE.md "HMOS delta", last row): ours on every merge conflict (rule 5).
OWNED_RE='^(CLAUDE\.md|scripts/openharmony/.*|\.agents/skills/hmos-[^/]*/.*|\.docs-check\.toml|scripts/docs-gate\.py)$'
# Generated files: take the tag's side, then regenerate with the owning tool (rule 2).
GENERATED_RE='(^|/)pnpm-lock\.yaml$|\.i18n\.yaml$'
# KNOWN-ISSUES.md section 1 grep set, applied to lines the range adds under src/ of the delta packages.
GREP_SET='\blink(Sync)?\(|process\.platform|userInfo\(|/proc/|statx|\bbash\b'
# The device recipe files whose change on the merge branch needs a review before they run on the device (skill §7).
DEVICE_REVIEW=(scripts/openharmony/deploy.sh scripts/openharmony/smoke.sh scripts/openharmony/push-env.sh
  scripts/openharmony/lib.sh scripts/openharmony/dsh-web.zsh)

say() { printf '[dsh-merge] %s\n' "$*" >&2; }
usage() {
  sed -n '7,10p' "$0" | sed 's/^# \{0,1\}//' >&2
  echo 'dsh-merge: state=failed tag=- exit=1 worktree=- report=- head=-'; exit 1
}

NO_PUSH=0 BASE_ARG=''
while [ $# -gt 0 ]; do
  case $1 in
    --no-push) NO_PUSH=1; shift ;;
    --base) [ $# -ge 2 ] || usage; BASE_ARG=$2; NO_PUSH=1; shift 2 ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) usage ;;
    *) break ;;
  esac
done
[ $# -eq 1 ] || usage
TAG=$1

MROOT=${DSH_MERGE_ROOT:-$HOME/.cache}
WT=$MROOT/dsh-merge-$TAG
REPORT=$MROOT/dsh-merge-$TAG.report.md
LOGS=$MROOT/dsh-merge-$TAG.logs
OUTDIR=$MROOT/dsh-merge-$TAG.out
PRISTINE=$MROOT/dsh-merge-$TAG.pristine
BRANCH=local/merge-$TAG
OHROOT=${DSH_OH_ROOT:-/data/storage/el2/base/dsh-dev}
OWNER=${DSH_OH_OWNER:-$(id -un)}
HOSTALIAS=${DSH_OH_HOST:-hmos}
WAIT_MAX=${DSH_MERGE_WAIT_MAX:-1800}
WAIT_STEP=${DSH_MERGE_WAIT_STEP:-60}
GUARD=${DSH_MERGE_DISK_GUARD:-$HOME/.bin/disk-guard.sh}
if [ -z "${OH_SSH:-}" ]; then if [ -x /usr/bin/ssh ]; then OH_SSH=/usr/bin/ssh; else OH_SSH=ssh; fi; fi

STEP=start STATE=failed NEXT='' HEAD12='' WRITE_REPORT=1 FINISHED=0 RESUMED=0 STARTED=$(date +%s)
T_SHA='' T_KIND='' BASE_SHA='' BASE_NAME='' U='' VERIFY_NOTE='' RANGE_N='' DELTA_N='' COVERED=''

# ---------------------------------------------------------------------------------------------------- run plumbing
st_get() { [ -f "$LOGS/state" ] && sed -n "s/^$1=//p" "$LOGS/state" | tail -1; return 0; }
st_set() {
  mkdir -p "$LOGS"
  { [ -f "$LOGS/state" ] && grep -v "^$1=" "$LOGS/state"; printf '%s=%s\n' "$1" "$2"; } >"$LOGS/state.new" || true
  mv "$LOGS/state.new" "$LOGS/state"
}

rerun_cmd() {
  local c='scripts/openharmony/upstream-merge.sh'
  [ -z "$BASE_ARG" ] && [ "$NO_PUSH" = 1 ] && c+=' --no-push'
  [ -n "$BASE_ARG" ] && c+=" --base $BASE_ARG"
  [ -n "${DSH_MERGE_ROOT:-}" ] && c="DSH_MERGE_ROOT=$DSH_MERGE_ROOT $c"
  printf '%s %s' "$c" "$TAG"
}

finish() { # <state> <exit> [next]: write the report, print the machine line, exit
  STATE=$1; local rc=$2 wt=- rp=-
  [ -n "${3:-}" ] && NEXT=$3
  if [ -d "$WT" ] && git -C "$WT" rev-parse -q --verify HEAD >/dev/null 2>&1; then HEAD12=$(git -C "$WT" rev-parse --short=12 HEAD); fi
  if [ "$WRITE_REPORT" = 1 ]; then write_report || say "could not write $REPORT"; fi
  [ -d "$WT" ] && wt=$WT
  [ "$WRITE_REPORT" = 1 ] && [ -f "$REPORT" ] && rp=$REPORT
  FINISHED=1
  say "$STATE after $(( $(date +%s) - STARTED ))s"
  printf 'dsh-merge: state=%s tag=%s exit=%s worktree=%s report=%s head=%s\n' "$STATE" "$TAG" "$rc" "$wt" "$rp" "${HEAD12:--}"
  exit "$rc"
}
on_exit() {
  local rc=$?
  [ "$FINISHED" = 1 ] && return
  trap - EXIT
  say "unexpected failure in step '$STEP' (exit $rc)"
  finish failed 1 "The script failed in step '$STEP' (exit $rc), a tool error rather than a judgment stop; its log is under $LOGS. Fix the cause and re-run \`$(rerun_cmd)\` (it resumes in the kept worktree when one exists)."
}
trap on_exit EXIT
trap 'exit 143' TERM; trap 'exit 130' INT

# Machine budget (skill §2): no heavy job of another session and a free build slot, then the host-share water level.
heavy_jobs() {
  { pgrep -xa cargo; pgrep -xa rustc; pgrep -xa box64; pgrep -xa node | grep -E 'vitest|tsc|tsdown|vite|tsx'; } 2>/dev/null || true
  [ -n "${CARGO_SLOT_HELD:-}" ] && return 0   # the caller holds the slot for us (hmos-bundle hold_slot)
  local d n free=0 slots=${CARGO_SLOTS:-1}
  d="${XDG_RUNTIME_DIR:-/tmp}/cargo-slot-$(id -u)"
  [ -d "$d" ] || return 0
  [[ $slots =~ ^[1-9][0-9]*$ ]] || slots=1
  for ((n = 0; n < slots; n++)); do
    [ -e "$d/$n.lock" ] || { free=1; break; }
    if (flock -n 9) 9<"$d/$n.lock" 2>/dev/null; then free=1; break; fi
  done
  [ "$free" = 1 ] || echo "build slot held: $(cat "$d"/*.owner 2>/dev/null | head -1)"
}
budget() { # <what> [disk]: wait for a free machine (unless "disk": the git-only steps), then check the water level
  local waited=0 h
  STEP="budget before $1"
  while [ "${2:-}" != disk ] && h=$(heavy_jobs) && [ -n "$h" ]; do
    if [ "$waited" -ge "$WAIT_MAX" ]; then
      say "still busy before $1 after ${waited}s: $(printf '%s' "$h" | head -3 | tr '\n' ';' | cut -c1-200)"
      finish busy 75 "Busy before $1 after ${waited}s (DSH_MERGE_WAIT_MAX=$WAIT_MAX): $(printf '%s' "$h" | head -2 | tr '\n' ';' | cut -c1-160). Nothing needs undoing; re-run \`$(rerun_cmd)\` when the machine is free."
    fi
    say "busy before $1 ($(printf '%s' "$h" | head -2 | tr '\n' ';' | cut -c1-160)); re-checking in ${WAIT_STEP}s"
    sleep "$WAIT_STEP"; waited=$((waited + WAIT_STEP))
  done
  if [ -x "$GUARD" ]; then
    "$GUARD" --check >/dev/null 2>&1 || finish busy 75 "The host share is below the disk margin ($GUARD --check exit non-zero; the number that matters is /mnt/linux_share/storage/Users/currentUser, ≥ 15 GiB). Free space on the host side (fed clean --apply, old worktrees), then re-run \`$(rerun_cmd)\`."
  else
    say "no $GUARD: host water level not checked"
  fi
}

run_in() { # <dir> <log> <bash command>: run, log, append wall time; returns the command's exit code
  local dir=$1 log=$2 s rc=0; s=$(date +%s)
  (cd "$dir" && bash -c "$3") >"$log" 2>&1 </dev/null || rc=$?
  printf 'RESULT rc=%s wall=%ss cmd=%s\n' "$rc" "$(( $(date +%s) - s ))" "$3" >>"$log"
  return "$rc"
}

# ---------------------------------------------------------------------------------------------------- report
md_table_rows() { # <tsv> <columns>: tab-separated rows as markdown table rows
  [ -s "$1" ] || return 0
  awk -F '\t' -v n="$2" '{ s = "|"; for (i = 1; i <= n; i++) s = s " " $i " |"; print s }' "$1"
}
write_report() {
  mkdir -p "$(dirname "$REPORT")"
  {
    printf '# dsh-merge %s: %s\n\n' "$TAG" "$STATE"
    printf 'Generated %s by `scripts/openharmony/upstream-merge.sh` (skill `hmos-upstream-merge`); exit and state as in the last stdout line. Worktree `%s`%s; logs `%s/`.\n\n' \
      "$(date '+%Y-%m-%d %H:%M:%S %z')" "$WT" "$(if [ -d "$WT" ]; then echo ' (kept)'; elif [ -n "$(st_get head)" ]; then echo ' (removed)'; else echo ' (not created)'; fi)" "$LOGS"
    printf '## Tag\n\n'
    printf -- '- `%s` = `%s` (%s tag)%s\n' "$TAG" "${T_SHA:-?}" "${T_KIND:-?}" "${VERIFY_NOTE:+; $VERIFY_NOTE}"
    printf -- '- base `%s` = `%s`; last upstream commit it absorbed U = `%s`\n' "${BASE_NAME:-?}" "${BASE_SHA:-?}" "${U:-?}"
    printf -- '- range U..tag: %s upstream commits onto %s fork delta commits%s\n' "${RANGE_N:-?}" "${DELTA_N:-?}" "${COVERED:+; also covers $COVERED}"
    printf -- '- head: `%s`\n\n' "$(if [ -d "$WT" ]; then git -C "$WT" rev-parse HEAD 2>/dev/null; else st_get head; fi)"
    printf '## Conflicts\n\n'
    if [ -s "$LOGS/conflicts.tsv" ]; then
      printf '| Path | Rule |\n|---|---|\n'; md_table_rows "$LOGS/conflicts.tsv" 2
    elif [ -f "$LOGS/conflicts.tsv" ]; then printf 'None: the merge applied textually.\n'
    else printf 'Not reached.\n'; fi
    printf '\n## Review\n\nKNOWN-ISSUES.md section 1 on U..tag, filtered to `src/` of the delta packages and the native pins (test and README hits left out). "ask" = needs a decision before the merge ships.\n\n'
    if [ -s "$LOGS/review.tsv" ]; then
      printf '| Area | Where | Hits | Verdict |\n|---|---|---|---|\n'; md_table_rows "$LOGS/review.tsv" 4
    else printf 'Not reached.\n'; fi
    printf '\n## Delta check\n\n'
    if [ -s "$LOGS/delta.txt" ]; then cat "$LOGS/delta.txt"; else printf 'Not reached.\n'; fi
    printf '\n## Gates\n\n'
    if [ -s "$LOGS/gates.tsv" ]; then
      printf '| Gate | Command | Exit | Classification | Log |\n|---|---|---|---|---|\n'; md_table_rows "$LOGS/gates.tsv" 5
    else printf 'Not reached.\n'; fi
    printf '\n## Device\n\n'
    if [ -s "$LOGS/device.txt" ]; then printf '```\n'; cat "$LOGS/device.txt"; printf '```\n'; else printf 'Not reached.\n'; fi
    printf '\n## Next\n\n%s\n' "${NEXT:-Nothing: done.}"
  } >"$REPORT.new"
  mv "$REPORT.new" "$REPORT"
}

# ---------------------------------------------------------------------------------------------------- §1 tag
STEP=checkout
REPO=$(git rev-parse --show-toplevel 2>/dev/null) || { say "not inside a git checkout"; exit 1; }
cd "$REPO"
case $(git remote get-url origin 2>/dev/null) in
  *downsea/deepseek-harness*) ;;
  *) say "origin is not the fork downsea/deepseek-harness"; finish failed 1 ;;
esac
[[ $TAG =~ ^dsh-v[0-9][0-9A-Za-z.+-]*$ ]] || { say "not a dsh-v* tag: $TAG"; finish failed 1; }
if [ "$OHROOT" = "$OH_DEFAULT_ROOT" ] || [ "$OHROOT" = "$OH_DEFAULT_ROOT/" ]; then
  finish review 2 "DSH_OH_ROOT=$OHROOT is the maintainer's install of the released package; the device check runs on a second root (default /data/storage/el2/base/dsh-dev). Unset DSH_OH_ROOT or point it at a second root and re-run."
fi
git remote get-url upstream >/dev/null 2>&1 || { say "adding remote upstream $UPSTREAM_URL"; git remote add upstream "$UPSTREAM_URL"; }

STEP="verify tag"
say "fetch origin, upstream master and $TAG"
git fetch -q origin
remote=$(git ls-remote upstream "refs/tags/$TAG" "refs/tags/$TAG^{}")
rsha=$(printf '%s\n' "$remote" | awk -v r="refs/tags/$TAG^{}" '$2 == r { print $1 }')
if [ -n "$rsha" ]; then T_KIND=annotated
else T_KIND=lightweight; rsha=$(printf '%s\n' "$remote" | awk -v r="refs/tags/$TAG" '$2 == r { print $1 }'); fi
[ -n "$rsha" ] || finish review 2 "Upstream has no tag $TAG (git ls-remote upstream). Check the tag name; the skill's section 1 lists the releases with \`gh release list -R $UPSTREAM_SLUG\`."
if lsha=$(git rev-parse -q --verify "refs/tags/$TAG^{commit}"); then
  [ "$lsha" = "$rsha" ] || finish review 2 "The local tag $TAG is $lsha but upstream's is $rsha: a moved or rewritten tag (skill §10). Ask the maintainer; do not merge."
else
  git fetch -q --no-tags upstream "refs/tags/$TAG:refs/tags/$TAG"
fi
git fetch -q --no-tags upstream '+refs/heads/master:refs/remotes/upstream/master'
T_SHA=$(git rev-parse "refs/tags/$TAG^{commit}")
[ "$T_SHA" = "$rsha" ] || finish review 2 "$TAG resolves to $T_SHA locally but ls-remote says $rsha (skill §10)."
VERIFY_NOTE="git ls-remote agrees"
if command -v gh >/dev/null 2>&1 && ref=$(gh api "repos/$UPSTREAM_SLUG/git/ref/tags/$TAG" --jq '.object.type + " " + .object.sha' 2>/dev/null); then
  gsha=${ref#* }
  [ "${ref%% *}" = tag ] && gsha=$(gh api "repos/$UPSTREAM_SLUG/git/tags/$gsha" --jq .object.sha)
  [ "$gsha" = "$T_SHA" ] || finish review 2 "The GitHub ref API names $gsha for $TAG, git names $T_SHA (skill §10: a moved tag). Ask the maintainer."
  rel=$(gh release view "$TAG" -R "$UPSTREAM_SLUG" --json isDraft,isPrerelease,publishedAt --jq '"draft=\(.isDraft) prerelease=\(.isPrerelease) published=\(.publishedAt)"' 2>/dev/null) \
    || finish review 2 "$TAG has no GitHub release on $UPSTREAM_SLUG; master follows releases only (skill §1). Ask which tag to merge."
  case $rel in draft=true*) finish review 2 "The release $TAG is a draft; master follows published releases only." ;; esac
  VERIFY_NOTE="git ls-remote and the GitHub ref API agree; release $rel"
else
  VERIFY_NOTE="git ls-remote agrees; GitHub API not reachable (gh missing or offline), release not checked"
fi

if [ -n "$BASE_ARG" ]; then BASE_NAME=$BASE_ARG; else BASE_NAME=origin/master; fi
BASE_SHA=$(git rev-parse --verify "$BASE_NAME^{commit}")

# ---------------------------------------------------------------------------------------------------- resume or fresh
if [ -e "$WT" ]; then
  RESUMED=1
  # Resume only in a worktree registered to this clone (the caller re-runs from the same clone); anything else is left
  # alone for a human.
  if ! git worktree list --porcelain | grep -qxF "worktree $(realpath "$WT")" \
    || [ "$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" != "$(git rev-parse --path-format=absolute --git-common-dir)" ]; then
    finish diverged 2 "\`$WT\` exists but is not a registered worktree of this clone (\`$REPO\`): made from another checkout, or this clone was re-created. It is left untouched. Continue the merge from the clone that owns it, or inspect it, move it away and re-run \`$(rerun_cmd)\` to start over."
  fi
  mkdir -p "$LOGS"
  sb=$(st_get base); [ -n "$sb" ] && BASE_SHA=$sb
  [ -n "$(st_get base_name)" ] && BASE_NAME=$(st_get base_name)
  [ "$(st_get push)" = 0 ] && NO_PUSH=1
  say "resuming in $WT (base $BASE_NAME ${BASE_SHA:0:12})"
else
  if git merge-base --is-ancestor "$T_SHA" "$BASE_SHA"; then
    say "$TAG ($T_SHA) is already an ancestor of $BASE_NAME"
    HEAD12=- WRITE_REPORT=0
    finish already-merged 0
  fi
fi
U=$(git merge-base "$BASE_SHA" "$T_SHA")
RANGE_N=$(git rev-list --count "$U..$T_SHA")
DELTA_N=$(git rev-list --count --no-merges "$T_SHA..$BASE_SHA")
while read -r sha ref; do
  t=${ref#refs/tags/}; t=${t%^\{\}}
  [ "$t" = "$TAG" ] && continue
  git merge-base --is-ancestor "$sha" "$T_SHA" 2>/dev/null && ! git merge-base --is-ancestor "$sha" "$BASE_SHA" 2>/dev/null \
    && COVERED="${COVERED:+$COVERED, }$t"
done < <(git ls-remote --tags upstream 'refs/tags/dsh-v*' | awk '{ sub(/\^\{\}$/, "", $2); s[$2] = $1 } END { for (r in s) print s[r], r }' | sort -k2)

if [ "$RESUMED" = 0 ]; then
  B=$(git merge-base "$BASE_SHA" refs/remotes/upstream/master)
  git merge-base --is-ancestor "$B" "$T_SHA" || { finish review 2 "$TAG does not contain ${B:0:12}, the last upstream commit $BASE_NAME absorbed: the tag sits behind master's line. Do not back-merge it (skill §1); ask which line master follows."; }

  # Fresh run: rotate the previous logs of this tag, take the lock, budget, review, merge.
  if [ -d "$LOGS" ]; then rm -rf "$LOGS.prev"; mv "$LOGS" "$LOGS.prev"; fi
  mkdir -p "$LOGS"
  st_set base "$BASE_SHA"; st_set base_name "$BASE_NAME"; st_set push "$((1 - NO_PUSH))"; st_set tag "$T_SHA"
fi
exec 9>"$LOGS/.lock"
flock -n 9 || { WRITE_REPORT=0; finish busy 75 "Another run of upstream-merge.sh holds $LOGS/.lock."; }

# ---------------------------------------------------------------------------------------------------- §3 review
REVIEW_ASK=0
review_inventory() {
  STEP="range review"
  local dirs=() d h a n p
  : >"$LOGS/review.tsv"
  mapfile -t dirs < <(git diff --no-renames --name-only "$U" "$BASE_SHA" | grep '/src/' | sed 's#/src/.*#/src#' | sort -u)
  printf '%s\n' "${dirs[@]}" >"$LOGS/delta-src.lst"
  # Grep set on lines the range adds under src/ of the delta packages; a line the same file also removes (moved or
  # re-indented code) is not new.
  if [ ${#dirs[@]} -gt 0 ]; then
    git diff --no-renames -U0 "$U" "$T_SHA" -- "${dirs[@]}" | awk '
      function flush(  k) { for (k in add) if (!(add[k] in del)) print file ":" k ":" add[k]; delete add; delete del }
      /^\+\+\+ / { flush(); file = substr($2, 3); next }
      /^--- / { next }
      /^@@ / { split($3, a, ","); ln = substr(a[1], 2) + 0; next }
      /^\+/ { t = substr($0, 2); gsub(/^[ \t]+|[ \t]+$/, "", t); add[ln] = t; ln++; next }
      /^-/ { t = substr($0, 2); gsub(/^[ \t]+|[ \t]+$/, "", t); del[t] = 1; next }
      END { flush() }' | grep -vE '\.(spec|test)\.[cm]?[jt]sx?:' | grep -E "$GREP_SET" | sort -t: -k1,1 -k2,2n >"$LOGS/review-hits.txt" || true
  else : >"$LOGS/review-hits.txt"; fi
  while IFS= read -r h; do
    p=${h%%:*}
    case $h in
      *link\(*|*linkSync\(*) a='Hard-link publish' ;;
      *userInfo\(*) a='os.userInfo()' ;;
      *bash*) a='Hard-coded bash' ;;
      *statx*) a='statx (OHOS musl lacks it)' ;;
      *) a='procfs / platform gates' ;;
    esac
    printf '%s\t`%s`\t`%s`\task\n' "$a" "$p" "$(printf '%s' "${h#*:}" | cut -c1-140 | tr '|`' '/'"'")" >>"$LOGS/review.tsv"
    REVIEW_ASK=$((REVIEW_ASK + 1))
  done <"$LOGS/review-hits.txt"
  for d in "${dirs[@]}"; do
    n=$(git rev-list --count --no-merges "$U..$T_SHA" -- "$d")
    [ "$n" = 0 ] || printf 'Delta package source\t`%s/`\t%s upstream commits\tcheck in gates\n' "$d" "$n" >>"$LOGS/review.tsv"
  done
  # Native pins of build-natives.sh against the tag's lockfile; a pin the lockfile no longer has fails build-natives.sh
  # and is a human question (skill §10).
  local bn lockT lockU pin var name have
  bn=$(git show "$BASE_SHA:scripts/openharmony/build-natives.sh")
  lockT=$(git show "$T_SHA:pnpm-lock.yaml"); lockU=$(git show "$U:pnpm-lock.yaml")
  for pin in NARB_VERSION:node-addon-require-builtin NODE_PTY_VERSION:node-pty KOFFI_VERSION:koffi VSCODE_RG_VERSION:@vscode/ripgrep; do
    var=${pin%%:*} name=${pin#*:}
    p=$(printf '%s\n' "$bn" | sed -nE "s/^(.*[[:space:]])?$var=([^[:space:]]+).*/\2/p" | head -1)
    have=$(printf '%s\n' "$lockT" | sed -nE "s#^  '?$name@([0-9][^'(:]*)'?:.*#\1#p" | sort -u | tr '\n' ' ')
    if printf ' %s ' "$have" | grep -qF " $p "; then
      printf 'Native pin\t`%s@%s`\tlockfile at the tag: %s\tnone\n' "$name" "$p" "${have% }" >>"$LOGS/review.tsv"
    else
      printf 'Native pin\t`%s@%s`\tlockfile at the tag: %s\task (pin drift; build-natives.sh would fail)\n' "$name" "$p" "${have:-absent}" >>"$LOGS/review.tsv"
      REVIEW_ASK=$((REVIEW_ASK + 1))
    fi
  done
  local su st
  su=$(printf '%s\n' "$lockU" | sed -nE "s#^  '@img/sharp-wasm32@([^']*)':\$#\1#p" | sort -u | tr '\n' ' ')
  st=$(printf '%s\n' "$lockT" | sed -nE "s#^  '@img/sharp-wasm32@([^']*)':\$#\1#p" | sort -u | tr '\n' ' ')
  if [ "$su" = "$st" ]; then printf 'Native pin\t`@img/sharp-wasm32`\t%s unchanged\tnone\n' "${st% }" >>"$LOGS/review.tsv"
  else printf 'Native pin\t`@img/sharp-wasm32`\t%s → %s\tcheck on device (pack-tree.sh follows the lockfile; M6 sharp)\n' "${su% }" "${st% }" >>"$LOGS/review.tsv"; fi
  # The rest of the inventory, outside the delta packages: verdicts the gates and the device run settle.
  inv() { # <area> <verdict> <paths...>
    local area=$1 verdict=$2 c; shift 2
    c=$(git rev-list --count --no-merges "$U..$T_SHA" -- "$@")
    if [ "$c" = 0 ]; then printf '%s\t`%s`\tuntouched\tnone\n' "$area" "$*" >>"$LOGS/review.tsv"
    else printf '%s\t`%s`\t%s upstream commits\t%s\n' "$area" "$*" "$c" "$verdict" >>"$LOGS/review.tsv"; fi
  }
  inv 'Release steps the recipe mirrors' 'check on device (pack-tree.sh)' .github/workflows/release.yml scripts/release/verify-packed-install.ts scripts/build.ts
  inv 'Replay fixtures' 'check on device (M3/M6)' snapshots/session/bash-tool-turn snapshots/session/fs-write snapshots/session/fs-glob-sampling snapshots/session/pty-tools-sandbox-backend packages/test-support/llm-replay
  inv 'Glob / search argv' 'check in gates + on device (M6)' packages/fs/tool-fs-search
  inv 'flock platform' 'check in gates (native/system) + on device (M1)' native/system
  n=$(git diff "$U" "$T_SHA" -- packages native apps | grep -cE '^\+.*(assertBundlePlatform|NODE_PLATFORMS)' || true)
  printf 'Platform allow-lists\t`assertBundlePlatform` / `NODE_PLATFORMS`\t%s added lines\t%s\n' "$n" "$([ "$n" = 0 ] && echo none || echo 'check (latent: omits openharmony)')" >>"$LOGS/review.tsv"
  n=$(git diff --no-renames --name-only --diff-filter=A "$U" "$T_SHA" -- ':(glob)packages/*/*/package.json' | sed 's#/package.json##' | tr '\n' ' ')
  printf 'New packages\t`packages/`\t%s\tnone (outside the delta)\n' "${n:-none}" >>"$LOGS/review.tsv"
  say "range review: $REVIEW_ASK hit(s) need a decision ($(wc -l <"$LOGS/review.tsv") rows)"
}

# ---------------------------------------------------------------------------------------------------- §4 merge
merge_msg() { # writes the prepared merge message to stdout
  local n
  printf 'merge(hmos): %s into master\n\n' "$TAG"
  printf 'Upstream release %s (%s, %s tag; %s), merged with %s as the base, the last\nupstream commit master absorbed: %s upstream commits onto %s fork delta commits.%s\n\n' \
    "$TAG" "${T_SHA:0:12}" "$T_KIND" "$VERIFY_NOTE" "${U:0:12}" "$RANGE_N" "$DELTA_N" "${COVERED:+ Covers $COVERED.}"
  if [ -s "$LOGS/conflicts.tsv" ]; then
    printf 'Conflicts (skill hmos-upstream-merge section 4):\n'
    awk -F '\t' '{ r = $2; if (r ~ /^needs agent/) r = "TODO(agent): rule 3, how the HMOS behaviour was kept on upstream'"'"'s code"; print "- " $1 ": " r }' "$LOGS/conflicts.tsv"
  else printf 'Conflicts: none.\n'; fi
  n=$(grep -c $'\task' "$LOGS/review.tsv" || true)
  printf '\nRange review (scripts/openharmony/KNOWN-ISSUES.md section 1, src/ of the delta packages\nand the native pins): %s hit(s) needing a decision%s.\n' "$n" "$([ "$n" = 0 ] || echo ' (TODO(agent): one verdict each)')"
  awk -F '\t' '$4 ~ /^ask/ { print "- " $2 " " $3 ": TODO(agent) verdict" }' "$LOGS/review.tsv" | tr -d '`'
  printf '\nDelta (scripts/openharmony/delta-check.sh): A, R and X with reasons; X = the\nconflicted paths above whose delta lines changed. Gate and device evidence: the run report.\n'
}

LEFT=0
resolve_conflicts() { # applies rules 5, 1, 2, 4; writes conflicts.tsv; LEFT = the number left to an agent
  local p stages rule
  : >"$LOGS/conflicts.tsv"; : >"$LOGS/regen.lst"
  git diff --no-renames --name-only "$U" "$BASE_SHA" | sort >"$LOGS/delta-paths.lst"
  while IFS= read -r p; do
    stages=$(git ls-files -u -- "$p" | awk '{ print $3 }' | sort -u | tr -d '\n')
    rule=''
    if [[ $p =~ $OWNED_RE ]]; then
      if [[ $stages == *2* ]]; then git checkout -q --ours -- "$p"; git add -- "$p"; else git rm -q -- "$p"; fi
      rule='rule 5 (repository-owned: ours)'
    elif [[ $p == package.json || $p == */package.json ]] && [ "$stages" = 123 ] && rule1 "$p"; then
      rule='rule 1 (version fields: the tag'"'"'s; the other changes merged)'
    elif [[ $p =~ $GENERATED_RE ]]; then
      if [[ $stages == *3* ]]; then git checkout -q --theirs -- "$p"; git add -- "$p"; else git rm -q -- "$p"; fi
      echo "$p" >>"$LOGS/regen.lst"
      rule='rule 2 (generated: the tag'"'"'s side, regenerated after install)'
    elif ! grep -qxF "$p" "$LOGS/delta-paths.lst"; then
      if [[ $stages == *3* ]]; then git checkout -q --theirs -- "$p"; git add -- "$p"; else git rm -q -- "$p"; fi
      rule='rule 4 (outside the delta: the tag'"'"'s side)'
    else
      rule='needs agent (rule 3: keep the HMOS behaviour, re-expressed on upstream'"'"'s code)'
      LEFT=$((LEFT + 1))
    fi
    printf '`%s`\t%s\n' "$p" "$rule" >>"$LOGS/conflicts.tsv"
    say "conflict $p: $rule"
  done < <(git diff --name-only --diff-filter=U)
  # paths for the agent, kept for the resume (X candidates)
  awk -F '\t' '$2 ~ /^needs agent/ { gsub(/`/, "", $1); print $1 }' "$LOGS/conflicts.tsv" >"$LOGS/agent-paths.lst"
}

rule1() { # <package.json path>: version fields take the tag's value; anything else must merge cleanly
  local p=$1 d v rc=0
  d=$(mktemp -d)
  git show ":1:$p" >"$d/base"; git show ":2:$p" >"$d/ours"; git show ":3:$p" >"$d/theirs"
  for f in base ours theirs; do [ "$(grep -cE '^[[:space:]]*"version":' "$d/$f")" = 1 ] || rc=1; done
  if [ $rc = 0 ]; then
    v=$(grep -E '^[[:space:]]*"version":' "$d/theirs")
    for f in base ours; do
      V=$v awk '/^[[:space:]]*"version":/ { print ENVIRON["V"]; next } { print }' "$d/$f" >"$d/$f.n"
    done
    if git merge-file -p "$d/ours.n" "$d/base.n" "$d/theirs" >"$d/out" 2>/dev/null \
      && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$d/out" 2>/dev/null; then
      cp "$d/out" "$p"; git add -- "$p"
    else rc=1; fi
  fi
  rm -rf "$d"
  return $rc
}

if [ "$RESUMED" = 0 ]; then
  budget "the merge" disk   # review and merge are git only: no wait for other sessions' builds
  review_inventory
  STEP=merge
  say "worktree $WT on $BRANCH at $BASE_NAME (${BASE_SHA:0:12})"
  git worktree add -q -B "$BRANCH" "$WT" "$BASE_SHA"
  cd "$WT"
  mrc=0
  LEFTHOOK=0 git -c merge.conflictStyle=diff3 -c rerere.enabled=false merge --no-ff --no-commit -q "refs/tags/$TAG" \
    >"$LOGS/merge.log" 2>&1 || mrc=$?
  if [ "$mrc" != 0 ] && [ -z "$(git diff --name-only --diff-filter=U)" ]; then
    cat "$LOGS/merge.log" >&2; finish failed 1 "git merge failed without conflicts (log $LOGS/merge.log)."
  fi
  resolve_conflicts
  merge_msg >"$LOGS/merge-msg.txt"
  cp "$LOGS/merge-msg.txt" "$(git rev-parse --git-path MERGE_MSG)"
  if [ "$LEFT" -gt 0 ]; then
    finish conflicts 2 "In \`$WT\` (branch \`$BRANCH\`, merge in progress): resolve each path marked \"needs agent\" under Conflicts by skill hmos-upstream-merge section 4 rule 3 (keep the HMOS behaviour, re-expressed on upstream's new code; the files carry diff3 markers), and give every \"ask\" row under Review a verdict. \`git add\` the resolved paths, edit the prepared message (\`$(git rev-parse --git-path MERGE_MSG)\`: replace each TODO(agent) with the rule and the reason, the X paths included) and commit with \`LEFTHOOK=0 git commit --no-edit\`; non-mechanical follow-ups are their own commits. Do not push. Then re-run \`$(rerun_cmd)\` (or \`hmos-bundle run dsh --merge\` in homebrew-hmos): it resumes at the delta check."
  fi
  STEP="merge commit"
  LEFTHOOK=0 git commit -q --no-edit
  say "merge committed: $(git rev-parse --short=12 HEAD)"
  if [ "$REVIEW_ASK" -gt 0 ]; then
    finish review 2 "The merge applied (committed in \`$WT\`, branch \`$BRANCH\`), but the range review has $REVIEW_ASK hit(s) in src/ of the delta packages or the native pins that need a decision (rows marked \"ask\" under Review; KNOWN-ISSUES.md section 1 says why each area matters). Read each hit; where the HMOS behaviour needs carrying, add a \`fix(<pkg>): … for $TAG\` commit; record one verdict per hit in the merge commit body (\`git commit --amend\`, LEFTHOOK=0). A native pin drift is a maintainer question (skill §10). Do not push. Then re-run \`$(rerun_cmd)\`."
  fi
else
  cd "$WT"
  STEP=resume
  if [ -n "$(git diff --name-only --diff-filter=U)" ]; then
    [ -f "$LOGS/review.tsv" ] || review_inventory
    finish conflicts 2 "Still unmerged in \`$WT\`: $(git diff --name-only --diff-filter=U | tr '\n' ' '). Resolve them (rule 3), \`git add\`, edit the TODO(agent) lines of the prepared message and \`LEFTHOOK=0 git commit --no-edit\`; do not push; then re-run \`$(rerun_cmd)\`."
  fi
  if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
    say "committing the resolved merge"
    LEFTHOOK=0 git commit -q --no-edit
  fi
  git merge-base --is-ancestor "$T_SHA" HEAD \
    || finish diverged 2 "HEAD of \`$WT\` does not contain $TAG ($T_SHA): the worktree no longer carries the merge. Inspect it; if it is unusable, remove it (\`git worktree remove --force $WT\`, \`git branch -D $BRANCH\`) and re-run to start over."
  [ -f "$LOGS/review.tsv" ] || review_inventory
fi

# ---------------------------------------------------------------------------------------------------- §5 delta check
STEP="delta check"
cd "$WT"
st_set head "$(git rev-parse HEAD)"
MERGE_C=$(git rev-list --first-parent --merges --parents "$BASE_SHA..HEAD" | awk -v t="$T_SHA" '$3 == t { print $1 }' | tail -1)
[ -n "$MERGE_C" ] || finish diverged 2 "No merge commit with parents ($BASE_NAME, $TAG) on the first-parent line of \`$WT\`. Re-create the merge or remove the worktree and re-run."
RECORD=$(git log --first-parent --format=%B "$BASE_SHA..HEAD")
if printf '%s\n' "$RECORD" | grep -q 'TODO(agent)'; then
  printf 'Not run: the merge record still has TODO(agent) lines.\n' >"$LOGS/delta.txt"
  finish delta-check 2 "The merge record in \`$WT\` still has TODO(agent) placeholders (\`git log --first-parent $BASE_SHA..HEAD\`). Replace each with the rule and the reason (\`LEFTHOOK=0 git commit --amend\` on the merge commit, or reword it), then re-run \`$(rerun_cmd)\`."
fi
# X = delta paths an agent resolved or changed after the merge commit, named in the record. A, R and further X only from
# a decision written to <logs>/{A,R,X}.lst (each path named with its reason in the record, skill §5).
{ cat "$LOGS/agent-paths.lst" 2>/dev/null || true; git diff --no-renames --name-only "$MERGE_C" HEAD; cat "$LOGS/X.lst" 2>/dev/null || true; } \
  | sort -u >"$LOGS/x-candidates.lst"
: >"$LOGS/x-auto.lst"; unnamed=''
for kind in A R X; do
  f="$LOGS/x-candidates.lst"; [ "$kind" = X ] || f="$LOGS/$kind.lst"
  [ -s "$f" ] || continue
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if printf '%s\n' "$RECORD" | grep -qF "$p"; then [ "$kind" = X ] && echo "$p" >>"$LOGS/x-auto.lst"
    else unnamed+="$kind:$p "; fi
  done <"$f"
done
dargs=(--adapted "$LOGS/x-auto.lst")
[ -s "$LOGS/A.lst" ] && dargs+=(--added "$LOGS/A.lst")
[ -s "$LOGS/R.lst" ] && dargs+=(--dropped "$LOGS/R.lst")
drc=0
scripts/openharmony/delta-check.sh "${dargs[@]}" "refs/tags/$TAG" HEAD "$BASE_SHA" >"$LOGS/delta-check.log" 2>&1 || drc=$?
{
  printf -- '- result: `%s` (`%s`)\n' "$(tail -1 "$LOGS/delta-check.log")" "$LOGS/delta-check.log"
  printf -- '- A = %s\n' "$( [ -s "$LOGS/A.lst" ] && tr '\n' ' ' <"$LOGS/A.lst" || echo none)"
  printf -- '- R = %s\n' "$( [ -s "$LOGS/R.lst" ] && tr '\n' ' ' <"$LOGS/R.lst" || echo none)"
  printf -- '- X = %s\n' "$(awk '/adapted \(listed\)/ { printf "%s ", $3 }' "$LOGS/delta-check.log" | sed 's/ $//' | grep . || echo none)"
  grep -E '^  (MISSING|EXTRA|MISMATCH)' "$LOGS/delta-check.log" | sed 's/^  /- FAIL: /' || true
  for u in $unnamed; do
    case $u in X:*) awk -v p="${u#X:}" '$1 == "MISMATCH" && $2 == p { f = 1 } END { exit !f }' "$LOGS/delta-check.log" || continue ;; esac
    printf -- '- %s: changed or resolved by the agent but not named in the merge record, so not passed to the check\n' "$u"
  done
} >"$LOGS/delta.txt"
if [ "$drc" != 0 ]; then
  finish delta-check 2 "delta-check.sh FAILED in \`$WT\` (lines marked FAIL under Delta check; log \`$LOGS/delta-check.log\`). MISSING = a delta path the merge lost; EXTRA = a path the merge head adds beyond the tag; MISMATCH = the path's HMOS changed lines differ. Fix the merge (an adaptation commit), or, where the change is intended, name the path with its reason in the merge record: an X path (adapted hunks) is accepted once named; A (added) and R (dropped) are a maintainer decision (skill §10) and are passed through \`$LOGS/A.lst\` / \`$LOGS/R.lst\`. Do not push; re-run \`$(rerun_cmd)\`."
fi
say "delta-check PASS"

# ---------------------------------------------------------------------------------------------------- §6 gates
GATE_STOP=0 PRISTINE_OK=''
gate_rec() { printf '%s\t`%s`\t%s\t%s\t`%s`\n' "$1" "$2" "$3" "$4" "$5" >>"$LOGS/gates.tsv"; }
is_env() { # <rc> <log>: an out-of-memory kill or abort
  case $1 in 134|137) return 0 ;; esac
  grep -qE 'heap out of memory|JavaScript heap|^Killed|exit 13[47]\)' "$2"
}
sigs() { # <log> <root>: normalised failure signatures
  sed -e 's/\x1b\[[0-9;]*m//g' -e "s#$2/##g" "$1" | sed -nE \
    -e 's/^ FAIL +(.*[^ ])$/fail \1/p' \
    -e 's/^ERROR: Coverage for ([a-z]+) \([0-9.]+%\) does not meet .* for (.+)$/coverage \1 \2/p' \
    -e 's/^ +- FAILED (.+) \([0-9.]+s, exit [0-9]+\)$/gate \1/p' \
    -e 's/^([^ (]+)\([0-9]+,[0-9]+\): error (TS[0-9]+):.*/ts \1 \2/p' \
    -e 's/^✖ (.+) \([0-9.]+ms\)$/test \1/p' \
    -e 's/^([^ :]+):[0-9]+:[0-9]+: .*\[(Error|Warning)\/([^]]+)\]$/lint \1 \3/p' | LC_ALL=C sort -u
}
ensure_pristine() {
  [ -n "$PRISTINE_OK" ] && return "$PRISTINE_OK"
  PRISTINE_OK=1
  say "pristine worktree of $TAG for red classification"
  [ -d "$PRISTINE" ] || git -C "$REPO" worktree add -q --detach "$PRISTINE" "$T_SHA" || return 1
  budget "the pristine install"
  run_in "$PRISTINE" "$LOGS/pristine-install.log" 'pnpm install --frozen-lockfile --ignore-scripts' || return 1
  run_in "$PRISTINE" "$LOGS/pristine-native-system.log" 'pnpm run build:native-system' || return 1
  PRISTINE_OK=0
}
gate() { # <id> <command> [pristine-check]: run on the merge; a red is classified against the pristine tag
  local id=$1 cmd=$2 log="$LOGS/gate-$1.log" rc=0 prc=0 class subs line line_rc ok i
  budget "gate $id"
  STEP="gate $id"
  say "gate $id: $cmd"
  run_in "$WT" "$log" "$cmd" || rc=$?
  if [ "$rc" = 0 ]; then gate_rec "$id" "$cmd" 0 green "$log"; return 0; fi
  if is_env "$rc" "$log"; then
    # Out of memory: run-gates sub-gates that died alone are re-run one by one; otherwise the gate is re-run once.
    subs=$(sed -e 's/\x1b\[[0-9;]*m//g' "$log" | awk '/- FAILED .*exit [0-9]+\)$/ { e = $NF; sub(/\)$/, "", e); getline c; sub(/^ +/, "", c); print e "\t" c }')
    if [ -n "$subs" ] && ! printf '%s\n' "$subs" | cut -f1 | grep -qvE '^13[47]$'; then
      ok='' i=0
      while IFS=$'\t' read -r line_rc line; do
        i=$((i + 1)); budget "gate $id (alone: $line)"
        line_rc=0; run_in "$WT" "$log.alone-$i" "${cmd%%pnpm run*}$line" || line_rc=$?
        [ "$line_rc" = 0 ] || [ -n "$ok" ] || { ok="$log.alone-$i"; rc=$line_rc; }
      done <<<"$subs"
      if [ -z "$ok" ]; then gate_rec "$id" "$cmd" 0 "environment (OOM; the failed sub-gates green alone)" "$log"; return 0; fi
      log=$ok
    else
      budget "gate $id (retry)"
      rc=0; run_in "$WT" "$log.retry" "$cmd" || rc=$?
      log="$log.retry"
      if [ "$rc" = 0 ]; then gate_rec "$id" "$cmd" 0 "environment (OOM; green on the retry)" "$log"; return 0; fi
    fi
    if is_env "$rc" "$log"; then gate_rec "$id" "$cmd" "$rc" "environment (OOM after the retry)" "$log"; GATE_STOP=1; return 0; fi
  fi
  # Red: the same gate on the pristine tag (skill §6). Red there too with no new failure = upstream.
  if ! ensure_pristine; then gate_rec "$id" "$cmd" "$rc" "unclassified (pristine worktree failed)" "$log"; GATE_STOP=1; return 0; fi
  if [ -n "${3:-}" ] && ! (cd "$PRISTINE" && bash -c "$3") >/dev/null 2>&1; then
    gate_rec "$id" "$cmd" "$rc" "adaptation (the gate has no counterpart on the tag)" "$log"; GATE_STOP=1; return 0
  fi
  budget "gate $id on the pristine tag"
  run_in "$PRISTINE" "$LOGS/pristine-$id.log" "$cmd" || prc=$?
  if [ "$prc" = 0 ]; then
    class=adaptation; GATE_STOP=1
  else
    sigs "$log" "$WT" >"$LOGS/sigs-$id.merge"; sigs "$LOGS/pristine-$id.log" "$PRISTINE" >"$LOGS/sigs-$id.pristine"
    if [ ! -s "$LOGS/sigs-$id.merge" ]; then class="upstream (red on the tag too, exit $prc)"
    elif [ -z "$(LC_ALL=C comm -23 "$LOGS/sigs-$id.merge" "$LOGS/sigs-$id.pristine")" ]; then
      class="upstream (red on the tag too: $(wc -l <"$LOGS/sigs-$id.merge") failure(s), all on the tag)"
    else
      class="adaptation ($(LC_ALL=C comm -23 "$LOGS/sigs-$id.merge" "$LOGS/sigs-$id.pristine" | wc -l) failure(s) only on the merge: $LOGS/sigs-$id.merge)"; GATE_STOP=1
    fi
  fi
  gate_rec "$id" "$cmd" "$rc" "$class" "$log"
}

regenerate() { # rule 2 follow-up: the lockfile and i18n records the conflict rules took from the tag
  [ -s "$LOGS/regen.lst" ] || return 0
  if grep -qxE '(.*/)?pnpm-lock\.yaml' "$LOGS/regen.lst"; then
    budget "the lockfile regeneration"; STEP="regenerate pnpm-lock.yaml"
    run_in "$WT" "$LOGS/regen-lockfile.log" 'pnpm install --lockfile-only --ignore-scripts' || finish failed 1
    if [ -n "$(git status --porcelain -- pnpm-lock.yaml)" ]; then
      git add pnpm-lock.yaml; LEFTHOOK=0 git commit -q -m "chore(deps): regenerate pnpm-lock.yaml for $TAG"
    fi
  fi
}
regenerate_i18n() {
  [ -s "$LOGS/regen.lst" ] || return 0
  local p md
  STEP="regenerate i18n records"
  while IFS= read -r p; do
    case $p in *.i18n.yaml) md=${p%.i18n.yaml}.md ;; *) continue ;; esac
    [ -f "$md" ] || continue
    run_in "$WT" "$LOGS/regen-i18n.log" "pnpm run verify-translation-pairing --write '$md'" || finish failed 1
  done <"$LOGS/regen.lst"
  if [ -n "$(git status --porcelain -- '*.i18n.yaml')" ]; then
    git add -- '*.i18n.yaml'; LEFTHOOK=0 git commit -q -m 'chore(docs): regenerate i18n records'
  fi
  : >"$LOGS/regen.lst"
}

STEP=gates
HEAD_SHA=$(git rev-parse HEAD)
if [ "$(st_get gates_green)" = "$HEAD_SHA" ] && [ -s "$LOGS/gates.tsv" ]; then
  say "gates already green for ${HEAD_SHA:0:12} in an earlier run of this worktree"
else
  : >"$LOGS/gates.tsv"
  regenerate
  budget "install"; STEP=install
  run_in "$WT" "$LOGS/install.log" 'pnpm install --frozen-lockfile --ignore-scripts' \
    || finish gates 2 "\`pnpm install --frozen-lockfile --ignore-scripts\` failed in \`$WT\` (log \`$LOGS/install.log\`): the merged lockfile and manifests disagree. Regenerate the lockfile (\`pnpm install --lockfile-only --ignore-scripts\`), commit, re-run \`$(rerun_cmd)\`."
  gate_rec install 'pnpm install --frozen-lockfile --ignore-scripts' 0 green "$LOGS/install.log"
  regenerate_i18n
  HEAD_SHA=$(git rev-parse HEAD)
  # A fresh worktree installed with --ignore-scripts has no host flock addon (session-persistence-jsonl needs it).
  budget "the host flock addon"; STEP="host flock addon"
  run_in "$WT" "$LOGS/native-system-host.log" 'pnpm run build:native-system' || finish failed 1
  gate typecheck 'DSH_GATE_CONCURRENCY=1 pnpm run typecheck'
  git diff --no-renames --name-only --diff-filter=d "refs/tags/$TAG" HEAD \
    | grep -E '\.(ts|tsx|mts|cts|mjs)$' | grep -vE '^vendor/[^/]+/src/' >"$LOGS/lint-paths.lst" || true
  if [ -s "$LOGS/lint-paths.lst" ]; then
    gate lint "mapfile -t P < <(while read -r p; do [ -e \"\$p\" ] && echo \"\$p\"; done <'$LOGS/lint-paths.lst'); [ \${#P[@]} -gt 0 ] || exit 0; pnpm exec tsx scripts/run-oxlint.ts --format=unix \"\${P[@]}\""
  fi
  # Tests of every delta package with source in the delta, plus the inventory packages the range touched.
  mapfile -t PKGS < <({ git diff --no-renames --name-only "refs/tags/$TAG" HEAD | sed -nE 's#^(packages/[^/]+/[^/]+)/src/.*#\1#p'
                        [ "$(git rev-list --count --no-merges "$U..$T_SHA" -- packages/fs/tool-fs-search/src)" = 0 ] || echo packages/fs/tool-fs-search; } | sort -u)
  for p in "${PKGS[@]}"; do
    gate "test-${p##*/}" "pnpm exec vitest run $p --coverage --coverage.include='$p/src/**/*.ts'" "test -d $p"
  done
  if git diff --quiet "refs/tags/$TAG" HEAD -- native/system; then :; else
    # The flock tests need the C oracle; its script builds glibc first and then fails without musl-gcc (oh-vm).
    gate native-system 'cd native/system && { node ./scripts/build-test-oracle.mjs || true; } && node --test ./test/flock.test.js ./test/package-matrix.test.js ./test/release-packing.test.js'
  fi
  gate doc-sync 'NODE_OPTIONS=--max-old-space-size=4096 DSH_GATE_CONCURRENCY=1 pnpm run doc-sync'
  gate docs-gate 'python3 scripts/docs-gate.py' 'test -f scripts/docs-gate.py'
  if [ -d "$PRISTINE" ]; then git -C "$REPO" worktree remove --force "$PRISTINE" || say "could not remove $PRISTINE"; fi
  if [ "$GATE_STOP" = 1 ]; then
    finish gates 2 "A gate is red on the merge only (\"adaptation\") or ran out of memory twice (\"environment\"); see Gates, each with its log, and for adaptation the failures the tag does not have (\`$LOGS/sigs-<gate>.merge\` vs \`.pristine\`). Fix an adaptation red in \`$WT\` with a \`fix(<pkg>): … for $TAG\` commit (two failed attempts: ask, skill §10); an environment red needs a quieter machine. Do not push; re-run \`$(rerun_cmd)\`."
  fi
  st_set gates_green "$HEAD_SHA"
fi

# ---------------------------------------------------------------------------------------------------- §7 device
STEP=device
: >"$LOGS/device.txt"
dev() { printf '%s\n' "$*" >>"$LOGS/device.txt"; }
dev "root=$OHROOT owner=$OWNER host=$HOSTALIAS head=$HEAD_SHA"
"$OH_SSH" -o BatchMode=yes -o ConnectTimeout=15 "$HOSTALIAS" true 2>"$LOGS/device-ssh.log" \
  || { dev "ssh $HOSTALIAS: unreachable ($(head -1 "$LOGS/device-ssh.log"))"; finish device 2 "\`ssh $HOSTALIAS\` fails: sshd on the PC is down or the PC is off (KNOWN-ISSUES.md §2). Only the maintainer can restore it (\`restore-ssh.sh\` in HiShell). Then re-run \`$(rerun_cmd)\`."; }
changed=$(git diff --name-only "$BASE_SHA" HEAD -- "${DEVICE_REVIEW[@]}" | tr '\n' ' ')
if [ -n "$changed" ] && [ "$(cat "$LOGS/device-reviewed" 2>/dev/null)" != "$HEAD_SHA" ]; then
  dev "recipe scripts changed on the merge branch: $changed"
  finish device 2 "The merge branch changes $changed: skill §7 asks for a review before they run on the device. Review \`git diff $BASE_SHA HEAD -- $changed\` in \`$WT\`; when it is safe, write the head sha (\`git rev-parse HEAD > $LOGS/device-reviewed\`) and re-run \`$(rerun_cmd)\`."
fi
# M5 (deploy from an empty root) when the recipe changed since the last merge of an upstream tag (METRICS.md): that merge
# is the oldest first-parent commit of the base that already contains U.
prev=''
while read -r c; do git merge-base --is-ancestor "$U" "$c" || break; prev=$c; done < <(git rev-list --first-parent "$BASE_SHA")
M5=1
if [ -n "$prev" ] && git diff --quiet "$prev" HEAD -- scripts/openharmony ':!scripts/openharmony/*.md' \
  ':!scripts/openharmony/*.i18n.yaml' ':!scripts/openharmony/delta-check.sh' ':!scripts/openharmony/upstream-merge.sh'; then M5=0; fi
R=$WT/scripts/openharmony
export DSH_OH_ROOT=$OHROOT DSH_OH_OWNER=$OWNER OH_WAIT_MAX=$WAIT_MAX OH_WAIT_STEP=$WAIT_STEP
recipe() { # <name> <log> <command...>
  local name=$1 log=$2 rc=0 s; shift 2; s=$(date +%s)
  STEP="device $name"; say "device $name"
  "$@" >"$log" 2>&1 </dev/null || rc=$?
  dev "$name exit=$rc wall=$(( $(date +%s) - s ))s log=$log"
  [ "$rc" = 75 ] && finish busy 75 "The device recipe waited too long for the machine during $name (OH_WAIT_MAX=$WAIT_MAX); re-run \`$(rerun_cmd)\`."
  [ "$rc" = 0 ] || finish device 2 "The device recipe failed at $name (log \`$log\`). Compare with KNOWN-ISSUES.md §2/§3: a known environment cause → fix it and re-run \`$(rerun_cmd)\`; anything else is new: stop and ask (skill §10), do not retry blindly."
}
budget "the device recipe"
recipe build-natives "$LOGS/device-build-natives.log" "$R/build-natives.sh" "$WT" "$OUTDIR/natives"
recipe make-node "$LOGS/device-make-node.log" "$R/make-node.sh" "${DEVICE_CLT:-/mnt/linux_share/storage/Users/currentUser/hmos-clt/command-line-tools}/node/bin/node" "$OUTDIR/node"
budget "pack-tree"
recipe pack-tree "$LOGS/device-pack-tree.log" env OH_BUILD_ARGS=--serial "$R/pack-tree.sh" "$WT" "$OUTDIR/natives" "$OUTDIR"
tc=$(cat "$OUTDIR/tree/oh/dsh-commit.txt" 2>/dev/null || true)
[ "$tc" = "$HEAD_SHA" ] || finish device 2 "The packed tree records commit '$tc', not the merged head $HEAD_SHA (uncommitted changes in \`$WT\`?). Commit, then re-run \`$(rerun_cmd)\`."
if [ "$M5" = 1 ]; then
  STEP="device M5 empty root"
  say "M5: the recipe changed since ${prev:0:12}; deploying from an empty $OHROOT"
  # shellcheck disable=SC2029 # OHROOT/OWNER are validated by deploy.sh's rules: expand them here, on purpose
  r=$("$OH_SSH" "$HOSTALIAS" "if [ ! -e '$OHROOT' ]; then echo absent; elif [ \"\$(cat '$OHROOT/.owner' 2>/dev/null)\" = '$OWNER' ]; then rm -rf '$OHROOT' && echo removed; else echo foreign; fi")
  dev "M5 root before deploy: $r"
  [ "$r" = foreign ] && finish device 2 "$OHROOT exists without the owner marker '$OWNER'; refusing to empty it for M5. Pick another DSH_OH_ROOT or have its owner remove it."
fi
recipe deploy "$LOGS/device-deploy.log" "$R/deploy.sh" "$OUTDIR/tree" "$OUTDIR/node" "$HOSTALIAS"
STEP="device smoke"; say "device smoke --m3 --m6"
src=0; s=$(date +%s)
"$R/smoke.sh" --m3 --m6 "$HOSTALIAS" >"$LOGS/device-smoke.log" 2>&1 </dev/null || src=$?
dev "smoke exit=$src wall=$(( $(date +%s) - s ))s log=$LOGS/device-smoke.log"
grep -E '^M[0-9]' "$LOGS/device-smoke.log" | grep -vE '^M[0-9] [a-z-]+ (stderr|file):|^M[0-9] stdout:|M[36]-(TOOL|LOG)|^M6 TERM |^M1 SMOKE ' >>"$LOGS/device.txt" || true
need=("^M0 device: .* commit=$HEAD_SHA\$" '^M1 SMOKE-SUMMARY ok=5 fail=0' '^M2 exit=0 no-usable-native-binding=no'
  '^M3 bash-tool-turn verdict=ok' '^M3 fs-write verdict=ok' '^M6 rg verdict=ok' '^M6 fs-glob-sampling verdict=ok'
  '^M6 pty-tools-sandbox-backend verdict=ok' '^M6 TERM-SUMMARY ok=8 fail=0' '^M6 terminal verdict=ok' '^M6 sharp ok'
  '^M6 web verdict=ok')
missing=''
for re in "${need[@]}"; do grep -qE "$re" "$LOGS/device-smoke.log" || missing+="${re#^} | "; done
[ "$M5" = 1 ] && dev "M5 $([ -z "$missing" ] && [ "$src" = 0 ] && echo ok || echo fail) (deployed from an empty root)"
if [ "$src" != 0 ] || [ -n "$missing" ]; then
  dev "FAIL: smoke exit=$src; missing: ${missing% | }"
  finish device 2 "The device check did not pass on $OHROOT (smoke exit $src; lines missing or not ok: ${missing% | }; log \`$LOGS/device-smoke.log\`). Compare with KNOWN-ISSUES.md §2; a failure listed there has its fix; anything else is new: stop and ask (skill §10)."
fi
dev "PASS: M0 commit = head; M1, M2, M3, M6$([ "$M5" = 1 ] && echo ', M5') ok"

# ---------------------------------------------------------------------------------------------------- §8 push, cleanup
HEAD12=$(git rev-parse --short=12 HEAD)
if [ "$NO_PUSH" = 0 ]; then
  STEP=push
  git fetch -q origin
  git merge-base --is-ancestor refs/remotes/origin/master HEAD \
    || finish diverged 2 "origin/master moved and is no longer an ancestor of the merge head: merge origin/master into \`$WT\` (skill §8), re-run the affected gates, then re-run \`$(rerun_cmd)\`."
  budget push; STEP=push
  say "push HEAD:master (pre-push typecheck runs; fast-forward only)"
  DSH_GATE_CONCURRENCY=1 git push origin HEAD:refs/heads/master >"$LOGS/push.log" 2>&1 \
    || finish failed 1 "\`git push origin HEAD:master\` failed (log \`$LOGS/push.log\`); the worktree is kept, re-run \`$(rerun_cmd)\` to resume."
  FINAL=pushed
else
  FINAL=merged-unpushed
fi
STEP=cleanup
cd "$REPO"
git worktree remove --force "$WT" || say "could not remove $WT"
git branch -q -D "$BRANCH" 2>/dev/null || true
[ -d "$PRISTINE" ] && { git worktree remove --force "$PRISTINE" || true; }
rm -rf "$OUTDIR"
if [ "$FINAL" = pushed ]; then
  NEXT="Nothing for the merge: \`master\` carries $TAG at $HEAD12 (pushed fast-forward). Record it in the fork's local issue (link this report). The release is the maintainer's \`scripts/hmos-bundle run dsh\` in homebrew-hmos."
else
  NEXT="Merged and verified without a push (--no-push${BASE_ARG:+ / --base $BASE_ARG}); the head $HEAD12 is no longer on a branch (the worktree and $BRANCH are removed)."
fi
finish "$FINAL" 0
