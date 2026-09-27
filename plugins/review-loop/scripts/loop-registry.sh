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
# same session. An entry whose state file is gone or names another session is
# a leftover (a crash, a deleted checkout) and is removed; register also sweeps
# such leftovers of other sessions. Loop directories are stored as physical
# paths. Exit status: 0 on success, 1 when there is nothing to return or no
# registry directory, 2 on invalid arguments.
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

# Physical path of an existing directory, so that a loop reached through a
# symlink and through its real path is the same entry.
canonical_dir() {
  (cd "$1" 2>/dev/null && pwd -P)
}

# Prints valid, stale or unknown for the entry of <session-id>. Only a state
# file that is gone, or that parses and names another session, makes an entry
# stale; an unreadable or unparseable one (a transient error, a file being
# replaced) is unknown and the entry is kept.
entry_status() {
  local session_id="$1"
  local entry="$2"
  local loop_dir owner

  loop_dir="$(head -n 1 "$entry" 2>/dev/null || true)"
  if ! valid_loop_dir "$loop_dir" || [ ! -e "$loop_dir/$STATE_PATH" ]; then
    printf 'stale\n'
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1 ||
    ! owner=$(jq -er 'if type == "object" and (.session_id | type == "string") then .session_id else "" end' \
      "$loop_dir/$STATE_PATH" 2>/dev/null); then
    printf 'unknown\n'
    return 0
  fi
  if [ "$owner" = "$session_id" ]; then
    printf 'valid\n'
  else
    printf 'stale\n'
  fi
}

# Entries of sessions that ended without cleanup (a crash, a killed terminal)
# are never looked up again, so every registration sweeps them.
sweep() {
  local registry="$1"
  local entry

  for entry in "$registry"/*; do
    [ -f "$entry" ] || continue
    case "${entry##*/}" in
      *.tmp.*) continue ;;
    esac
    valid_session_id "${entry##*/}" || continue
    if [ "$(entry_status "${entry##*/}" "$entry")" = "stale" ]; then
      rm -f "$entry"
    fi
  done
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
    valid_session_id "$session_id" || usage
    valid_loop_dir "$3" || usage
    loop_dir="$(canonical_dir "$3")" || usage
    valid_loop_dir "$loop_dir" || usage
    registry="$(registry_dir)" || exit 1
    mkdir -p "$registry"
    sweep "$registry"
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
    valid_session_id "$session_id" || usage
    loop_dir="$(canonical_dir "$3" || printf '%s' "$3")"
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
    case "$(entry_status "$session_id" "$entry")" in
      valid)
        head -n 1 "$entry"
        ;;
      stale)
        rm -f "$entry"
        exit 1
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  *)
    usage
    ;;
esac
