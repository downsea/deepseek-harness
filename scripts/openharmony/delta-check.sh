#!/usr/bin/env bash
# delta-check.sh: does an upstream-merge head carry the HMOS delta onto an upstream release tag?
#
# Usage: delta-check.sh [--added <file>] [--dropped <file>] [--adapted <file>] <tag> [<head> [<master>]]
#   <tag>      the upstream release tag being merged (e.g. dsh-v0.2.2-alpha.2)
#   <head>     the merge head (default HEAD)
#   <master>   the master the merge goes onto (default origin/master, else master)
#   --added    paths the merge adds to the delta for this release (A), one per line
#   --dropped  paths the merge drops from the delta because upstream adopted the change (R), one per line
#   --adapted  paths whose delta lines changed on purpose (adapted hunks), one per line
#
# Reference delta D = git diff U <master>, with U = merge-base(<master>, <tag>) (the upstream commit master last
# absorbed). Candidate delta D' = git diff <tag> <head>. PASS iff
#   1. <tag> and <master> are ancestors of <head>, and a merge commit with parents (<master>, <tag>) is in <head>;
#   2. paths(D') = paths(D) + A - R: nothing else differs from the tag;
#   3. per common path, the sorted changed lines (git diff -U0, +/- lines, no context) are equal in D and D', after
#      three named noise filters: "version" lines in package.json, 16-hex en:/zh: hash lines in *.i18n.yaml, and
#      pnpm-lock.yaml as a whole; every other mismatch must be listed with --adapted.
# Every listed A, R and adapted path needs a reason in the merge record. Exit 0 PASS, 1 FAIL, 2 usage.
# Step 5 of skill hmos-upstream-merge (.agents/skills/hmos-upstream-merge/SKILL.md).
set -euo pipefail
ADDED=/dev/null DROPPED=/dev/null ADAPTED=/dev/null
while [ $# -gt 0 ]; do
  case $1 in
    --added) ADDED=$2; shift 2 ;;
    --dropped) DROPPED=$2; shift 2 ;;
    --adapted) ADAPTED=$2; shift 2 ;;
    -h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) break ;;
  esac
done
[ $# -ge 1 ] && [ $# -le 3 ] || { sed -n '4p' "$0" | sed 's/^# //' >&2; exit 2; }
TAG=$1 HEADREF=${2:-HEAD}
if [ -n "${3:-}" ]; then MASTER=$3
elif git rev-parse -q --verify refs/remotes/origin/master >/dev/null; then MASTER=refs/remotes/origin/master
else MASTER=refs/heads/master; fi
T=$(git rev-parse "$TAG^{commit}") H=$(git rev-parse "$HEADREF^{commit}") M=$(git rev-parse "$MASTER^{commit}")
U=$(git merge-base "$M" "$T")
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0

echo "delta-check tag=$TAG ($T) head=$H master=$M base U=$U"
git merge-base --is-ancestor "$T" "$H" || { echo "ancestry: FAIL  $TAG is not an ancestor of head"; fail=1; }
git merge-base --is-ancestor "$M" "$H" || { echo "ancestry: FAIL  master is not an ancestor of head"; fail=1; }
if git rev-list --merges --parents "$M..$H" | awk -v m="$M" -v t="$T" '$2 == m && $3 == t { f = 1 } END { exit !f }'; then
  echo "ancestry: ok    merge commit with parents (master, $TAG) present"
else
  echo "ancestry: FAIL  no merge commit with parents (master, $TAG) in master..head"; fail=1
fi

git diff --no-renames --name-only "$U" "$M" | sort >"$W/d"
git diff --no-renames --name-only "$T" "$H" | sort >"$W/d2"
sort -u "$ADDED" >"$W/a"; sort -u "$DROPPED" >"$W/r"; sort -u "$ADAPTED" >"$W/x"
comm -23 "$W/d" "$W/d2" >"$W/missing"   # in the delta, not in the merge head
comm -13 "$W/d" "$W/d2" >"$W/extra"     # in the merge head, not in the delta
echo "paths: D=$(wc -l <"$W/d") D'=$(wc -l <"$W/d2") missing=$(wc -l <"$W/missing") extra=$(wc -l <"$W/extra")"
while IFS= read -r p; do
  if grep -qxF "$p" "$W/r"; then echo "  dropped (listed R)  $p"; else echo "  MISSING             $p"; fail=1; fi
done <"$W/missing"
while IFS= read -r p; do
  if grep -qxF "$p" "$W/a"; then echo "  added (listed A)    $p"; else echo "  EXTRA               $p"; fail=1; fi
done <"$W/extra"

lines() { # <from> <to> <path>: sorted changed lines after the noise filters
  git diff --no-renames -U0 "$1" "$2" -- "$3" \
    | grep -E '^[+-]' | grep -vE '^(\+\+\+|---) (a/|b/|/dev/null)' \
    | { case $3 in
          */package.json|package.json) grep -vE '^[+-][[:space:]]*"version":' ;;
          *.i18n.yaml) grep -vE '^[+-][[:space:]]*(en|zh): [0-9a-f]{16}$' ;;
          *) cat ;;
        esac; } | LC_ALL=C sort || true
}
mism=0
while IFS= read -r p; do
  case $p in pnpm-lock.yaml|*/pnpm-lock.yaml) continue ;; esac
  lines "$U" "$M" "$p" >"$W/l1"; lines "$T" "$H" "$p" >"$W/l2"
  cmp -s "$W/l1" "$W/l2" && continue
  mism=$((mism + 1))
  only_d=$(LC_ALL=C comm -23 "$W/l1" "$W/l2" | wc -l); only_d2=$(LC_ALL=C comm -13 "$W/l1" "$W/l2" | wc -l)
  if grep -qxF "$p" "$W/x"; then echo "  adapted (listed)    $p  (-$only_d delta lines, +$only_d2 merge lines)"
  else echo "  MISMATCH            $p  (-$only_d delta lines, +$only_d2 merge lines)"; fail=1; fi
done < <(comm -12 "$W/d" "$W/d2")
echo "changed-line mismatches: $mism (filters: package.json version, *.i18n.yaml hashes, pnpm-lock.yaml)"
if [ "$fail" = 0 ]; then echo "delta-check: PASS"; else echo "delta-check: FAIL"; fi
exit "$fail"
