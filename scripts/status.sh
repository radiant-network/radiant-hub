#!/usr/bin/env bash
# Show branch and state of every checked-out repo in repos.conf.
#
#   ./scripts/status.sh          branch, dirty, ahead/behind upstream
#   ./scripts/status.sh --pull   also `git pull --ff-only` every clean repo
set -euo pipefail

HUB="$(cd "$(dirname "$0")/.." && pwd)"
PULL=false
[ "${1:-}" = "--pull" ] && PULL=true

printf '%-20s %-40s %-7s %s\n' PATH BRANCH STATE UPSTREAM
while read -r path _ _ <&3; do
  case "$path" in ''|'#'*) continue ;; esac
  dir="$HUB/$path"
  [ -d "$dir/.git" ] || [ -f "$dir/.git" ] || continue

  branch="$(git -C "$dir" symbolic-ref --short -q HEAD || echo '(detached)')"
  if [ -n "$(git -C "$dir" status --porcelain)" ]; then state=dirty; else state=clean; fi

  if $PULL && [ "$state" = clean ]; then
    git -C "$dir" pull -q --ff-only </dev/null || state=pull-failed
  fi

  upstream="-"
  if counts="$(git -C "$dir" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null)"; then
    set -- $counts
    upstream="behind $1, ahead $2"
  fi
  printf '%-20s %-40s %-7s %s\n' "$path" "$branch" "$state" "$upstream"
done 3<"$HUB/repos.conf"
