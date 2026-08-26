#!/usr/bin/env bash
set -euo pipefail

DEFAULT_MAX_ROUNDS=3
MAX_ALLOWED_ROUNDS=10
PROJECT_CONFIG=".review-loop.toml"
USER_CONFIG="${XDG_CONFIG_HOME:-${HOME:-$PWD}/.config}/review-loop/config.toml"

read_config_max_rounds() {
  local config_file="$1"
  local result

  result=$(awk '
    /^[[:space:]]*max_rounds[[:space:]]*=/ {
      value = $0
      sub(/^[[:space:]]*max_rounds[[:space:]]*=[[:space:]]*/, "", value)
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
      printf 'Error: failed to read max_rounds from %s.\n' "$config_file" >&2
      return 1
      ;;
  esac
}

validate_max_rounds() {
  local value="$1"
  local source="$2"

  case "$value" in
    1|2|3|4|5|6|7|8|9|10)
      printf '%s\n' "$value"
      ;;
    *)
      printf 'Error: %s must be an integer from 1 to %s (got %q).\n' \
        "$source" "$MAX_ALLOWED_ROUNDS" "$value" >&2
      return 1
      ;;
  esac
}

if [ "${REVIEW_LOOP_MAX_ROUNDS+x}" = x ]; then
  validate_max_rounds "$REVIEW_LOOP_MAX_ROUNDS" "REVIEW_LOOP_MAX_ROUNDS"
elif [ -f "$PROJECT_CONFIG" ] && PROJECT_MAX_ROUNDS=$(read_config_max_rounds "$PROJECT_CONFIG"); then
  validate_max_rounds "$PROJECT_MAX_ROUNDS" "$PROJECT_CONFIG max_rounds"
elif [ -f "$USER_CONFIG" ] && USER_MAX_ROUNDS=$(read_config_max_rounds "$USER_CONFIG"); then
  validate_max_rounds "$USER_MAX_ROUNDS" "$USER_CONFIG max_rounds"
else
  printf '%s\n' "$DEFAULT_MAX_ROUNDS"
fi
