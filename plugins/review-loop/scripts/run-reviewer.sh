#!/usr/bin/env bash
set -euo pipefail

REVIEWER="${1:-}"
PROMPT_FILE="${2:-}"

REVIEW_FILE="${3:-}"

if [ -z "$REVIEWER" ] || [ -z "$PROMPT_FILE" ] || [ ! -f "$PROMPT_FILE" ]; then
  echo "Usage: run-reviewer.sh <codex|gemini|cursor> <prompt-file> [review-file]" >&2
  exit 2
fi

run_reviewer() {
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
      CURSOR_FLAGS="${REVIEW_LOOP_CURSOR_FLAGS:---output-format text}"
      # shellcheck disable=SC2086
      cursor-agent -p ${CURSOR_FLAGS} < "$PROMPT_FILE"
      ;;
    *)
      echo "Unsupported reviewer: $REVIEWER" >&2
      return 2
      ;;
  esac
}

if [ -z "$REVIEW_FILE" ]; then
  run_reviewer
  exit $?
fi

OUTPUT_FILE="${REVIEW_FILE}.stdout.$$"
trap 'rm -f "$OUTPUT_FILE"' EXIT

set +e
run_reviewer | tee "$OUTPUT_FILE"
REVIEWER_EXIT=${PIPESTATUS[0]}
set -e

has_verdict() {
  case "$(head -n 1 "$1" 2>/dev/null || true)" in
    "VERDICT: PASS"|"VERDICT: FAIL") return 0 ;;
    *) return 1 ;;
  esac
}

if [ -s "$OUTPUT_FILE" ] && {
  [ ! -s "$REVIEW_FILE" ] ||
  { ! has_verdict "$REVIEW_FILE" && has_verdict "$OUTPUT_FILE"; };
}; then
  mv "$OUTPUT_FILE" "$REVIEW_FILE"
else
  rm -f "$OUTPUT_FILE"
fi

exit "$REVIEWER_EXIT"
