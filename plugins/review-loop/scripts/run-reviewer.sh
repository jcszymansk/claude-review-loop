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
    GEMINI_FLAGS="${REVIEW_LOOP_GEMINI_FLAGS:---output-format text}"
    # shellcheck disable=SC2086
    gemini -p "$(cat "$PROMPT_FILE")" ${GEMINI_FLAGS}
    ;;
  cursor)
    CURSOR_FLAGS="${REVIEW_LOOP_CURSOR_FLAGS:---output-format text --trust}"
    # shellcheck disable=SC2086
    cursor-agent -p ${CURSOR_FLAGS} < "$PROMPT_FILE"
    ;;
  *)
    echo "Unsupported reviewer: $REVIEWER" >&2
    exit 2
    ;;
esac
