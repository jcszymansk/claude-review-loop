#!/usr/bin/env bash
set -u

STATE_FILE=".claude/review-loop.local.json"
PID_FILE=".claude/review-loop-child.pid"

runtime_files=(
  "$STATE_FILE"
  ".claude/review-loop.lock"
  ".claude/review-loop-run-codex.sh"
  ".claude/review-loop-run-cursor.sh"
  ".claude/review-loop-codex-prompt.txt"
  ".claude/review-loop-cursor-prompt.txt"
  ".claude/review-loop-retries"
  "$PID_FILE"
)

child_pids() {
  local parent="$1"
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -P "$parent" 2>/dev/null || true
  else
    ps -e -o pid= -o ppid= 2>/dev/null |
      awk -v parent="$parent" '$2 == parent {print $1}' || true
  fi
}

valid_pid() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -gt 1 ] 2>/dev/null
}

terminate_process_tree() {
  local pid="$1"
  local child

  while IFS= read -r child; do
    [ -n "$child" ] || continue
    terminate_process_tree "$child"
  done < <(child_pids "$pid")

  kill -TERM "$pid" 2>/dev/null || true
}

force_terminate_process_tree() {
  local pid="$1"
  local child

  while IFS= read -r child; do
    [ -n "$child" ] || continue
    force_terminate_process_tree "$child"
  done < <(child_pids "$pid")

  kill -KILL "$pid" 2>/dev/null || true
}

state_present=false
phase="unknown"
review_id="unknown"
if [ -f "$STATE_FILE" ]; then
  state_present=true
  if command -v jq >/dev/null 2>&1; then
    phase=$(jq -r '.phase // "unknown"' "$STATE_FILE" 2>/dev/null || printf 'unknown')
    review_id=$(jq -r '.review_id // "unknown"' "$STATE_FILE" 2>/dev/null || printf 'unknown')
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
      terminate_process_tree "$pid"
      sleep 0.1
      if kill -0 "$pid" 2>/dev/null; then
        force_terminate_process_tree "$pid"
      fi
    fi
  done < "$PID_FILE"
fi

rm -f "${runtime_files[@]}" "$PID_FILE".tmp.*

if [ "$state_present" = true ]; then
  printf 'Review loop cancelled (was at phase: %s, review ID: %s)\n' "$phase" "$review_id"
else
  printf 'No active review loop found.\n'
fi
