#!/usr/bin/env bash
# Check out the module repos listed in repos.conf into the hub.
#
#   ./scripts/bootstrap.sh                       clone core repos, ask about each infra repo
#   ./scripts/bootstrap.sh --link ~/workspace    symlink existing clones instead (clone if missing)
#   ./scripts/bootstrap.sh --infra all|none|ask  skip the infra prompt
#
# Idempotent: a path that already exists is never touched. Written for bash 3.2 (macOS default).
set -euo pipefail

HUB="$(cd "$(dirname "$0")/.." && pwd)"
CONF="$HUB/repos.conf"
LINK_DIR=""
INFRA=""

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --link) LINK_DIR="${2:?--link needs a directory}"; shift 2 ;;
    --infra) INFRA="${2:?--infra needs all|none|ask}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done

if [ -z "$INFRA" ]; then
  # Never block a non-interactive caller (CI, an agent) on a prompt.
  if [ -t 0 ]; then INFRA=ask; else INFRA=none; fi
fi
case "$INFRA" in all|none|ask) ;; *) echo "--infra must be all, none or ask" >&2; exit 1 ;; esac

if [ -n "$LINK_DIR" ]; then
  LINK_DIR="$(cd "$LINK_DIR" && pwd)"
fi

SUMMARY=""
record() { SUMMARY="${SUMMARY}$(printf '%-20s %-9s %s' "$1" "$2" "$3")"$'\n'; }

branch_of() { git -C "$1" symbolic-ref --short -q HEAD 2>/dev/null || echo "(detached)"; }

checkout() {
  local path="$1" url="$2" dest="$HUB/$1" name
  name="$(basename "$url" .git)"
  mkdir -p "$(dirname "$dest")"
  if [ -n "$LINK_DIR" ] && [ -d "$LINK_DIR/$name/.git" ]; then
    ln -s "$LINK_DIR/$name" "$dest"
    record "$path" linked "$(branch_of "$dest") -> $LINK_DIR/$name"
  else
    git clone -q "$url" "$dest" </dev/null
    record "$path" cloned "$(branch_of "$dest")"
  fi
}

wants_infra() {
  local name="$1" answer
  case "$INFRA" in
    all) return 0 ;;
    none) return 1 ;;
  esac
  printf 'Check out %s? [y/N] ' "$name" >&2
  read -r answer || answer=""
  case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# repos.conf is read on fd 3 so the infra prompt can read the user's answer on stdin.
while read -r path url group <&3; do
  case "$path" in ''|'#'*) continue ;; esac
  if [ -e "$HUB/$path" ] || [ -L "$HUB/$path" ]; then
    record "$path" present "$(branch_of "$HUB/$path")"
    continue
  fi
  if [ "$group" = infra ] && ! wants_infra "$(basename "$url" .git)"; then
    record "$path" skipped "-"
    continue
  fi
  checkout "$path" "$url"
done 3<"$CONF"

# Symlinked repos resolve outside the hub: tell Claude Code about their real location so it
# doesn't prompt on every file. Merged into settings.local.json (gitignored) to keep other keys.
targets=""
while read -r path _ _ <&3; do
  case "$path" in ''|'#'*) continue ;; esac
  if [ -L "$HUB/$path" ]; then
    targets="${targets}$(cd "$HUB/$path" && pwd -P)"$'\n'
  fi
done 3<"$CONF"

if [ -n "$targets" ]; then
  if command -v python3 >/dev/null; then
    # shellcheck disable=SC2086  # one target per word, paths contain no spaces
    python3 -c '
import json, os, sys
path, targets = sys.argv[1], sys.argv[2:]
settings = {}
if os.path.exists(path):
    with open(path) as f:
        settings = json.load(f)
dirs = settings.setdefault("permissions", {}).setdefault("additionalDirectories", [])
dirs.extend(t for t in targets if t not in dirs)
with open(path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
' "$HUB/.claude/settings.local.json" $targets
    echo "Updated .claude/settings.local.json with symlink targets." >&2
  else
    echo "python3 not found: add these to permissions.additionalDirectories in .claude/settings.local.json:" >&2
    printf '  %s\n' $targets >&2
  fi
fi

echo
printf '%-20s %-9s %s\n' PATH STATE BRANCH
printf '%s' "$SUMMARY"
