#!/usr/bin/env bash
set -euo pipefail

REVIEWER="${1:-}"
PROMPT_FILE="${2:-}"

if [ -z "$REVIEWER" ] || [ -z "$PROMPT_FILE" ] || [ ! -f "$PROMPT_FILE" ]; then
  echo "Usage: run-reviewer.sh <codex|gemini|cursor> <prompt-file>" >&2
  exit 2
fi

case "$REVIEWER" in
  codex)
    CODEX_FLAGS="${REVIEW_LOOP_CODEX_FLAGS:---dangerously-bypass-approvals-and-sandbox}"
    # shellcheck disable=SC2086
    codex ${CODEX_FLAGS} exec "$(cat "$PROMPT_FILE")"
    ;;
  gemini)
    gemini -p "$(cat "$PROMPT_FILE")" --output-format text
    ;;
  cursor)
    cursor-agent -p --output-format text --trust < "$PROMPT_FILE"
    ;;
  *)
    echo "Unsupported reviewer: $REVIEWER" >&2
    exit 2
    ;;
esac
