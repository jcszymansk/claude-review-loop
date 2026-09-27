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
# 1. The nearest loop whose session_id is this session wins.
# 2. Otherwise a loop in <start-dir> itself is used whatever its owner, as
#    before sessions were recorded: /clear starts a new session id, and older
#    or unreadable state has no owner, but the loop there must still run and
#    stay cancellable.
#
# The walk stops at a directory holding `.git`: a git worktree (Claude Code
# puts them under <repo>/.claude/worktrees/) or a nested repository is a
# checkout of its own and must not review its parent's files.
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

if [ -n "$session_id" ]; then
  candidate="$dir"
  while :; do
    state_file="${candidate%/}/$STATE_PATH"
    if [ -f "$state_file" ] && [ "$(state_owner "$state_file")" = "$session_id" ]; then
      printf '%s\n' "$candidate"
      exit 0
    fi
    if [ -e "${candidate%/}/.git" ] || [ "$candidate" = "/" ]; then
      break
    fi
    candidate="${candidate%/*}"
    [ -n "$candidate" ] || candidate="/"
  done
fi

if [ -f "${dir%/}/$STATE_PATH" ]; then
  printf '%s\n' "$dir"
  exit 0
fi
exit 1
