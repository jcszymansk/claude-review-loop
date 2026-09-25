#!/usr/bin/env bash
# Prints the reviewer timeout in seconds, resolved from (first match wins):
#   REVIEW_LOOP_REVIEW_TIMEOUT
#   review_timeout in .review-loop.toml
#   review_timeout in ${XDG_CONFIG_HOME:-$HOME/.config}/review-loop/config.toml
#   the default of 1800
#
# The value must be a positive integer no larger than the Claude Code Stop
# hook timeout minus a safety margin; otherwise this fails instead of silently
# falling back to another source.
set -euo pipefail

DEFAULT_REVIEW_TIMEOUT=1800
HOOK_TIMEOUT_MARGIN_SECONDS=60
PROJECT_CONFIG=".review-loop.toml"
USER_CONFIG="${XDG_CONFIG_HOME:-${HOME:-$PWD}/.config}/review-loop/config.toml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Without the hook timeout there is no safe upper bound, so setup stops here
# instead of guessing one.
if ! HOOK_TIMEOUT=$("$SCRIPT_DIR/read-hook-timeout.sh"); then
  printf 'Error: cannot validate review_timeout without the Stop hook timeout; check %s.\n' \
    "$(cd "$SCRIPT_DIR/.." && pwd)/hooks/hooks.json" >&2
  exit 1
fi
MAX_REVIEW_TIMEOUT=$((HOOK_TIMEOUT - HOOK_TIMEOUT_MARGIN_SECONDS))

read_config_review_timeout() {
  local config_file="$1"
  local result

  result=$(awk '
    /^[[:space:]]*review_timeout[[:space:]]*=/ {
      value = $0
      sub(/^[[:space:]]*review_timeout[[:space:]]*=[[:space:]]*/, "", value)
      sub(/[[:space:]]*#.*$/, "", value)
      sub(/[[:space:]]+$/, "", value)
      print "found:" value
      found = 1
      exit
    }
    END {
      if (!found) print "missing"
    }
  ' "$config_file")

  case "$result" in
    missing)
      return 1
      ;;
    found:*)
      printf '%s\n' "${result#found:}"
      ;;
    *)
      printf 'Error: failed to read review_timeout from %s.\n' "$config_file" >&2
      return 2
      ;;
  esac
}

validate_review_timeout() {
  local value="$1"
  local source="$2"

  case "$value" in
    ''|0*|*[!0-9]*)
      printf 'Error: %s must be a positive integer number of seconds (got %q).\n' \
        "$source" "$value" >&2
      return 1
      ;;
  esac
  if [ "${#value}" -gt 9 ] || [ "$value" -gt "$MAX_REVIEW_TIMEOUT" ]; then
    printf 'Error: %s must be at most %s seconds: the Claude Code Stop hook timeout is %ss and the review needs a %ss margin inside it (got %s).\n' \
      "$source" "$MAX_REVIEW_TIMEOUT" "$HOOK_TIMEOUT" "$HOOK_TIMEOUT_MARGIN_SECONDS" "$value" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

if [ "${REVIEW_LOOP_REVIEW_TIMEOUT+x}" = x ]; then
  validate_review_timeout "$REVIEW_LOOP_REVIEW_TIMEOUT" "REVIEW_LOOP_REVIEW_TIMEOUT"
  exit 0
fi

# A config file that cannot be read stops resolution; it is never skipped in
# favour of the next source.
for config_file in "$PROJECT_CONFIG" "$USER_CONFIG"; do
  [ -f "$config_file" ] || continue
  read_status=0
  config_value=$(read_config_review_timeout "$config_file") || read_status=$?
  case "$read_status" in
    0)
      validate_review_timeout "$config_value" "$config_file review_timeout"
      exit 0
      ;;
    1)
      ;;
    *)
      exit 1
      ;;
  esac
done

validate_review_timeout "$DEFAULT_REVIEW_TIMEOUT" "the default review_timeout"
