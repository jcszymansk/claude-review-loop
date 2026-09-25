#!/usr/bin/env bash
set -euo pipefail

REVIEWER="${1:-}"
PROMPT_FILE="${2:-}"

REVIEW_FILE="${3:-}"
DEBUG_ENABLED="${REVIEW_LOOP_DEBUG:-}"
DEBUG_FILE="${REVIEW_LOOP_DEBUG_FILE:-.claude/review-loop-debug.log}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
      env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT REVIEW_LOOP_REVIEWER_PROCESS=1 claude -p ${CLAUDE_FLAGS} "$(cat "$PROMPT_FILE")"
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
# Every normal path below moves or removes the capture before exiting, so a
# capture still present here belongs to a run that was interrupted (for
# example stopped by the runner's timeout watchdog). Its partial output is
# kept as a numbered reviewer-error file.
# shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap; older shellcheck reports SC2317, newer SC2329
keep_interrupted_capture() {
  if [ -s "$OUTPUT_FILE" ]; then
    "$SCRIPT_DIR/quarantine-review-artifact.sh" "$REVIEW_FILE" "$OUTPUT_FILE" >/dev/null 2>&1 ||
      rm -f "$OUTPUT_FILE"
  else
    rm -f "$OUTPUT_FILE"
  fi
}
trap keep_interrupted_capture EXIT

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
  quarantine_file=$("$SCRIPT_DIR/quarantine-review-artifact.sh" "$REVIEW_FILE")
  debug_log "quarantined review artifact after non-zero exit: $quarantine_file"
fi

debug_log "reviewer runner exiting (exit=$REVIEWER_EXIT)"
exit "$REVIEWER_EXIT"
