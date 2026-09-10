#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/stop-hook.sh"
CANCEL="$SCRIPT_DIR/../scripts/cancel-review-loop.sh"
TMP_DIR="$(mktemp -d)"
BIN_DIR="$TMP_DIR/bin"
HOME_DIR="$TMP_DIR/home"

cleanup() {
  set +e
  local pid="${HOOK_PID:-}"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    sleep 0.1
    kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$BIN_DIR" "$HOME_DIR/.codex"
printf '[features]\nmulti_agent = true\n' > "$HOME_DIR/.codex/config.toml"

cat > "$BIN_DIR/codex" <<'CODEX_EOF'
#!/usr/bin/env bash
if [ "${FAKE_REVIEW_MODE:-hang}" = "fail" ]; then
  printf 'VERDICT: FAIL\nneeds correction\n'
  exit 0
fi
printf '%s\n' "$$" > "$FAKE_REVIEWER_PID_FILE"
trap 'exit 143' TERM INT
while :; do
  sleep 1
done
CODEX_EOF
chmod +x "$BIN_DIR/codex"

cat > "$BIN_DIR/claude" <<'CLAUDE_EOF'
#!/usr/bin/env bash
if [ "${1:-}" != "-p" ]; then
  printf 'FAIL: unexpected Claude invocation\n' >&2
  exit 1
fi
printf '%s\n' "$$" > "$FAKE_REVIEWER_PID_FILE"
trap 'exit 143' TERM INT
while :; do
  sleep 1
done
CLAUDE_EOF
chmod +x "$BIN_DIR/claude"

write_state() {
  local project_dir="$1"
  local review_id="$2"
  local phase="${3:-task}"
  local reviewer="${4:-codex}"
  mkdir -p "$project_dir/.claude" "$project_dir/reviews/$review_id"
  printf '# Review Loop Task Context\n\nCancellation test\n' > \
    "$project_dir/reviews/$review_id/summary-0.md"
  cat > "$project_dir/.claude/review-loop.local.json" <<STATE_EOF
{
  "active": true,
  "phase": "$phase",
  "reviewer": "$reviewer",
  "task": "test cancellation",
  "round": 1,
  "max_rounds": 3,
  "review_id": "$review_id",
  "started_at": "2026-08-26T12:34:56Z"
}
STATE_EOF
}

wait_for_file() {
  local file="$1"
  local attempts=0
  while [ "$attempts" -lt 100 ]; do
    [ -f "$file" ] && return 0
    attempts=$((attempts + 1))
    sleep 0.1
  done
  printf 'FAIL: timed out waiting for %s\n' "$file" >&2
  exit 1
}

assert_stopped() {
  local pid_file="$1"
  local pid
  pid=$(cat "$pid_file")
  local attempts=0
  while [ "$attempts" -lt 30 ] && kill -0 "$pid" 2>/dev/null; do
    attempts=$((attempts + 1))
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    printf 'FAIL: process %s was not stopped\n' "$pid" >&2
    exit 1
  fi
}

REVIEW_PROJECT="$TMP_DIR/reviewer-project"
REVIEW_ID="20260826-123456-abcdef"
REVIEWER_PID_FILE="$TMP_DIR/reviewer.pid"
write_state "$REVIEW_PROJECT" "$REVIEW_ID"
(
  cd "$REVIEW_PROJECT"
  env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" \
    FAKE_REVIEW_MODE=hang \
    FAKE_REVIEWER_PID_FILE="$REVIEWER_PID_FILE" \
    "$HOOK" <<< '{}' > "$TMP_DIR/reviewer-hook-output"
) &
HOOK_PID=$!
wait_for_file "$REVIEWER_PID_FILE"
cancel_output=$(cd "$REVIEW_PROJECT" && "$CANCEL")
wait "$HOOK_PID" || true
unset HOOK_PID
assert_stopped "$REVIEWER_PID_FILE"
case "$cancel_output" in
  *"phase: task"*"review ID: $REVIEW_ID"*) ;;
  *)
    printf 'FAIL: cancellation reported the wrong loop: %s\n' "$cancel_output" >&2
    exit 1
    ;;
esac
[ ! -f "$REVIEW_PROJECT/.claude/review-loop.local.json" ]
[ ! -f "$REVIEW_PROJECT/.claude/review-loop-child.pid" ]
[ -f "$REVIEW_PROJECT/reviews/$REVIEW_ID/summary-0.md" ]
CLAUDE_REVIEW_PROJECT="$TMP_DIR/claude-reviewer-project"
CLAUDE_REVIEW_ID="20260826-123456-fedcba"
CLAUDE_REVIEWER_PID_FILE="$TMP_DIR/claude-reviewer.pid"
write_state "$CLAUDE_REVIEW_PROJECT" "$CLAUDE_REVIEW_ID" task claude
(
  cd "$CLAUDE_REVIEW_PROJECT"
  env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" \
    FAKE_REVIEWER_PID_FILE="$CLAUDE_REVIEWER_PID_FILE" \
    "$HOOK" <<< '{}' > "$TMP_DIR/claude-reviewer-hook-output"
) &
HOOK_PID=$!
wait_for_file "$CLAUDE_REVIEWER_PID_FILE"
cancel_output=$(cd "$CLAUDE_REVIEW_PROJECT" && "$CANCEL")
wait "$HOOK_PID" || true
unset HOOK_PID
assert_stopped "$CLAUDE_REVIEWER_PID_FILE"
case "$cancel_output" in
  *"phase: task"*"review ID: $CLAUDE_REVIEW_ID"*) ;;
  *)
    printf 'FAIL: Claude reviewer cancellation reported the wrong loop: %s\n' "$cancel_output" >&2
    exit 1
    ;;
esac
[ ! -f "$CLAUDE_REVIEW_PROJECT/.claude/review-loop.local.json" ]
[ ! -f "$CLAUDE_REVIEW_PROJECT/.claude/review-loop-child.pid" ]
[ -f "$CLAUDE_REVIEW_PROJECT/reviews/$CLAUDE_REVIEW_ID/summary-0.md" ]


printf 'cancellation tests passed\n'
