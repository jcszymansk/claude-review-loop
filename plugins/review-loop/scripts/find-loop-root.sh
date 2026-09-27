#!/usr/bin/env bash
# Usage: find-loop-root.sh <start-dir> [session-id]
#
# Prints the directory of the review loop that a Claude Code session in
# <start-dir> belongs to, and exits 1 when there is none.
#
# 1. The loop registered for this session in loop-registry.sh, wherever the
#    session's shell has moved since setup.
# 2. Otherwise a loop in <start-dir> itself, whatever its owner, as before
#    sessions were recorded: /clear starts a new session id, and older state
#    has no owner, but the loop there must still run and stay cancellable.
#
# A loop another session started elsewhere is never picked up.
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

if [ -n "$session_id" ] && "$SCRIPT_DIR/loop-registry.sh" lookup "$session_id"; then
  exit 0
fi

if [ -f "${dir%/}/$STATE_PATH" ]; then
  printf '%s\n' "$dir"
  exit 0
fi
exit 1
