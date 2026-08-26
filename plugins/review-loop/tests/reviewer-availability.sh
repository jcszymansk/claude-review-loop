#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/stop-hook.sh"
TMP_DIR="$(mktemp -d)"
PROJECT_DIR="$TMP_DIR/project"
HOME_DIR="$TMP_DIR/home"
BIN_DIR="$TMP_DIR/bin"
STATE_FILE="$PROJECT_DIR/.claude/review-loop.local.json"
REVIEW_DIR="$PROJECT_DIR/reviews/20260826-123456-abcdef"


cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$PROJECT_DIR/.claude" "$HOME_DIR" "$BIN_DIR"

link_command() {
  local name="$1"
  ln -s "$(command -v "$name")" "$BIN_DIR/$name"
}

for command_name in awk bash cat date dirname grep head jq mkdir rm sed; do
  link_command "$command_name"
done

write_state() {
  local reviewer="$1"
  jq -n \
    --arg reviewer "$reviewer" \
    '{
      active: true,
      phase: "task",
      reviewer: $reviewer,
      task: "review the current changes",
      round: 1,
      max_rounds: 3,
      review_id: "20260826-123456-abcdef",
      started_at: "2026-08-26T12:34:56Z"
    }' > "$STATE_FILE"
}

write_addressing_state() {
  jq -n '{
    active: true,
    phase: "addressing",
    reviewer: "codex",
    task: "review the current changes",
    round: 1,
    max_rounds: 3,
    review_id: "20260826-123456-abcdef",
    started_at: "2026-08-26T12:34:56Z"
  }' > "$STATE_FILE"
}

output=$(cd "$PROJECT_DIR" && env -i HOME="$HOME_DIR" PATH="$BIN_DIR" "$HOOK" <<< '{}')
if ! jq -e '.decision == "approve"' <<< "$output" >/dev/null; then
  printf 'FAIL: no-state path did not approve: %s\n' "$output" >&2
  exit 1
fi

assert_missing_cli() {
  local reviewer="$1"
  local cli="$2"
  local name="$3"
  local install="$4"
  local output

  write_state "$reviewer"
  mkdir -p "$REVIEW_DIR"
  printf 'retained review history\n' > "$REVIEW_DIR/summary-0.md"
  touch \
    "$PROJECT_DIR/.claude/review-loop-run-codex.sh" \
    "$PROJECT_DIR/.claude/review-loop-codex-prompt.txt" \
    "$PROJECT_DIR/.claude/review-loop-retries"
  output=$(cd "$PROJECT_DIR" && env -i HOME="$HOME_DIR" PATH="$BIN_DIR" "$HOOK" <<< '{}')

  if ! jq -e --arg cli "$cli" --arg name "$name" --arg install "$install" \
    '.decision == "block" and (.reason | contains($cli)) and (.reason | contains($name)) and (.reason | contains($install))' \
    <<< "$output" >/dev/null; then
    printf 'FAIL: missing %s CLI response: %s\n' "$reviewer" "$output" >&2
    exit 1
  fi

  if [ ! -d "$REVIEW_DIR" ]; then
    printf 'FAIL: missing %s CLI did not create its loop directory\n' "$reviewer" >&2
    exit 1
  fi

  if [ -f "$STATE_FILE" ]; then
    printf 'FAIL: missing %s CLI left active state behind\n' "$reviewer" >&2
    exit 1
  fi
  for generated_file in \
    "$PROJECT_DIR/.claude/review-loop-run-codex.sh" \
    "$PROJECT_DIR/.claude/review-loop-codex-prompt.txt" \
    "$PROJECT_DIR/.claude/review-loop-retries"; do
    if [ -e "$generated_file" ]; then
      printf 'FAIL: missing %s CLI left generated runtime file: %s\n' "$reviewer" "$generated_file" >&2
      exit 1
    fi
  done

  if [ "$(cat "$REVIEW_DIR/summary-0.md")" != 'retained review history' ]; then
    printf 'FAIL: missing %s CLI removed review history\n' "$reviewer" >&2
    exit 1
  fi
}

assert_missing_cli codex codex Codex 'npm install -g @openai/codex'
assert_missing_cli gemini gemini Gemini 'npm install -g @google/gemini-cli'
assert_missing_cli cursor cursor-agent 'Cursor Agent' 'curl https://cursor.com/install -fsS | bash'

write_addressing_state
mkdir -p "$REVIEW_DIR"
: > "$PROJECT_DIR/.claude/review-loop-run-codex.sh"
printf 'implementation summary\n' > "$REVIEW_DIR/summary-0.md"
printf 'first correction summary\n' > "$REVIEW_DIR/summary-1.md"
printf 'later round review\n' > "$REVIEW_DIR/review-2.md"
output=$(cd "$PROJECT_DIR" && env -i HOME="$HOME_DIR" PATH="$BIN_DIR" "$HOOK" <<< '{}')
if ! jq -e '.decision == "block"' <<< "$output" >/dev/null || [ ! -f "$STATE_FILE" ]; then
  printf 'FAIL: addressing path did not block without a review: %s\n' "$output" >&2
  exit 1
fi

assert_review_decision() {
  local content="$1"
  local expected_decision="$2"
  local output

  write_addressing_state
  printf '%s\n' "$content" > "$REVIEW_DIR/review-1.md"
  output=$(cd "$PROJECT_DIR" && env -i HOME="$HOME_DIR" PATH="$BIN_DIR" "$HOOK" <<< '{}')

  if [ "$expected_decision" = "block" ]; then
    if ! jq -e --arg decision "$expected_decision" \
      '.decision == $decision and (.reason | contains("FAIL"))' \
      <<< "$output" >/dev/null; then
      printf 'FAIL: rejected verdict produced the wrong decision: %s\n' "$output" >&2
      exit 1
    fi
  elif ! jq -e --arg decision "$expected_decision" \
    '.decision == $decision' <<< "$output" >/dev/null; then
    printf 'FAIL: accepted verdict produced the wrong decision: %s\n' "$output" >&2
    exit 1
  fi

  if [ "$expected_decision" = "approve" ] && [ -f "$STATE_FILE" ]; then
    printf 'FAIL: accepted verdict left active state behind\n' >&2
    exit 1
  fi
  if [ "$expected_decision" = "block" ] && [ ! -f "$STATE_FILE" ]; then
    printf 'FAIL: rejected verdict removed active state\n' >&2
    exit 1
  fi
}

assert_review_decision "" block
assert_review_decision "Review complete without a verdict" block
assert_review_decision "verdict: PASS" block
assert_review_decision "VERDICT: PASS " block
assert_review_decision "VERDICT: FAIL" block
assert_review_decision $'VERDICT: PASS\nNo findings.' approve

if [ ! -d "$REVIEW_DIR" ]; then
  printf 'FAIL: review loop directory was removed with the state\n' >&2
  exit 1
fi

for artifact in summary-0.md summary-1.md review-2.md; do
  if [ ! -s "$REVIEW_DIR/$artifact" ]; then
    printf 'FAIL: PASS cleanup removed retained artifact: %s\n' "$artifact" >&2
    exit 1
  fi
done
if [ "$(cat "$REVIEW_DIR/summary-0.md")" != 'implementation summary' ] ||
  [ "$(cat "$REVIEW_DIR/summary-1.md")" != 'first correction summary' ] ||
  [ "$(cat "$REVIEW_DIR/review-2.md")" != 'later round review' ]; then
  printf 'FAIL: PASS cleanup modified retained review history\n' >&2
  exit 1
fi

printf '{"active":' > "$STATE_FILE"
output=$(cd "$PROJECT_DIR" && env -i HOME="$HOME_DIR" PATH="$BIN_DIR" "$HOOK" <<< '{}')
if ! jq -e '.decision == "approve"' <<< "$output" >/dev/null || [ -f "$STATE_FILE" ]; then
  printf 'FAIL: malformed JSON state was not failed open: %s\n' "$output" >&2
  exit 1
fi

jq -n '{
  active: true,
  phase: "task",
  reviewer: "codex",
  task: "review the current changes",
  round: "one",
  max_rounds: 3,
  review_id: "20260826-123456-abcdef",
  started_at: "2026-08-26T12:34:56Z"
}' > "$STATE_FILE"
output=$(cd "$PROJECT_DIR" && env -i HOME="$HOME_DIR" PATH="$BIN_DIR" "$HOOK" <<< '{}')
if ! jq -e '.decision == "approve"' <<< "$output" >/dev/null || [ -f "$STATE_FILE" ]; then
  printf 'FAIL: invalid state field type was not failed open: %s\n' "$output" >&2
  exit 1
fi

jq -n '{
  active: true,
  phase: "task",
  reviewer: "codex",
  task: "review the current changes",
  round: -1,
  max_rounds: 0,
  review_id: "20260826-123456-abcdef",
  started_at: "2026-08-26T12:34:56Z"
}' > "$STATE_FILE"
output=$(cd "$PROJECT_DIR" && env -i HOME="$HOME_DIR" PATH="$BIN_DIR" "$HOOK" <<< '{}')
if ! jq -e '.decision == "approve"' <<< "$output" >/dev/null || [ -f "$STATE_FILE" ]; then
  printf 'FAIL: invalid state numeric bounds were not failed open: %s\n' "$output" >&2
  exit 1
fi

cancel_command="$SCRIPT_DIR/../commands/cancel-review.md"
if grep -Eq '^[[:space:]]*rm .*reviews/' "$cancel_command" ||
  ! grep -Fq 'Leave `reviews/<review_id>/` untouched.' "$cancel_command"; then
  printf 'FAIL: cancellation instructions do not preserve review history\n' >&2
  exit 1
fi

printf 'reviewer availability tests passed\n'
