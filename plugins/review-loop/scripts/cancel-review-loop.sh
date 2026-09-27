#!/usr/bin/env bash
# Usage: cancel-review-loop.sh [session-id]
#
# Cancels the review loop that the session in the current directory belongs
# to: the loop registered for the session, or else the loop in the current
# directory (see find-loop-root.sh). Its registry entry is removed too.
set -u

STATE_FILE=".claude/review-loop.local.json"
PID_FILE=".claude/review-loop-child.pid"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STOP_TREE_SCRIPT="$SCRIPT_DIR/stop-process-tree.sh"

if loop_root="$("$SCRIPT_DIR/find-loop-root.sh" "$PWD" "${1:-}" 2>/dev/null)"; then
  if ! cd "$loop_root"; then
    printf 'Error: cannot enter the review loop directory %s\n' "$loop_root" >&2
    exit 1
  fi
fi

runtime_files=(
  "$STATE_FILE"
  ".claude/review-loop.lock"
  ".claude/review-loop-run-codex.sh"
  ".claude/review-loop-run-cursor.sh"
  ".claude/review-loop-run-claude.sh"
  ".claude/review-loop-codex-prompt.txt"
  ".claude/review-loop-cursor-prompt.txt"
  ".claude/review-loop-claude-prompt.txt"
  ".claude/review-loop-retries"
  ".claude/review-loop-timed-out"
  "$PID_FILE"
)

valid_pid() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -gt 1 ] 2>/dev/null
}

state_present=false
phase="unknown"
review_id="unknown"
owner=""
if [ -f "$STATE_FILE" ]; then
  state_present=true
  if command -v jq >/dev/null 2>&1; then
    phase=$(jq -r '.phase // "unknown"' "$STATE_FILE" 2>/dev/null || printf 'unknown')
    review_id=$(jq -r '.review_id // "unknown"' "$STATE_FILE" 2>/dev/null || printf 'unknown')
    owner=$(jq -r 'if type == "object" and (.session_id | type == "string") then .session_id else "" end' \
      "$STATE_FILE" 2>/dev/null || true)
  fi
fi

if [ "$state_present" = true ] && [ ! -f "$PID_FILE" ]; then
  attempts=0
  while [ "$attempts" -lt 10 ] && [ ! -f "$PID_FILE" ]; do
    attempts=$((attempts + 1))
    sleep 0.05
  done
fi

if [ "$state_present" = true ] && [ -f "$PID_FILE" ]; then
  while IFS= read -r pid; do
    if valid_pid "$pid" && [ "$pid" -ne "$$" ]; then
      "$STOP_TREE_SCRIPT" "$pid" 1 >/dev/null || true
    fi
  done < "$PID_FILE"
fi

rm -f "${runtime_files[@]}" "$PID_FILE".tmp.*
if [ -n "$owner" ]; then
  "$SCRIPT_DIR/loop-registry.sh" unregister "$owner" "$PWD" >/dev/null 2>&1 || true
fi

if [ "$state_present" = true ]; then
  printf 'Review loop cancelled (was at phase: %s, review ID: %s)\n' "$phase" "$review_id"
else
  printf 'No active review loop found.\n'
fi
