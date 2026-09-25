#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/stop-hook.sh"
TMP_DIR="$(mktemp -d)"
PROJECT_DIR="$TMP_DIR/project"
HOME_DIR="$TMP_DIR/home"
BIN_DIR="$TMP_DIR/bin"
REVIEW_ID="20260827-150000-cdef01"
STATE_FILE="$PROJECT_DIR/.claude/review-loop.local.json"
REVIEW_DIR="$PROJECT_DIR/reviews/$REVIEW_ID"
REVIEW_FILE="$REVIEW_DIR/review-1.md"
REVIEWER_PID_FILE="$TMP_DIR/reviewer.pid"
RUNNER="$PROJECT_DIR/.claude/review-loop-run-codex.sh"
HOOK_PID=""
REVIEWER_PID=""

cleanup() {
  set +e
  for pid in "$HOOK_PID" "$REVIEWER_PID"; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 0.1
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$PROJECT_DIR/.claude" "$HOME_DIR/.codex" "$BIN_DIR"
printf '[features]\nmulti_agent = true\n' > "$HOME_DIR/.codex/config.toml"

cat > "$BIN_DIR/codex" <<'CODEX_EOF'
#!/usr/bin/env bash
case "${FAKE_REVIEW_MODE:-clean}" in
  crash)
    exit 3
    ;;
  fail-then-crash)
    printf 'VERDICT: FAIL\nfindings from a crashed reviewer\n'
    exit 5
    ;;
  pass-then-crash)
    count=0
    if [ -f "${FAKE_COUNT_FILE:-}" ]; then
      count=$(cat "$FAKE_COUNT_FILE")
    fi
    count=$((count + 1))
    if [ -n "${FAKE_COUNT_FILE:-}" ]; then
      printf '%s\n' "$count" > "$FAKE_COUNT_FILE"
    fi
    printf 'VERDICT: PASS\nreview from a crashed reviewer (attempt %s)\n' "$count"
    exit 7
    ;;
  hang)
    printf '%s\n' "$$" > "$FAKE_REVIEWER_PID_FILE"
    trap 'exit 143' TERM INT
    while :; do
      sleep 1
    done
    ;;
  *)
    printf 'VERDICT: PASS\nclean review\n'
    ;;
esac
CODEX_EOF
chmod +x "$BIN_DIR/codex"

write_state() {
  rm -rf "$REVIEW_DIR"
  mkdir -p "$REVIEW_DIR"
  cat > "$STATE_FILE" <<STATE_EOF
{
  "active": true,
  "phase": "task",
  "reviewer": "codex",
  "task": "reviewer error handling test",
  "round": 1,
  "max_rounds": 3,
  "review_id": "$REVIEW_ID",
  "started_at": "2026-08-27T15:00:00Z"
}
STATE_EOF
  printf '# Review Loop Task Context\n\nreviewer error test\n' > \
    "$REVIEW_DIR/summary-0.md"
}

write_summary() {
  cat > "$REVIEW_DIR/summary-1.md" <<'SUMMARY_EOF'
## Fixes
- no findings were accepted

## Skipped findings
- None

## Quality gates
- shell test: PASS
SUMMARY_EOF
}

run_hook() {
  (
    cd "$PROJECT_DIR"
    env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" "$HOOK" <<< '{}'
  )
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
  local pid="$1"
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

assert_reviewer_failed() {
  local output="$1"
  jq -e '.decision == "block"' <<< "$output" >/dev/null
  case "$(jq -r '.reason' <<< "$output")" in
    *"did not produce a usable artifact"*)
      ;;
    *)
      printf 'FAIL: failed reviewer did not produce the artifact error: %s\n' \
        "$output" >&2
      exit 1
      ;;
  esac
  jq -e '.phase == "addressing"' "$STATE_FILE" >/dev/null
  [ ! -e "$REVIEW_FILE" ]
  [ -f "$PROJECT_DIR/.claude/review-loop-run-codex.sh" ]
}

assert_fails_open() {
  # First stop after the failure prompts a rerun; the second fails open.
  # This final approve is the error fail-open (state cleaned, history kept),
  # never a PASS verdict approval.
  local output
  output=$(run_hook)
  jq -e '.decision == "block"' <<< "$output" >/dev/null
  case "$(jq -r '.reason' <<< "$output")" in
    *"has not been completed yet"*)
      ;;
    *)
      printf 'FAIL: failed review did not prompt to run the reviewer: %s\n' \
        "$output" >&2
      exit 1
      ;;
  esac
  [ "$(cat "$PROJECT_DIR/.claude/review-loop-retries")" = "1" ]

  output=$(run_hook)
  jq -e '.decision == "approve"' <<< "$output" >/dev/null
  [ ! -f "$STATE_FILE" ]
  [ -d "$REVIEW_DIR" ]
}

# ── Reviewer crashes without writing anything ──────────────────────────────
export FAKE_REVIEW_MODE=crash
write_state
output=$(run_hook)
assert_reviewer_failed "$output"
[ ! -e "$REVIEW_FILE.reviewer-error.1" ]
grep -q 'exit=3' "$PROJECT_DIR/.claude/review-loop.log"
assert_fails_open
[ -f "$REVIEW_DIR/summary-0.md" ]

# ── Reviewer crashes after writing a PASS verdict ──────────────────────────
# A non-zero exit must never end the loop with PASS: the artifact is kept
# for inspection but moved out of the canonical review path.
export FAKE_REVIEW_MODE=pass-then-crash
write_state
output=$(run_hook)
assert_reviewer_failed "$output"
[ -f "$REVIEW_FILE.reviewer-error.1" ]
[ "$(head -n 1 "$REVIEW_FILE.reviewer-error.1")" = "VERDICT: PASS" ]
grep -q 'exit=7' "$PROJECT_DIR/.claude/review-loop.log"
assert_fails_open
[ -f "$REVIEW_FILE.reviewer-error.1" ]
[ -f "$REVIEW_DIR/summary-0.md" ]

# ── Reviewer crashes after writing a FAIL verdict ──────────────────────────
# A crashed reviewer's FAIL artifact is not accepted either; the round
# requires a clean rerun before any verdict is honored.
export FAKE_REVIEW_MODE=fail-then-crash
write_state
output=$(run_hook)
assert_reviewer_failed "$output"
[ -f "$REVIEW_FILE.reviewer-error.1" ]
[ "$(head -n 1 "$REVIEW_FILE.reviewer-error.1")" = "VERDICT: FAIL" ]
grep -q 'exit=5' "$PROJECT_DIR/.claude/review-loop.log"
assert_fails_open
[ -f "$REVIEW_FILE.reviewer-error.1" ]

# ── Two failed invocations in one round keep every artifact ────────────────
# A rerun that also crashes must not overwrite the first quarantined
# artifact: each failed attempt gets its own numbered file.
export FAKE_REVIEW_MODE=pass-then-crash FAKE_COUNT_FILE="$TMP_DIR/attempt-count"
write_state
output=$(run_hook)
assert_reviewer_failed "$output"
[ -f "$REVIEW_FILE.reviewer-error.1" ]
grep -q 'attempt 1' "$REVIEW_FILE.reviewer-error.1"

output=$(run_hook)
jq -e '.decision == "block"' <<< "$output" >/dev/null
[ "$(cat "$PROJECT_DIR/.claude/review-loop-retries")" = "1" ]

(
  cd "$PROJECT_DIR"
  env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" "$RUNNER"
) >/dev/null || true
[ ! -e "$REVIEW_FILE" ]
[ -f "$REVIEW_FILE.reviewer-error.2" ]
grep -q 'attempt 2' "$REVIEW_FILE.reviewer-error.2"

output=$(run_hook)
jq -e '.decision == "approve"' <<< "$output" >/dev/null
[ ! -f "$STATE_FILE" ]
[ -f "$REVIEW_FILE.reviewer-error.1" ]
[ -f "$REVIEW_FILE.reviewer-error.2" ]
[ -f "$REVIEW_DIR/summary-0.md" ]

# ── Hung reviewer killed from outside ──────────────────────────────────────
# Something other than the runner's watchdog (an OOM killer, a user's kill)
# stops a hung reviewer while the hook survives. The loop must not report
# PASS, must keep state for the retry gate, must leave no tracked child
# behind, and must recover when the rerun succeeds. The runner's own timeout
# is covered by review-timeout.sh.
export FAKE_REVIEW_MODE=hang FAKE_REVIEWER_PID_FILE="$REVIEWER_PID_FILE"
write_state
(
  cd "$PROJECT_DIR"
  env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" "$HOOK" <<< '{}' \
    > "$TMP_DIR/hang-hook-output"
) &
HOOK_PID=$!
wait_for_file "$REVIEWER_PID_FILE"
REVIEWER_PID=$(cat "$REVIEWER_PID_FILE")
kill -TERM "$REVIEWER_PID"
wait "$HOOK_PID" || true
HOOK_PID=""
assert_reviewer_failed "$(cat "$TMP_DIR/hang-hook-output")"
assert_stopped "$REVIEWER_PID"
REVIEWER_PID=""
[ ! -e "$REVIEW_FILE.reviewer-error.1" ]
[ ! -e "$PROJECT_DIR/.claude/review-loop-child.pid" ]
grep -q 'exit=143' "$PROJECT_DIR/.claude/review-loop.log"

# Retry gate prompts a rerun, then a successful rerun recovers the loop.
export FAKE_REVIEW_MODE=clean
output=$(run_hook)
jq -e '.decision == "block"' <<< "$output" >/dev/null
[ "$(cat "$PROJECT_DIR/.claude/review-loop-retries")" = "1" ]

(
  cd "$PROJECT_DIR"
  env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" "$RUNNER"
) >/dev/null
[ "$(head -n 1 "$REVIEW_FILE")" = "VERDICT: PASS" ]

output=$(run_hook)
jq -e '.decision == "block"' <<< "$output" >/dev/null
case "$(jq -r '.reason' <<< "$output")" in
  *"missing or incomplete"*)
    ;;
  *)
    printf 'FAIL: recovered review did not require a correction summary: %s\n' \
      "$output" >&2
    exit 1
    ;;
esac

write_summary
output=$(run_hook)
jq -e '.decision == "approve"' <<< "$output" >/dev/null
[ ! -f "$STATE_FILE" ]
[ -f "$REVIEW_DIR/review-1.md" ]
[ -f "$REVIEW_DIR/summary-0.md" ]
[ -f "$REVIEW_DIR/summary-1.md" ]

printf 'reviewer error tests passed\n'
