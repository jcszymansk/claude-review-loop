#!/usr/bin/env bash
set -euo pipefail

REVIEWER="${1:-}"
PROMPT_FILE="${2:-}"

REVIEW_FILE="${3:-}"
DEBUG_ENABLED="${REVIEW_LOOP_DEBUG:-}"
DEBUG_FILE="${REVIEW_LOOP_DEBUG_FILE:-.claude/review-loop-debug.log}"

if [ -z "$REVIEWER" ] || [ -z "$PROMPT_FILE" ] || [ ! -f "$PROMPT_FILE" ]; then
  echo "Usage: run-reviewer.sh <codex|cursor|claude> <prompt-file> [review-file]" >&2
  exit 2
fi

debug_log() {
  if [ "$DEBUG_ENABLED" != "1" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$DEBUG_FILE")" 2>/dev/null || return 0
  printf '[%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*" >> "$DEBUG_FILE" 2>/dev/null || true
}

run_reviewer() {
  debug_log "reviewer=$REVIEWER cwd=$PWD prompt=$PROMPT_FILE review_file=${REVIEW_FILE:-none} pid=$$"
  case "$REVIEWER" in
    codex)
      CODEX_FLAGS="${REVIEW_LOOP_CODEX_FLAGS:---dangerously-bypass-approvals-and-sandbox}"
      debug_log "invoke=codex prompt_mode=argument cli_path=$(command -v codex 2>/dev/null || printf 'unavailable')"
      # shellcheck disable=SC2086
      codex ${CODEX_FLAGS} exec "$(cat "$PROMPT_FILE")"
      ;;
    cursor)
      CURSOR_FLAGS="${REVIEW_LOOP_CURSOR_FLAGS:---output-format text}"
      debug_log "invoke=cursor-agent prompt_mode=stdin cli_path=$(command -v cursor-agent 2>/dev/null || printf 'unavailable')"
      # shellcheck disable=SC2086
      cursor-agent -p ${CURSOR_FLAGS} < "$PROMPT_FILE"
      ;;
    claude)
      CLAUDE_FLAGS="${REVIEW_LOOP_CLAUDE_FLAGS:---permission-mode acceptEdits}"
      debug_log "invoke=claude prompt_mode=argument cli_path=$(command -v claude 2>/dev/null || printf 'unavailable')"
      # shellcheck disable=SC2086
      env -u CLAUDECODE REVIEW_LOOP_REVIEWER_PROCESS=1 claude -p ${CLAUDE_FLAGS} "$(cat "$PROMPT_FILE")"
      ;;
    *)
      echo "Unsupported reviewer: $REVIEWER" >&2
      return 2
      ;;
  esac
}

if [ -z "$REVIEW_FILE" ]; then
  set +e
  run_reviewer
  REVIEWER_EXIT=$?
  set -e
  debug_log "reviewer invocation finished (exit=$REVIEWER_EXIT)"
  exit "$REVIEWER_EXIT"
fi

OUTPUT_FILE="${REVIEW_FILE}.stdout.$$"
trap 'rm -f "$OUTPUT_FILE"' EXIT

set +e
if [ "$DEBUG_ENABLED" = "1" ]; then
  debug_log "provider output begins; stdout and stderr are interleaved below"
  run_reviewer 2> >(tee -a "$DEBUG_FILE" >&2) |
    tee "$OUTPUT_FILE" |
    tee -a "$DEBUG_FILE"
else
  run_reviewer | tee "$OUTPUT_FILE"
fi
REVIEWER_EXIT=${PIPESTATUS[0]}
set -e
debug_log "provider output ended (exit=$REVIEWER_EXIT)"

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
  debug_log "capturing stdout as review artifact (bytes=$(wc -c < "$OUTPUT_FILE"))"
  mv "$OUTPUT_FILE" "$REVIEW_FILE"
else
  debug_log "discarding stdout capture (bytes=$(wc -c < "$OUTPUT_FILE" 2>/dev/null || printf '0'))"
  rm -f "$OUTPUT_FILE"
fi

if [ "$REVIEWER_EXIT" -ne 0 ] && [ -f "$REVIEW_FILE" ]; then
  # A non-zero reviewer exit is an error: the loop must never accept this
  # artifact as a PASS verdict. Keep every failed attempt for inspection,
  # numbered to avoid collisions, and vacate the canonical review path so
  # the addressing phase treats the round as incomplete and the retry gate
  # takes over. Vacating the path also lets a later rerun capture a fresh
  # artifact.
  quarantine_index=1
  quarantine_file="${REVIEW_FILE}.reviewer-error.${quarantine_index}"
  while [ -e "$quarantine_file" ]; do
    quarantine_index=$((quarantine_index + 1))
    quarantine_file="${REVIEW_FILE}.reviewer-error.${quarantine_index}"
  done
  debug_log "quarantining review artifact after non-zero exit: $quarantine_file"
  mv "$REVIEW_FILE" "$quarantine_file"
fi

debug_log "reviewer runner exiting (exit=$REVIEWER_EXIT)"
exit "$REVIEWER_EXIT"
