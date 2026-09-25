#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/stop-hook.sh"
STOP_TREE="$PLUGIN_DIR/scripts/stop-process-tree.sh"
TMP_DIR="$(mktemp -d)"
BIN_DIR="$TMP_DIR/bin"
HOME_DIR="$TMP_DIR/home"
REVIEW_ID="20260925-130000-bac4a1"
BACKGROUND_PIDS=()

cleanup() {
  set +e
  local pid
  for pid in "${BACKGROUND_PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      "$STOP_TREE" "$pid" 1 >/dev/null
    fi
  done
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$BIN_DIR" "$HOME_DIR/.codex"
printf '[features]\nmulti_agent = true\n' > "$HOME_DIR/.codex/config.toml"

cat > "$BIN_DIR/codex" <<'CODEX_EOF'
#!/usr/bin/env bash
case "${FAKE_REVIEW_MODE:-clean}" in
  crash)
    exit 3
    ;;
  slow-pass)
    sleep "${FAKE_REVIEW_SECONDS:-3}"
    printf 'VERDICT: PASS\nslow background review\n'
    ;;
  *)
    printf 'VERDICT: PASS\nclean review\n'
    ;;
esac
CODEX_EOF
chmod +x "$BIN_DIR/codex"

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "$3 does not contain '$2': $1" ;;
  esac
}

assert_single_json_decision() {
  jq -e -s 'length == 1 and (.[0] | type == "object")' <<< "$1" >/dev/null ||
    fail "hook stdout is not exactly one JSON object: $1"
}

write_state() {
  local project_dir="$1"

  mkdir -p "$project_dir/.claude" "$project_dir/reviews/$REVIEW_ID"
  printf '# Review Loop Task Context\n\nbackground rerun test\n' > \
    "$project_dir/reviews/$REVIEW_ID/summary-0.md"
  cat > "$project_dir/.claude/review-loop.local.json" <<STATE_EOF
{
  "active": true,
  "phase": "task",
  "reviewer": "codex",
  "task": "background rerun test",
  "round": 1,
  "max_rounds": 3,
  "review_timeout": 600,
  "review_id": "$REVIEW_ID",
  "started_at": "2026-09-25T13:00:00Z"
}
STATE_EOF
}

write_summary() {
  cat > "$1/reviews/$REVIEW_ID/summary-1.md" <<'SUMMARY_EOF'
## Fixes
- none needed

## Skipped findings
- None

## Quality gates
- shell test: PASS
SUMMARY_EOF
}

# run_hook <project> <hook> [VAR=value ...]
run_hook() {
  local project_dir="$1"
  local hook="$2"
  shift 2
  (
    cd "$project_dir"
    env -i HOME="$HOME_DIR" XDG_CONFIG_HOME="$HOME_DIR/.config" \
      PATH="$BIN_DIR:$PATH" "$@" "$hook" <<< '{}'
  )
}

# Starts the generated runner in the background, the way Claude runs it with
# run_in_background, and waits until it has recorded its PID or, for a
# reviewer that fails at once, already finished.
start_background_runner() {
  local project_dir="$1"
  shift
  (
    cd "$project_dir"
    exec env -i HOME="$HOME_DIR" XDG_CONFIG_HOME="$HOME_DIR/.config" \
      PATH="$BIN_DIR:$PATH" "$@" bash .claude/review-loop-run-codex.sh >/dev/null 2>&1
  ) &
  local runner_pid=$!
  BACKGROUND_PIDS+=("$runner_pid")
  local attempts=0
  while [ ! -f "$project_dir/.claude/review-loop-child.pid" ] && kill -0 "$runner_pid" 2>/dev/null &&
    [ "$attempts" -lt 50 ]; do
    attempts=$((attempts + 1))
    sleep 0.1
  done
  [ -f "$project_dir/.claude/review-loop-child.pid" ] || ! kill -0 "$runner_pid" 2>/dev/null ||
    fail "background runner did not record its PID"
}

# prepare_retry_gate <project>: a first review that crashed, leaving the
# round in addressing with the runner script in place and no artifact.
prepare_retry_gate() {
  local output

  write_state "$1"
  output=$(run_hook "$1" "$HOOK" FAKE_REVIEW_MODE=crash)
  assert_contains "$(jq -r '.reason' <<< "$output")" "did not produce a usable artifact" "crash handoff"
  jq -e '.phase == "addressing"' "$1/.claude/review-loop.local.json" >/dev/null ||
    fail "crashed review did not reach addressing"
}

# ── The rerun instructions use run_in_background, not a tool timeout ──────
for prompt in addressing-review.md addressing-missing-review.md; do
  if grep -q '600000' "$PLUGIN_DIR/prompts/$prompt"; then
    fail "$prompt still asks for a 600000ms Bash timeout"
  fi
  grep -q 'run_in_background' "$PLUGIN_DIR/prompts/$prompt" ||
    fail "$prompt does not ask for run_in_background"
done

PROMPT_PROJECT="$TMP_DIR/prompt"
prepare_retry_gate "$PROMPT_PROJECT"
PROMPT_OUTPUT=$(run_hook "$PROMPT_PROJECT" "$HOOK")
PROMPT_REASON=$(jq -r '.reason' <<< "$PROMPT_OUTPUT")
assert_contains "$PROMPT_REASON" "run_in_background" "retry-gate reason"
assert_contains "$PROMPT_REASON" "completion notification" "retry-gate reason"
case "$PROMPT_REASON" in
  *600000*) fail "retry-gate reason still mentions 600000ms" ;;
esac

# ── The hook waits for a live background rerun, then evaluates it ────────
WAIT_PROJECT="$TMP_DIR/wait"
prepare_retry_gate "$WAIT_PROJECT"
write_summary "$WAIT_PROJECT"
start_background_runner "$WAIT_PROJECT" FAKE_REVIEW_MODE=slow-pass FAKE_REVIEW_SECONDS=3
WAIT_OUTPUT=$(run_hook "$WAIT_PROJECT" "$HOOK")
assert_single_json_decision "$WAIT_OUTPUT"
jq -e '.decision == "approve" and (has("systemMessage") | not)' <<< "$WAIT_OUTPUT" >/dev/null ||
  fail "hook did not accept the PASS from the background rerun: $WAIT_OUTPUT"
[ ! -e "$WAIT_PROJECT/.claude/review-loop.local.json" ] || fail "state left after PASS"
[ "$(head -n 1 "$WAIT_PROJECT/reviews/$REVIEW_ID/review-1.md")" = "VERDICT: PASS" ] ||
  fail "background rerun artifact missing"
WAIT_LOG=$(cat "$WAIT_PROJECT/.claude/review-loop.log")
assert_contains "$WAIT_LOG" "Waiting for the running codex review (runner pid=" "log"
assert_contains "$WAIT_LOG" "The running codex review finished after waiting" "log"
assert_contains "$WAIT_LOG" "Review loop complete" "log"

# A rerun that fails while the hook waits goes through the normal retry gate
# instead of being counted before it finished.
FAILED_RERUN_PROJECT="$TMP_DIR/failed-rerun"
prepare_retry_gate "$FAILED_RERUN_PROJECT"
start_background_runner "$FAILED_RERUN_PROJECT" FAKE_REVIEW_MODE=crash
FAILED_RERUN_OUTPUT=$(run_hook "$FAILED_RERUN_PROJECT" "$HOOK")
jq -e '.decision == "block"' <<< "$FAILED_RERUN_OUTPUT" >/dev/null ||
  fail "a failed background rerun did not reach the retry gate"
[ "$(cat "$FAILED_RERUN_PROJECT/.claude/review-loop-retries")" = "1" ] ||
  fail "retry count is wrong after a failed background rerun"

# ── A stale or reused PID is not waited on ────────────────────────────────
STALE_PROJECT="$TMP_DIR/stale"
prepare_retry_gate "$STALE_PROJECT"
sleep 60 &
UNRELATED_PID=$!
BACKGROUND_PIDS+=("$UNRELATED_PID")
printf '%s\n' "$UNRELATED_PID" > "$STALE_PROJECT/.claude/review-loop-child.pid"
STALE_START=$(date +%s)
STALE_OUTPUT=$(run_hook "$STALE_PROJECT" "$HOOK")
[ $(( $(date +%s) - STALE_START )) -lt 10 ] || fail "hook waited on an unrelated process"
assert_contains "$(jq -r '.reason' <<< "$STALE_OUTPUT")" "has not been completed yet" "stale-pid reason"
grep -q "pid $UNRELATED_PID is not a review runner" "$STALE_PROJECT/.claude/review-loop.log" ||
  fail "reused PID was not logged"
kill "$UNRELATED_PID" 2>/dev/null || true
wait "$UNRELATED_PID" 2>/dev/null || true

DEAD_PROJECT="$TMP_DIR/dead"
prepare_retry_gate "$DEAD_PROJECT"
sleep 0 &
DEAD_PID=$!
wait "$DEAD_PID"
printf '%s\n' "$DEAD_PID" > "$DEAD_PROJECT/.claude/review-loop-child.pid"
DEAD_OUTPUT=$(run_hook "$DEAD_PROJECT" "$HOOK")
assert_contains "$(jq -r '.reason' <<< "$DEAD_OUTPUT")" "has not been completed yet" "dead-pid reason"
grep -q "pid $DEAD_PID is not running" "$DEAD_PROJECT/.claude/review-loop.log" ||
  fail "dead PID was not logged"

# ── The wait stays inside the hook budget ─────────────────────────────────
BUDGET_PLUGIN="$TMP_DIR/budget-plugin"
mkdir -p "$BUDGET_PLUGIN"
cp -R "$PLUGIN_DIR/hooks" "$PLUGIN_DIR/scripts" "$PLUGIN_DIR/prompts" "$BUDGET_PLUGIN/"
jq '(.hooks.Stop[0].hooks[0].timeout) = 64' "$PLUGIN_DIR/hooks/hooks.json" > "$BUDGET_PLUGIN/hooks/hooks.json"
BUDGET_PROJECT="$TMP_DIR/budget"
prepare_retry_gate "$BUDGET_PROJECT"
start_background_runner "$BUDGET_PROJECT" FAKE_REVIEW_MODE=slow-pass FAKE_REVIEW_SECONDS=60
BUDGET_START=$(date +%s)
BUDGET_OUTPUT=$(run_hook "$BUDGET_PROJECT" "$BUDGET_PLUGIN/hooks/stop-hook.sh")
BUDGET_ELAPSED=$(( $(date +%s) - BUDGET_START ))
[ "$BUDGET_ELAPSED" -le 6 ] || fail "hook waited ${BUDGET_ELAPSED}s with a 4s budget"
assert_single_json_decision "$BUDGET_OUTPUT"
jq -e '.decision == "block"' <<< "$BUDGET_OUTPUT" >/dev/null || fail "exhausted wait did not block"
assert_contains "$(jq -r '.reason' <<< "$BUDGET_OUTPUT")" "is still running" "budget reason"
assert_contains "$(jq -r '.reason' <<< "$BUDGET_OUTPUT")" "Do not start another run" "budget reason"
assert_contains "$(jq -r '.systemMessage' <<< "$BUDGET_OUTPUT")" "still running" "budget systemMessage"
grep -q 'the Stop hook budget is spent' "$BUDGET_PROJECT/.claude/review-loop.log" ||
  fail "exhausted wait was not logged"
[ ! -e "$BUDGET_PROJECT/.claude/review-loop-retries" ] || fail "the waiting stop consumed the retry"
jq -e '.phase == "addressing"' "$BUDGET_PROJECT/.claude/review-loop.local.json" >/dev/null ||
  fail "exhausted wait changed the loop state"
RUNNER_PID=$(head -n 1 "$BUDGET_PROJECT/.claude/review-loop-child.pid")
kill -0 "$RUNNER_PID" 2>/dev/null || fail "the hook stopped the background rerun"

printf 'background rerun tests passed\n'
