#!/usr/bin/env bash
# Usage:
#   loop-registry.sh dir                                  print the registry directory
#   loop-registry.sh register <session-id> <loop-dir>     record the session's loop
#   loop-registry.sh unregister <session-id> <loop-dir>   forget it, if it is that loop
#   loop-registry.sh lookup <session-id>                  print the session's loop
#
# Claude Code runs the Stop hook in the session's current directory, which
# follows the main agent's last `cd`, so the hook cannot find a loop from its
# cwd alone. Setup records the loop directory here, keyed by the session id
# that the hook receives in its input:
#
#   ${XDG_STATE_HOME:-~/.local/state}/review-loop/sessions/<session-id>
#       -> one line: the absolute loop directory
#
# lookup only returns a directory whose state file still exists and names the
# same session; anything else is a leftover (a crash, a deleted checkout) and
# is removed. Exit status: 0 on success, 1 when there is nothing to return or
# no registry directory, 2 on invalid arguments.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_PATH=".claude/review-loop.local.json"

usage() {
  echo "Usage: loop-registry.sh dir | register <session-id> <loop-dir> | unregister <session-id> <loop-dir> | lookup <session-id>" >&2
  exit 2
}

# The XDG spec says relative values must be ignored.
registry_dir() {
  local state_home="${XDG_STATE_HOME:-}"
  case "$state_home" in
    /*) ;;
    *)
      case "${HOME:-}" in
        /*) state_home="$HOME/.local/state" ;;
        *) return 1 ;;
      esac
      ;;
  esac
  printf '%s\n' "${state_home%/}/review-loop/sessions"
}

valid_session_id() {
  [ -n "$1" ] && [ "$("$SCRIPT_DIR/normalize-session-id.sh" "$1")" = "$1" ]
}

# The entry is a single line, so a directory with a newline cannot be stored.
valid_loop_dir() {
  case "$1" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *$'\n'*) return 1 ;;
  esac
}

state_owner() {
  jq -r 'if type == "object" and (.session_id | type == "string") then .session_id else "" end' \
    "$1" 2>/dev/null || true
}

command="${1:-}"
case "$command" in
  dir)
    [ "$#" -eq 1 ] || usage
    registry_dir
    ;;
  register)
    [ "$#" -eq 3 ] || usage
    session_id="$2"
    loop_dir="$3"
    valid_session_id "$session_id" || usage
    valid_loop_dir "$loop_dir" || usage
    registry="$(registry_dir)" || exit 1
    mkdir -p "$registry"
    entry="$registry/$session_id"
    temp_file="$entry.tmp.$$"
    if ! printf '%s\n' "$loop_dir" > "$temp_file" || ! mv "$temp_file" "$entry"; then
      rm -f "$temp_file"
      exit 1
    fi
    ;;
  unregister)
    [ "$#" -eq 3 ] || usage
    session_id="$2"
    loop_dir="$3"
    valid_session_id "$session_id" || usage
    registry="$(registry_dir)" || exit 0
    entry="$registry/$session_id"
    if [ -f "$entry" ] && [ "$(head -n 1 "$entry" 2>/dev/null || true)" = "$loop_dir" ]; then
      rm -f "$entry"
    fi
    ;;
  lookup)
    [ "$#" -eq 2 ] || usage
    session_id="$2"
    valid_session_id "$session_id" || exit 1
    registry="$(registry_dir)" || exit 1
    entry="$registry/$session_id"
    [ -f "$entry" ] || exit 1
    loop_dir="$(head -n 1 "$entry" 2>/dev/null || true)"
    if valid_loop_dir "$loop_dir" && [ -f "$loop_dir/$STATE_PATH" ] &&
      command -v jq >/dev/null 2>&1 &&
      [ "$(state_owner "$loop_dir/$STATE_PATH")" = "$session_id" ]; then
      printf '%s\n' "$loop_dir"
      exit 0
    fi
    # Without jq ownership cannot be checked, but the entry may still be good.
    if command -v jq >/dev/null 2>&1; then
      rm -f "$entry"
    fi
    exit 1
    ;;
  *)
    usage
    ;;
esac
