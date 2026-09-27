#!/usr/bin/env bash
# Usage: find-loop-root.sh <start-dir> [session-id]
#
# Prints the directory of the review loop that a Claude Code session in
# <start-dir> belongs to, and exits 1 when there is none.
#
# Claude Code runs the Stop hook in the session's current directory, which
# follows the main agent's last `cd`, so the loop can live in a parent of
# <start-dir>. Walking up is only safe for loops this session owns: another
# session may run its own loop in a parent directory.
#
#   /repo/.claude/review-loop.local.json      session_id = A
#   /repo/sub/.claude/review-loop.local.json  session_id = B
#   /repo/sub/dir                             <start-dir>
#
#   session A -> /repo      session B -> /repo/sub      other -> none
#
# A state file in <start-dir> itself is used unless it names a different
# session; state without an owner (older setups, unreadable files) is only
# used from its own directory, where the hook can still report its problems.
set -euo pipefail

STATE_PATH=".claude/review-loop.local.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

start_dir="${1:-}"
if [ -z "$start_dir" ]; then
  echo "Usage: find-loop-root.sh <start-dir> [session-id]" >&2
  exit 2
fi
session_id="$("$SCRIPT_DIR/normalize-session-id.sh" "${2:-}")"

if ! dir="$(cd "$start_dir" 2>/dev/null && pwd)"; then
  echo "Error: cannot enter $start_dir" >&2
  exit 2
fi

state_owner() {
  local state_file="$1"
  local owner=""

  if command -v jq >/dev/null 2>&1; then
    owner=$(jq -r 'if type == "object" and (.session_id | type == "string") then .session_id else "" end' \
      "$state_file" 2>/dev/null || true)
  fi
  "$SCRIPT_DIR/normalize-session-id.sh" "$owner"
}

candidate="$dir"
while :; do
  state_file="${candidate%/}/$STATE_PATH"
  if [ -f "$state_file" ]; then
    owner="$(state_owner "$state_file")"
    if [ "$candidate" = "$dir" ]; then
      if [ -z "$owner" ] || [ -z "$session_id" ] || [ "$owner" = "$session_id" ]; then
        printf '%s\n' "$candidate"
        exit 0
      fi
    elif [ -n "$owner" ] && [ "$owner" = "$session_id" ]; then
      printf '%s\n' "$candidate"
      exit 0
    fi
  fi
  [ "$candidate" = "/" ] && break
  candidate="${candidate%/*}"
  [ -n "$candidate" ] || candidate="/"
done
exit 1
