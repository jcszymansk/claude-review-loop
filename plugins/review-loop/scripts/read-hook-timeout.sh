#!/usr/bin/env bash
# Prints the Stop hook timeout (seconds) that Claude Code enforces, as
# declared in this plugin's hooks/hooks.json. That file is the only place the
# number is defined; everything that has to stay inside it reads it here.
set -euo pipefail

HOOKS_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hooks/hooks.json"

if ! command -v jq >/dev/null 2>&1; then
  printf 'Error: jq is required to read %s.\n' "$HOOKS_FILE" >&2
  exit 1
fi

# Selected by command rather than position, so adding another Stop hook entry
# cannot silently change which timeout is read.
if ! hook_timeout=$(jq -er '
  [.hooks.Stop[]?.hooks[]? | select((.command // "") | endswith("/hooks/stop-hook.sh")) | .timeout]
  | if length == 1 then .[0] else error("expected exactly one stop-hook.sh entry") end
' "$HOOKS_FILE" 2>/dev/null); then
  printf 'Error: failed to read the stop-hook.sh timeout from %s.\n' "$HOOKS_FILE" >&2
  exit 1
fi

case "$hook_timeout" in
  ''|0*|*[!0-9]*)
    printf 'Error: Stop hook timeout in %s must be a positive integer (got %q).\n' \
      "$HOOKS_FILE" "$hook_timeout" >&2
    exit 1
    ;;
esac
if [ "${#hook_timeout}" -gt 9 ]; then
  printf 'Error: Stop hook timeout in %s is too large (got %s).\n' "$HOOKS_FILE" "$hook_timeout" >&2
  exit 1
fi

printf '%s\n' "$hook_timeout"
