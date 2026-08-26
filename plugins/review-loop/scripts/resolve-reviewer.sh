#!/usr/bin/env bash
set -euo pipefail

PROJECT_CONFIG=".review-loop.toml"
USER_CONFIG="${XDG_CONFIG_HOME:-${HOME:-$PWD}/.config}/review-loop/config.toml"

read_config_reviewer() {
  local config_file="$1"
  local reviewer

  reviewer=$(sed -nE 's/^[[:space:]]*reviewer[[:space:]]*=[[:space:]]*"([^"]+)"[[:space:]]*(#.*)?$/\1/p' "$config_file" | head -n 1)
  if [ -z "$reviewer" ]; then
    echo "Error: $config_file must define reviewer = \"codex|gemini|cursor\"." >&2
    return 1
  fi
  printf '%s\n' "$reviewer"
}

resolve_reviewer() {
  if [ -n "${REVIEW_LOOP_REVIEWER:-}" ]; then
    printf '%s\n' "$REVIEW_LOOP_REVIEWER"
  elif [ -f "$PROJECT_CONFIG" ]; then
    read_config_reviewer "$PROJECT_CONFIG"
  elif [ -f "$USER_CONFIG" ]; then
    read_config_reviewer "$USER_CONFIG"
  else
    printf 'codex\n'
  fi
}

REVIEWER="$(resolve_reviewer)"
case "$REVIEWER" in
  codex|gemini|cursor) printf '%s\n' "$REVIEWER" ;;
  *) echo "Error: unsupported reviewer '$REVIEWER' (use codex, gemini, or cursor)" >&2; exit 1 ;;
esac
