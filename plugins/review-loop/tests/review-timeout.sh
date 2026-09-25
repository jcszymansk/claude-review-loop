#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/stop-hook.sh"
RESOLVER="$PLUGIN_DIR/scripts/resolve-review-timeout.sh"
HOOK_TIMEOUT_READER="$PLUGIN_DIR/scripts/read-hook-timeout.sh"
SETUP="$PLUGIN_DIR/scripts/setup-review-loop.sh"
TMP_DIR="$(mktemp -d)"
BIN_DIR="$TMP_DIR/bin"
HOME_DIR="$TMP_DIR/home"
REVIEW_ID="20260925-120000-7e0a11"
# Watchdog sleeps get durations derived from this run's PID, so a concurrent
# run of this test is unlikely to match them.
EXIT124_TIMEOUT=$((3000 + ($$ % 3000) * 3))
CLEAN_TIMEOUT=$((EXIT124_TIMEOUT + 1))
SIGNAL_TIMEOUT=$((EXIT124_TIMEOUT + 2))
BACKGROUND_PID=""

# Only processes that still look like this test's fakes are killed, so a
# recorded PID that has since been reused by something else is left alone.
cleanup() {
  set +e
  local pid_file
  local pid
  local command_line

  if [ -n "$BACKGROUND_PID" ] && kill -0 "$BACKGROUND_PID" 2>/dev/null; then
    "$PLUGIN_DIR/scripts/stop-process-tree.sh" "$BACKGROUND_PID" 1 >/dev/null
  fi
  for pid_file in "$TMP_DIR"/*/reviewer.pid "$TMP_DIR"/*/reviewer-child.pid; do
    [ -f "$pid_file" ] || continue
    pid=$(cat "$pid_file")
    command_line=$(ps -o args= -p "$pid" 2>/dev/null)
    case "$command_line" in
      *"$BIN_DIR/codex"*|"sleep 300") kill -KILL "$pid" 2>/dev/null ;;
    esac
  done
  pkill -f "^sleep ($EXIT124_TIMEOUT|$CLEAN_TIMEOUT|$SIGNAL_TIMEOUT|$((EXIT124_TIMEOUT + 3)))\$" 2>/dev/null
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
if [ -n "${FAKE_INVOCATION_FILE:-}" ]; then
  printf 'invoked\n' >> "$FAKE_INVOCATION_FILE"
fi
case "${FAKE_REVIEW_MODE:-clean}" in
  hang|hang-ignore-term)
    if [ "$FAKE_REVIEW_MODE" = "hang-ignore-term" ]; then
      trap '' TERM
    else
      trap 'exit 143' TERM
    fi
    sleep 300 &
    printf '%s\n' "$!" > "$FAKE_STATE_DIR/reviewer-child.pid"
    printf '%s\n' "$$" > "$FAKE_STATE_DIR/reviewer.pid"
    if [ -n "${FAKE_PARTIAL_REVIEW_FILE:-}" ]; then
      printf 'VERDICT: PASS\npartial review written before the hang\n' > "$FAKE_PARTIAL_REVIEW_FILE"
    fi
    printf 'VERDICT: PASS\npartial stdout before the hang\n'
    while :; do
      sleep 1
    done
    ;;
  exit-124)
    printf 'VERDICT: FAIL\nreviewer chose exit status 124\n'
    exit 124
    ;;
  *)
    printf 'VERDICT: PASS\nclean review\n'
    ;;
esac
CODEX_EOF
chmod +x "$BIN_DIR/codex"

# ── helpers ────────────────────────────────────────────────────────────────
is_running() {
  local pid="$1"
  local state

  kill -0 "$pid" 2>/dev/null || return 1
  state=$(ps -o stat= -p "$pid" 2>/dev/null || true)
  case "$state" in
    ''|Z*) return 1 ;;
  esac
}

assert_not_running() {
  local pid="$1"
  local label="$2"
  local attempts=0

  while [ "$attempts" -lt 30 ] && is_running "$pid"; do
    attempts=$((attempts + 1))
    sleep 0.1
  done
  if is_running "$pid"; then
    fail "$label (pid $pid) is still running"
  fi
}

assert_no_process_matching() {
  local pattern="$1"
  local attempts=0

  while [ "$attempts" -lt 30 ] && pgrep -f "$pattern" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    sleep 0.1
  done
  if pgrep -f "$pattern" >/dev/null 2>&1; then
    fail "a process matching '$pattern' outlived the runner"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"

  case "$haystack" in
    *"$needle"*) ;;
    *) fail "$label does not contain '$needle': $haystack" ;;
  esac
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"

  case "$haystack" in
    *"$needle"*) fail "$label unexpectedly contains '$needle': $haystack" ;;
  esac
}

assert_single_json_decision() {
  local output="$1"

  jq -e -s 'length == 1 and (.[0] | type == "object")' <<< "$output" >/dev/null ||
    fail "hook stdout is not exactly one JSON object: $output"
}

quarantine_count() {
  local count=0
  local file

  for file in "$1"/review-1.md.reviewer-error.*; do
    [ -f "$file" ] && count=$((count + 1))
  done
  printf '%s\n' "$count"
}

# Prints the first quarantined review-1.md artifact containing the text.
quarantine_containing() {
  local file

  for file in "$1"/review-1.md.reviewer-error.*; do
    if [ -f "$file" ] && grep -qF "$2" "$file"; then
      printf '%s\n' "$file"
      return 0
    fi
  done
  return 1
}

# write_state <project> <review_timeout|legacy> [phase] [round]
write_state() {
  local project_dir="$1"
  local review_timeout="$2"
  local phase="${3:-task}"
  local round="${4:-1}"
  local timeout_field=""

  mkdir -p "$project_dir/.claude" "$project_dir/reviews/$REVIEW_ID"
  printf '# Review Loop Task Context\n\nreview timeout test\n' > \
    "$project_dir/reviews/$REVIEW_ID/summary-0.md"
  if [ "$review_timeout" != "legacy" ]; then
    timeout_field="\"review_timeout\": $review_timeout,"
  fi
  cat > "$project_dir/.claude/review-loop.local.json" <<STATE_EOF
{
  "active": true,
  "phase": "$phase",
  "reviewer": "codex",
  "task": "review timeout test",
  "round": $round,
  "max_rounds": 3,
  $timeout_field
  "review_id": "$REVIEW_ID",
  "started_at": "2026-09-25T12:00:00Z"
}
STATE_EOF
}

write_summary() {
  local project_dir="$1"
  local round="$2"

  cat > "$project_dir/reviews/$REVIEW_ID/summary-$round.md" <<'SUMMARY_EOF'
## Fixes
- addressed the findings

## Skipped findings
- None

## Quality gates
- shell test: PASS
SUMMARY_EOF
}

invoke_hook() {
  local project_dir="$1"
  local hook="$2"
  shift 2
  (
    cd "$project_dir"
    env -i HOME="$HOME_DIR" XDG_CONFIG_HOME="$HOME_DIR/.config" \
      PATH="$BIN_DIR:$PATH" FAKE_STATE_DIR="$project_dir" "$@" \
      "$hook" <<< '{}'
  )
}

# run_runner <project> [VAR=value ...]; prints stderr, returns the exit status
run_runner() {
  local project_dir="$1"
  shift
  (
    cd "$project_dir"
    env -i HOME="$HOME_DIR" XDG_CONFIG_HOME="$HOME_DIR/.config" \
      PATH="$BIN_DIR:$PATH" FAKE_STATE_DIR="$project_dir" "$@" \
      .claude/review-loop-run-codex.sh >/dev/null
  ) 2>&1
}

# run_bounded <seconds> <output-file> <command...>
# Runs a command that is expected to be stopped by the watchdog, so a broken
# watchdog fails this test instead of hanging it.
run_bounded() {
  local limit="$1"
  local output_file="$2"
  shift 2
  local polls=0
  local status=0

  "$@" > "$output_file" &
  BACKGROUND_PID=$!
  while kill -0 "$BACKGROUND_PID" 2>/dev/null && [ "$polls" -lt $((limit * 10)) ]; do
    polls=$((polls + 1))
    sleep 0.1
  done
  if kill -0 "$BACKGROUND_PID" 2>/dev/null; then
    "$PLUGIN_DIR/scripts/stop-process-tree.sh" "$BACKGROUND_PID" 1 >/dev/null
    fail "command still running after ${limit}s: $*"
  fi
  wait "$BACKGROUND_PID" || status=$?
  BACKGROUND_PID=""
  return "$status"
}

# run_hook <project> <hook> [VAR=value ...]; prints the hook's stdout
run_hook() {
  local output_file

  output_file=$(mktemp "$TMP_DIR/hook-output.XXXXXX")
  run_bounded 30 "$output_file" invoke_hook "$@"
  cat "$output_file"
}

run_resolver() {
  local resolver="$1"
  local project_dir="$2"
  local home_dir="$3"
  shift 3
  (
    cd "$project_dir"
    env -i HOME="$home_dir" XDG_CONFIG_HOME="$home_dir/.config" PATH="$PATH" "$@" "$resolver"
  )
}

assert_resolves() {
  local expected="$1"
  shift
  local output

  output=$(run_resolver "$@") || fail "resolver failed, expected $expected"
  [ "$output" = "$expected" ] || fail "expected review timeout $expected, got $output"
}

assert_rejected() {
  local label="$1"
  shift
  local error_output

  if error_output=$(run_resolver "$@" 2>&1 >/dev/null); then
    fail "resolver accepted $label"
  fi
  assert_contains "$error_output" "Error:" "resolver error for $label"
}

copy_plugin_with_hook_timeout() {
  local destination="$1"
  local hook_timeout="$2"

  mkdir -p "$destination"
  cp -R "$PLUGIN_DIR/hooks" "$PLUGIN_DIR/scripts" "$PLUGIN_DIR/prompts" "$destination/"
  jq --argjson timeout "$hook_timeout" '.hooks.Stop[0].hooks[0].timeout = $timeout' \
    "$PLUGIN_DIR/hooks/hooks.json" > "$destination/hooks/hooks.json"
}

logged_effective_timeout() {
  sed -n 's/.*Review timeout: configured=.*effective=\(-\{0,1\}[0-9]*\)s.*/\1/p' \
    "$1/.claude/review-loop.log" | tail -n 1
}

# ── The Claude Code hook timeout is only a backstop ───────────────────────
[ "$("$HOOK_TIMEOUT_READER")" = "14400" ] ||
  fail "hooks.json Stop timeout is not the 14400s backstop"

# ── Resolver precedence, default, and validation ──────────────────────────
DEFAULT_PROJECT="$TMP_DIR/resolver-default-project"
DEFAULT_HOME="$TMP_DIR/resolver-default-home"
mkdir -p "$DEFAULT_PROJECT" "$DEFAULT_HOME"
assert_resolves 1800 "$RESOLVER" "$DEFAULT_PROJECT" "$DEFAULT_HOME"

PROJECT_ONLY="$TMP_DIR/resolver-project"
PROJECT_ONLY_HOME="$TMP_DIR/resolver-project-home"
mkdir -p "$PROJECT_ONLY" "$PROJECT_ONLY_HOME/.config/review-loop"
printf 'reviewer = "codex"\nreview_timeout = 2400 # forty minutes\n' > "$PROJECT_ONLY/.review-loop.toml"
printf 'review_timeout = 1200\n' > "$PROJECT_ONLY_HOME/.config/review-loop/config.toml"
assert_resolves 2400 "$RESOLVER" "$PROJECT_ONLY" "$PROJECT_ONLY_HOME"

USER_ONLY="$TMP_DIR/resolver-user"
mkdir -p "$USER_ONLY"
printf 'reviewer = "codex"\n' > "$USER_ONLY/.review-loop.toml"
assert_resolves 1200 "$RESOLVER" "$USER_ONLY" "$PROJECT_ONLY_HOME"

assert_resolves 90 "$RESOLVER" "$PROJECT_ONLY" "$PROJECT_ONLY_HOME" \
  env REVIEW_LOOP_REVIEW_TIMEOUT=90
assert_resolves 14340 "$RESOLVER" "$DEFAULT_PROJECT" "$DEFAULT_HOME" \
  env REVIEW_LOOP_REVIEW_TIMEOUT=14340

for invalid in '' 0 00 007 -5 abc 1.5 ' 60' 14341 99999999999; do
  assert_rejected "REVIEW_LOOP_REVIEW_TIMEOUT=$invalid" \
    "$RESOLVER" "$DEFAULT_PROJECT" "$DEFAULT_HOME" env REVIEW_LOOP_REVIEW_TIMEOUT="$invalid"
done
TOO_LARGE_ERROR=$(run_resolver "$RESOLVER" "$DEFAULT_PROJECT" "$DEFAULT_HOME" \
  env REVIEW_LOOP_REVIEW_TIMEOUT=14341 2>&1 >/dev/null || true)
assert_contains "$TOO_LARGE_ERROR" "at most 14340 seconds" "too-large error"

INVALID_PROJECT="$TMP_DIR/resolver-invalid-project"
mkdir -p "$INVALID_PROJECT"
printf 'review_timeout = "1800"\n' > "$INVALID_PROJECT/.review-loop.toml"
assert_rejected "a quoted project review_timeout" "$RESOLVER" "$INVALID_PROJECT" "$DEFAULT_HOME"

INVALID_USER_HOME="$TMP_DIR/resolver-invalid-user-home"
mkdir -p "$INVALID_USER_HOME/.config/review-loop"
printf 'review_timeout = 0\n' > "$INVALID_USER_HOME/.config/review-loop/config.toml"
assert_rejected "a zero user review_timeout" "$RESOLVER" "$DEFAULT_PROJECT" "$INVALID_USER_HOME"

# The upper bound follows the hook timeout declared in hooks.json.
SMALL_PLUGIN="$TMP_DIR/small-plugin"
copy_plugin_with_hook_timeout "$SMALL_PLUGIN" 120
assert_resolves 60 "$SMALL_PLUGIN/scripts/resolve-review-timeout.sh" \
  "$DEFAULT_PROJECT" "$DEFAULT_HOME" env REVIEW_LOOP_REVIEW_TIMEOUT=60
assert_rejected "61s under a 120s hook timeout" \
  "$SMALL_PLUGIN/scripts/resolve-review-timeout.sh" "$DEFAULT_PROJECT" "$DEFAULT_HOME" \
  env REVIEW_LOOP_REVIEW_TIMEOUT=61
assert_rejected "the 1800s default under a 120s hook timeout" \
  "$SMALL_PLUGIN/scripts/resolve-review-timeout.sh" "$DEFAULT_PROJECT" "$DEFAULT_HOME"

# Without a readable hooks.json there is no safe bound, so resolution fails
# and names the file.
BROKEN_PLUGIN="$TMP_DIR/broken-plugin"
copy_plugin_with_hook_timeout "$BROKEN_PLUGIN" 14400
printf 'not json\n' > "$BROKEN_PLUGIN/hooks/hooks.json"
assert_rejected "any value with an unreadable hooks.json" \
  "$BROKEN_PLUGIN/scripts/resolve-review-timeout.sh" "$DEFAULT_PROJECT" "$DEFAULT_HOME" \
  env REVIEW_LOOP_REVIEW_TIMEOUT=60
BROKEN_ERROR=$(run_resolver "$BROKEN_PLUGIN/scripts/resolve-review-timeout.sh" \
  "$DEFAULT_PROJECT" "$DEFAULT_HOME" 2>&1 >/dev/null || true)
assert_contains "$BROKEN_ERROR" "hooks/hooks.json" "unreadable hooks.json error"

# The timeout is read from the stop-hook.sh entry, not from the first entry.
REORDERED_PLUGIN="$TMP_DIR/reordered-plugin"
copy_plugin_with_hook_timeout "$REORDERED_PLUGIN" 300
jq '.hooks.Stop = [{"hooks": [{"type": "command", "command": "/bin/true", "timeout": 5}]}] + .hooks.Stop' \
  "$REORDERED_PLUGIN/hooks/hooks.json" > "$TMP_DIR/reordered-hooks.json"
mv "$TMP_DIR/reordered-hooks.json" "$REORDERED_PLUGIN/hooks/hooks.json"
[ "$("$REORDERED_PLUGIN/scripts/read-hook-timeout.sh")" = "300" ] ||
  fail "hook timeout was not read from the stop-hook.sh entry"

# A config file that cannot be read stops resolution instead of being skipped.
UNREADABLE_PROJECT="$TMP_DIR/resolver-unreadable-project"
mkdir -p "$UNREADABLE_PROJECT"
printf 'review_timeout = 900\n' > "$UNREADABLE_PROJECT/.review-loop.toml"
chmod 000 "$UNREADABLE_PROJECT/.review-loop.toml"
if [ -r "$UNREADABLE_PROJECT/.review-loop.toml" ]; then
  printf 'skipping the unreadable config case: permissions are not enforced\n'
else
  assert_rejected "an unreadable project config" "$RESOLVER" "$UNREADABLE_PROJECT" "$PROJECT_ONLY_HOME"
fi
chmod 644 "$UNREADABLE_PROJECT/.review-loop.toml"

# ── Setup stores the resolved value and rejects invalid ones ──────────────
SETUP_PROJECT="$TMP_DIR/setup-project"
SETUP_HOME="$TMP_DIR/setup-home"
mkdir -p "$SETUP_PROJECT" "$SETUP_HOME/.codex"
printf '[features]\nmulti_agent = true\n' > "$SETUP_HOME/.codex/config.toml"
(
  cd "$SETUP_PROJECT"
  env -i HOME="$SETUP_HOME" XDG_CONFIG_HOME="$SETUP_HOME/.config" PATH="$BIN_DIR:$PATH" \
    REVIEW_LOOP_REVIEWER=codex REVIEW_LOOP_REVIEW_TIMEOUT=900 \
    "$SETUP" "configured timeout" >/dev/null
)
jq -e '.review_timeout == 900 and .phase == "task"' \
  "$SETUP_PROJECT/.claude/review-loop.local.json" >/dev/null ||
  fail "setup did not store review_timeout 900"

SETUP_DEFAULT_PROJECT="$TMP_DIR/setup-default-project"
mkdir -p "$SETUP_DEFAULT_PROJECT"
(
  cd "$SETUP_DEFAULT_PROJECT"
  env -i HOME="$SETUP_HOME" XDG_CONFIG_HOME="$SETUP_HOME/.config" PATH="$BIN_DIR:$PATH" \
    REVIEW_LOOP_REVIEWER=codex "$SETUP" "default timeout" >/dev/null
)
jq -e '.review_timeout == 1800' "$SETUP_DEFAULT_PROJECT/.claude/review-loop.local.json" >/dev/null ||
  fail "setup did not store the default review_timeout"

SETUP_INVALID_PROJECT="$TMP_DIR/setup-invalid-project"
mkdir -p "$SETUP_INVALID_PROJECT"
if (
  cd "$SETUP_INVALID_PROJECT"
  env -i HOME="$SETUP_HOME" XDG_CONFIG_HOME="$SETUP_HOME/.config" PATH="$BIN_DIR:$PATH" \
    REVIEW_LOOP_REVIEWER=codex REVIEW_LOOP_REVIEW_TIMEOUT=abc \
    "$SETUP" "invalid timeout" >/dev/null 2>&1
); then
  fail "setup accepted an invalid review timeout"
fi
[ ! -e "$SETUP_INVALID_PROJECT/.claude/review-loop.local.json" ] ||
  fail "setup wrote state despite an invalid review timeout"

# ── A hung reviewer is stopped by the watchdog ────────────────────────────
HANG_PROJECT="$TMP_DIR/hang"
HANG_REVIEW_DIR="$HANG_PROJECT/reviews/$REVIEW_ID"
write_state "$HANG_PROJECT" 2
HANG_OUTPUT=$(run_hook "$HANG_PROJECT" "$HOOK" FAKE_REVIEW_MODE=hang \
  FAKE_PARTIAL_REVIEW_FILE="$HANG_REVIEW_DIR/review-1.md")
HANG_LOG=$(cat "$HANG_PROJECT/.claude/review-loop.log")

assert_single_json_decision "$HANG_OUTPUT"
jq -e '.decision == "block"' <<< "$HANG_OUTPUT" >/dev/null || fail "timeout did not block: $HANG_OUTPUT"
HANG_REASON=$(jq -r '.reason' <<< "$HANG_OUTPUT")
HANG_MESSAGE=$(jq -r '.systemMessage' <<< "$HANG_OUTPUT")
assert_contains "$HANG_REASON" "timed out after 2 seconds" "timeout reason"
assert_contains "$HANG_REASON" "REVIEW_LOOP_REVIEW_TIMEOUT" "timeout reason"
assert_contains "$HANG_REASON" "review_timeout" "timeout reason"
assert_contains "$HANG_REASON" "bash .claude/review-loop-run-codex.sh" "timeout reason"
assert_contains "$HANG_MESSAGE" "timed out after 2s" "timeout systemMessage"
assert_contains "$HANG_MESSAGE" "REVIEW_LOOP_REVIEW_TIMEOUT" "timeout systemMessage"

assert_contains "$HANG_LOG" "Starting codex review (timeout=2s)" "log"
assert_contains "$HANG_LOG" "review watchdog fired after 2s" "log"
assert_contains "$HANG_LOG" "review watchdog: sent TERM to process tree" "log"
assert_contains "$HANG_LOG" "ERROR: codex review timed out after" "log"
assert_contains "$HANG_LOG" "(limit 2s)" "log"
assert_contains "$HANG_LOG" "Quarantined partial review artifact after timeout" "log"
assert_contains "$HANG_LOG" "codex review finished (exit=124" "log"
assert_contains "$HANG_LOG" "configured=2s" "log"
assert_contains "$HANG_LOG" "effective=2s" "log"
assert_not_contains "$HANG_LOG" "capped" "log"

assert_not_running "$(cat "$HANG_PROJECT/reviewer.pid")" "hung reviewer"
assert_not_running "$(cat "$HANG_PROJECT/reviewer-child.pid")" "hung reviewer's child"
[ ! -e "$HANG_PROJECT/.claude/review-loop-child.pid" ] || fail "child PID file left behind"
[ ! -e "$HANG_PROJECT/.claude/review-loop-timed-out" ] || fail "timeout flag left behind"
[ ! -e "$HANG_REVIEW_DIR/review-1.md" ] || fail "partial review left at the canonical path"
quarantine_containing "$HANG_REVIEW_DIR" "partial review written before the hang" >/dev/null ||
  fail "partial review was not quarantined"
HANG_QUARANTINE_COUNT=$(quarantine_count "$HANG_REVIEW_DIR")
if compgen -G "$HANG_REVIEW_DIR/review-1.md.stdout.*" >/dev/null; then
  fail "stdout capture left in the review directory"
fi
jq -e '.phase == "addressing"' "$HANG_PROJECT/.claude/review-loop.local.json" >/dev/null ||
  fail "timeout did not move the loop to addressing"

# The partial PASS is never accepted: the next stop goes to the retry gate.
write_summary "$HANG_PROJECT" 1
RETRY_OUTPUT=$(run_hook "$HANG_PROJECT" "$HOOK")
assert_single_json_decision "$RETRY_OUTPUT"
jq -e '.decision == "block"' <<< "$RETRY_OUTPUT" >/dev/null ||
  fail "timed-out review was accepted: $RETRY_OUTPUT"
assert_contains "$(jq -r '.reason' <<< "$RETRY_OUTPUT")" "has not been completed yet" "retry gate"

# ── A manual runner rerun still enforces the timeout ──────────────────────
RERUN_STATUS=0
run_bounded 30 "$TMP_DIR/rerun.out" run_runner "$HANG_PROJECT" FAKE_REVIEW_MODE=hang \
  FAKE_PARTIAL_REVIEW_FILE="$HANG_REVIEW_DIR/review-1.md" || RERUN_STATUS=$?
RERUN_STDERR=$(cat "$TMP_DIR/rerun.out")
[ "$RERUN_STATUS" -eq 124 ] || fail "manual rerun exited $RERUN_STATUS instead of 124"
assert_contains "$RERUN_STDERR" "codex review timed out after" "manual rerun stderr"
assert_contains "$RERUN_STDERR" "REVIEW_LOOP_REVIEW_TIMEOUT" "manual rerun stderr"
assert_not_running "$(cat "$HANG_PROJECT/reviewer.pid")" "rerun reviewer"
assert_not_running "$(cat "$HANG_PROJECT/reviewer-child.pid")" "rerun reviewer's child"
[ ! -e "$HANG_REVIEW_DIR/review-1.md" ] || fail "manual rerun left a partial review"
[ "$(quarantine_count "$HANG_REVIEW_DIR")" -gt "$HANG_QUARANTINE_COUNT" ] ||
  fail "manual rerun did not quarantine its partial review"
[ -f "$HANG_REVIEW_DIR/review-1.md.reviewer-error.1" ] || fail "first quarantine was overwritten"
[ ! -e "$HANG_PROJECT/.claude/review-loop-child.pid" ] || fail "manual rerun left its PID file"
[ -f "$HANG_PROJECT/.claude/review-loop-timed-out" ] || fail "manual rerun did not record the timeout"

# The retry gate then fails open without a PASS and cleans every runtime file.
FINAL_OUTPUT=$(run_hook "$HANG_PROJECT" "$HOOK")
jq -e '.decision == "approve"' <<< "$FINAL_OUTPUT" >/dev/null || fail "retry gate did not fail open"
assert_single_json_decision "$FINAL_OUTPUT"
assert_contains "$(jq -r '.systemMessage' <<< "$FINAL_OUTPUT")" "timed out after 2s on the rerun" \
  "fail-open systemMessage"
grep -q 'ERROR: the last codex run timed out (limit 2s' "$HANG_PROJECT/.claude/review-loop.log" ||
  fail "rerun timeout was not logged by the retry gate"
[ ! -e "$HANG_PROJECT/.claude/review-loop.local.json" ] || fail "state left after fail-open"
[ ! -e "$HANG_PROJECT/.claude/review-loop-timed-out" ] || fail "timeout flag left after cleanup"
[ -f "$HANG_REVIEW_DIR/review-1.md.reviewer-error.1" ] || fail "review history was removed"

# ── A reviewer that ignores TERM is KILLed after the grace period ─────────
STUBBORN_PROJECT="$TMP_DIR/stubborn"
write_state "$STUBBORN_PROJECT" 2
STUBBORN_OUTPUT=$(run_hook "$STUBBORN_PROJECT" "$HOOK" FAKE_REVIEW_MODE=hang-ignore-term)
assert_single_json_decision "$STUBBORN_OUTPUT"
assert_contains "$(jq -r '.systemMessage' <<< "$STUBBORN_OUTPUT")" "timed out after 2s" "systemMessage"
STUBBORN_LOG=$(cat "$STUBBORN_PROJECT/.claude/review-loop.log")
assert_contains "$STUBBORN_LOG" "review watchdog: escalated to KILL" "log"
assert_contains "$STUBBORN_LOG" "stopped after KILL" "log"
assert_not_running "$(cat "$STUBBORN_PROJECT/reviewer.pid")" "TERM-ignoring reviewer"
assert_not_running "$(cat "$STUBBORN_PROJECT/reviewer-child.pid")" "TERM-ignoring reviewer's child"
[ ! -e "$STUBBORN_PROJECT/.claude/review-loop-child.pid" ] || fail "child PID file left behind"
[ ! -e "$STUBBORN_PROJECT/reviews/$REVIEW_ID/review-1.md" ] || fail "partial review left behind"
if compgen -G "$STUBBORN_PROJECT/reviews/$REVIEW_ID/review-1.md.stdout.*" >/dev/null; then
  fail "stdout capture of a KILLed dispatcher left in the review directory"
fi
quarantine_containing "$STUBBORN_PROJECT/reviews/$REVIEW_ID" "partial stdout before the hang" >/dev/null ||
  fail "partial stdout was not quarantined"

# ── A reviewer that exits 124 by itself is not a timeout ──────────────────
EXIT124_PROJECT="$TMP_DIR/exit-124"
write_state "$EXIT124_PROJECT" "$EXIT124_TIMEOUT"
EXIT124_OUTPUT=$(run_hook "$EXIT124_PROJECT" "$HOOK" FAKE_REVIEW_MODE=exit-124)
assert_single_json_decision "$EXIT124_OUTPUT"
jq -e '.decision == "block"' <<< "$EXIT124_OUTPUT" >/dev/null || fail "exit 124 did not block"
assert_not_contains "$(jq -r '.reason' <<< "$EXIT124_OUTPUT")" "timed out" "exit-124 reason"
assert_not_contains "$(jq -r '.systemMessage' <<< "$EXIT124_OUTPUT")" "timed out" "exit-124 systemMessage"
assert_contains "$(jq -r '.reason' <<< "$EXIT124_OUTPUT")" "did not produce a usable artifact" "exit-124 reason"
EXIT124_LOG=$(cat "$EXIT124_PROJECT/.claude/review-loop.log")
assert_contains "$EXIT124_LOG" "codex finished (exit=124" "log"
assert_not_contains "$EXIT124_LOG" "timed out" "log"
assert_not_contains "$EXIT124_LOG" "watchdog" "log"
[ -f "$EXIT124_PROJECT/reviews/$REVIEW_ID/review-1.md.reviewer-error.1" ] ||
  fail "exit-124 artifact was not quarantined as a reviewer error"
[ ! -e "$EXIT124_PROJECT/.claude/review-loop-timed-out" ] || fail "exit 124 wrote a timeout flag"
assert_no_process_matching "^sleep $EXIT124_TIMEOUT\$"

# ── A reviewer that finishes first stops the watchdog and its sleep ───────
CLEAN_PROJECT="$TMP_DIR/clean"
write_state "$CLEAN_PROJECT" "$CLEAN_TIMEOUT"
CLEAN_OUTPUT=$(run_hook "$CLEAN_PROJECT" "$HOOK" FAKE_REVIEW_MODE=clean)
assert_single_json_decision "$CLEAN_OUTPUT"
assert_contains "$(jq -r '.reason' <<< "$CLEAN_OUTPUT")" "round 1 completed" "clean reason"
[ "$(head -n 1 "$CLEAN_PROJECT/reviews/$REVIEW_ID/review-1.md")" = "VERDICT: PASS" ] ||
  fail "clean review was not captured"
grep -q "^REVIEW_TIMEOUT='$CLEAN_TIMEOUT'$" "$CLEAN_PROJECT/.claude/review-loop-run-codex.sh" ||
  fail "runner does not carry the configured timeout"
assert_no_process_matching "^sleep $CLEAN_TIMEOUT\$"

# ── A signal to the runner stops the reviewer and the watchdog ────────────
SIGNAL_PROJECT="$TMP_DIR/signal"
write_state "$SIGNAL_PROJECT" "$SIGNAL_TIMEOUT" addressing
cp "$CLEAN_PROJECT/.claude/review-loop-codex-prompt.txt" "$SIGNAL_PROJECT/.claude/"
sed -e "s|^REVIEW_TIMEOUT='$CLEAN_TIMEOUT'$|REVIEW_TIMEOUT='$SIGNAL_TIMEOUT'|" \
  -e "s|$CLEAN_PROJECT|$SIGNAL_PROJECT|g" \
  "$CLEAN_PROJECT/.claude/review-loop-run-codex.sh" > "$SIGNAL_PROJECT/.claude/review-loop-run-codex.sh"
chmod +x "$SIGNAL_PROJECT/.claude/review-loop-run-codex.sh"
(
  cd "$SIGNAL_PROJECT"
  exec env -i HOME="$HOME_DIR" XDG_CONFIG_HOME="$HOME_DIR/.config" PATH="$BIN_DIR:$PATH" \
    FAKE_STATE_DIR="$SIGNAL_PROJECT" FAKE_REVIEW_MODE=hang \
    .claude/review-loop-run-codex.sh >/dev/null 2>&1
) &
BACKGROUND_PID=$!
attempts=0
while [ ! -f "$SIGNAL_PROJECT/reviewer.pid" ] && [ "$attempts" -lt 100 ]; do
  attempts=$((attempts + 1))
  sleep 0.1
done
[ -f "$SIGNAL_PROJECT/reviewer.pid" ] || fail "runner did not start the reviewer"
kill -TERM "$BACKGROUND_PID"
SIGNAL_STATUS=0
wait "$BACKGROUND_PID" || SIGNAL_STATUS=$?
BACKGROUND_PID=""
[ "$SIGNAL_STATUS" -eq 143 ] || fail "signalled runner exited $SIGNAL_STATUS instead of 143"
assert_not_running "$(cat "$SIGNAL_PROJECT/reviewer.pid")" "reviewer of a signalled runner"
assert_not_running "$(cat "$SIGNAL_PROJECT/reviewer-child.pid")" "reviewer child of a signalled runner"
assert_no_process_matching "^sleep $SIGNAL_TIMEOUT\$"
[ ! -e "$SIGNAL_PROJECT/.claude/review-loop-child.pid" ] || fail "signalled runner left its PID file"
[ ! -e "$SIGNAL_PROJECT/.claude/review-loop-timed-out" ] || fail "a signal was recorded as a timeout"
grep -q 'review runner received a termination signal' "$SIGNAL_PROJECT/.claude/review-loop.log" ||
  fail "runner signal was not logged"

# ── The hooks.json timeout caps the configured limit ──────────────────────
CAPPED_PLUGIN="$TMP_DIR/capped-plugin"
copy_plugin_with_hook_timeout "$CAPPED_PLUGIN" 70
CAPPED_PROJECT="$TMP_DIR/capped"
write_state "$CAPPED_PROJECT" 1800
CAPPED_OUTPUT=$(run_hook "$CAPPED_PROJECT" "$CAPPED_PLUGIN/hooks/stop-hook.sh" FAKE_REVIEW_MODE=hang)
CAPPED_LIMIT=$(logged_effective_timeout "$CAPPED_PROJECT")
case "$CAPPED_LIMIT" in
  1|2|3|4|5|6|7|8|9|10) ;;
  *) fail "unexpected effective timeout under a 70s hook timeout: '$CAPPED_LIMIT'" ;;
esac
CAPPED_LOG=$(cat "$CAPPED_PROJECT/.claude/review-loop.log")
assert_contains "$CAPPED_LOG" "hook_timeout=70s" "log"
assert_contains "$CAPPED_LOG" "WARN: review timeout capped from 1800s to ${CAPPED_LIMIT}s" "log"
assert_contains "$CAPPED_LOG" "(limit ${CAPPED_LIMIT}s)" "log"
assert_contains "$CAPPED_LOG" "Starting codex review (timeout=${CAPPED_LIMIT}s)" "log"
# The script keeps the configured limit for manual reruns outside the hook.
grep -q "^REVIEW_TIMEOUT='1800'$" "$CAPPED_PROJECT/.claude/review-loop-run-codex.sh" ||
  fail "runner does not carry the configured timeout"
assert_single_json_decision "$CAPPED_OUTPUT"
assert_contains "$(jq -r '.systemMessage' <<< "$CAPPED_OUTPUT")" "timed out after ${CAPPED_LIMIT}s" "capped systemMessage"
assert_not_running "$(cat "$CAPPED_PROJECT/reviewer.pid")" "capped reviewer"

# ── No time left in the hook: the reviewer is never started ───────────────
EXHAUSTED_PLUGIN="$TMP_DIR/exhausted-plugin"
copy_plugin_with_hook_timeout "$EXHAUSTED_PLUGIN" 60
EXHAUSTED_PROJECT="$TMP_DIR/exhausted"
write_state "$EXHAUSTED_PROJECT" 1800
EXHAUSTED_OUTPUT=$(run_hook "$EXHAUSTED_PROJECT" "$EXHAUSTED_PLUGIN/hooks/stop-hook.sh" \
  FAKE_REVIEW_MODE=clean FAKE_INVOCATION_FILE="$EXHAUSTED_PROJECT/invocations")
[ ! -e "$EXHAUSTED_PROJECT/invocations" ] || fail "reviewer started without any time left"
assert_single_json_decision "$EXHAUSTED_OUTPUT"
jq -e '.decision == "block"' <<< "$EXHAUSTED_OUTPUT" >/dev/null || fail "exhausted budget did not block"
assert_contains "$(jq -r '.systemMessage' <<< "$EXHAUSTED_OUTPUT")" "timed out" "exhausted systemMessage"
assert_contains "$(jq -r '.reason' <<< "$EXHAUSTED_OUTPUT")" "timed out before it started" "exhausted reason"
grep -q 'ERROR: no time left for the reviewer' "$EXHAUSTED_PROJECT/.claude/review-loop.log" ||
  fail "exhausted budget was not logged"
grep -q "^REVIEW_TIMEOUT='1800'$" "$EXHAUSTED_PROJECT/.claude/review-loop-run-codex.sh" ||
  fail "runner for a manual rerun does not carry the configured timeout"
jq -e '.phase == "addressing"' "$EXHAUSTED_PROJECT/.claude/review-loop.local.json" >/dev/null ||
  fail "exhausted budget did not hand over to the retry gate"

# ── The start time survives the FAIL → next round re-exec ─────────────────
INHERIT_PLUGIN="$TMP_DIR/inherit-plugin"
copy_plugin_with_hook_timeout "$INHERIT_PLUGIN" 90
INHERIT_PROJECT="$TMP_DIR/inherit"
write_state "$INHERIT_PROJECT" 1800
run_hook "$INHERIT_PROJECT" "$INHERIT_PLUGIN/hooks/stop-hook.sh" \
  FAKE_REVIEW_MODE=clean REVIEW_LOOP_HOOK_STARTED_AT="$(( $(date +%s) - 10 ))" >/dev/null
INHERITED_LIMIT=$(logged_effective_timeout "$INHERIT_PROJECT")
case "$INHERITED_LIMIT" in
  12|13|14|15|16|17|18|19|20) ;;
  *) fail "inherited start time was not honored (effective '$INHERITED_LIMIT')" ;;
esac
grep -q 'start time: inherited from the re-executed hook' "$INHERIT_PROJECT/.claude/review-loop.log" ||
  fail "inherited start time was not logged"

FUTURE_PROJECT="$TMP_DIR/future-start"
write_state "$FUTURE_PROJECT" 1800
run_hook "$FUTURE_PROJECT" "$HOOK" FAKE_REVIEW_MODE=clean \
  REVIEW_LOOP_HOOK_STARTED_AT="$(( $(date +%s) + 1000 ))" >/dev/null
grep -q 'WARN: ignoring REVIEW_LOOP_HOOK_STARTED_AT=.* in the future' \
  "$FUTURE_PROJECT/.claude/review-loop.log" || fail "future start time was not rejected"
grep -q 'start time: this invocation' "$FUTURE_PROJECT/.claude/review-loop.log" ||
  fail "hook did not fall back to its own start time"

for bad_start in 0123 12x 1234567890123; do
  BAD_START_PROJECT="$TMP_DIR/bad-start-$bad_start"
  write_state "$BAD_START_PROJECT" 1800
  BAD_START_OUTPUT=$(run_hook "$BAD_START_PROJECT" "$HOOK" FAKE_REVIEW_MODE=clean \
    REVIEW_LOOP_HOOK_STARTED_AT="$bad_start")
  assert_single_json_decision "$BAD_START_OUTPUT"
  jq -e '.decision == "block"' <<< "$BAD_START_OUTPUT" >/dev/null ||
    fail "REVIEW_LOOP_HOOK_STARTED_AT=$bad_start broke the review"
  grep -q "WARN: ignoring REVIEW_LOOP_HOOK_STARTED_AT=$bad_start" "$BAD_START_PROJECT/.claude/review-loop.log" ||
    fail "REVIEW_LOOP_HOOK_STARTED_AT=$bad_start was not rejected"
done

EXEC_PROJECT="$TMP_DIR/exec"
write_state "$EXEC_PROJECT" 1800 addressing 1
printf 'VERDICT: FAIL\nneeds correction\n' > "$EXEC_PROJECT/reviews/$REVIEW_ID/review-1.md"
write_summary "$EXEC_PROJECT" 1
EXEC_OUTPUT=$(run_hook "$EXEC_PROJECT" "$HOOK" FAKE_REVIEW_MODE=clean)
assert_single_json_decision "$EXEC_OUTPUT"
jq -e '.round == 2 and .phase == "addressing"' "$EXEC_PROJECT/.claude/review-loop.local.json" >/dev/null ||
  fail "FAIL round did not advance"
grep -q 'start time: inherited from the re-executed hook' "$EXEC_PROJECT/.claude/review-loop.log" ||
  fail "re-executed hook reset the Stop hook clock"

# ── Legacy state without review_timeout ───────────────────────────────────
LEGACY_PROJECT="$TMP_DIR/legacy"
write_state "$LEGACY_PROJECT" legacy
run_hook "$LEGACY_PROJECT" "$HOOK" FAKE_REVIEW_MODE=clean REVIEW_LOOP_REVIEW_TIMEOUT=45 >/dev/null
grep -q 'Review timeout 45s: resolved at hook time for legacy state' \
  "$LEGACY_PROJECT/.claude/review-loop.log" || fail "legacy state did not resolve at hook time"
grep -q "^REVIEW_TIMEOUT='45'$" "$LEGACY_PROJECT/.claude/review-loop-run-codex.sh" ||
  fail "legacy runner does not carry the hook-time timeout"

LEGACY_INVALID_PROJECT="$TMP_DIR/legacy-invalid"
write_state "$LEGACY_INVALID_PROJECT" legacy
run_hook "$LEGACY_INVALID_PROJECT" "$HOOK" FAKE_REVIEW_MODE=clean REVIEW_LOOP_REVIEW_TIMEOUT=abc >/dev/null
grep -q 'Review timeout 1800s: default for legacy state' \
  "$LEGACY_INVALID_PROJECT/.claude/review-loop.log" || fail "legacy state did not fall back to the default"
grep -q "^REVIEW_TIMEOUT='1800'$" "$LEGACY_INVALID_PROJECT/.claude/review-loop-run-codex.sh" ||
  fail "legacy runner does not carry the default timeout"

# ── A malformed review_timeout in state fails open ────────────────────────
MALFORMED_PROJECT="$TMP_DIR/malformed"
for malformed in '"1800"' 0 1.5 -3; do
  write_state "$MALFORMED_PROJECT" "$malformed"
  MALFORMED_OUTPUT=$(run_hook "$MALFORMED_PROJECT" "$HOOK" FAKE_REVIEW_MODE=clean)
  jq -e '.decision == "approve"' <<< "$MALFORMED_OUTPUT" >/dev/null ||
    fail "malformed review_timeout $malformed did not fail open"
  [ ! -e "$MALFORMED_PROJECT/.claude/review-loop.local.json" ] ||
    fail "malformed review_timeout $malformed left state behind"
done

# Integral numbers in other notations: depending on the jq version they are
# printed as a plain integer (a normal review) or not (fail open), but never
# break the hook.
NOTATION_PROJECT="$TMP_DIR/notation"
for notation in 1800.0 1e3; do
  write_state "$NOTATION_PROJECT" "$notation"
  PRINTED=$(jq -r '.review_timeout' "$NOTATION_PROJECT/.claude/review-loop.local.json")
  NOTATION_OUTPUT=$(run_hook "$NOTATION_PROJECT" "$HOOK" FAKE_REVIEW_MODE=clean)
  assert_single_json_decision "$NOTATION_OUTPUT"
  case "$PRINTED" in
    *[!0-9]*)
      jq -e '.decision == "approve"' <<< "$NOTATION_OUTPUT" >/dev/null ||
        fail "review_timeout $notation (printed $PRINTED) did not fail open"
      grep -q "review_timeout in state is not a plain positive integer: $PRINTED" \
        "$NOTATION_PROJECT/.claude/review-loop.log" || fail "review_timeout $notation was not logged"
      ;;
    *)
      jq -e '.decision == "block"' <<< "$NOTATION_OUTPUT" >/dev/null ||
        fail "review_timeout $notation (printed $PRINTED) did not run the review"
      ;;
  esac
  rm -rf "$NOTATION_PROJECT"
done

# ── stop-process-tree.sh ──────────────────────────────────────────────────
STOP_TREE="$PLUGIN_DIR/scripts/stop-process-tree.sh"
STOP_STATUS=0
"$STOP_TREE" abc 1 >/dev/null 2>&1 || STOP_STATUS=$?
[ "$STOP_STATUS" -eq 2 ] || fail "stop-process-tree.sh accepted an invalid pid (status $STOP_STATUS)"
STOP_STATUS=0
"$STOP_TREE" 12345 x >/dev/null 2>&1 || STOP_STATUS=$?
[ "$STOP_STATUS" -eq 2 ] || fail "stop-process-tree.sh accepted an invalid grace (status $STOP_STATUS)"

sleep 1 &
FINISHED_PID=$!
wait "$FINISHED_PID"
STOP_STATUS=0
"$STOP_TREE" "$FINISHED_PID" 1 >/dev/null || STOP_STATUS=$?
[ "$STOP_STATUS" -eq 3 ] || fail "stop-process-tree.sh signalled a finished process (status $STOP_STATUS)"

# A TERM-ignoring process that keeps forking during the grace period must
# not leave any child behind.
FORKER_DIR="$TMP_DIR/forker"
mkdir -p "$FORKER_DIR"
FORK_SLEEP=$((EXIT124_TIMEOUT + 3))
bash -c "trap '' TERM; while :; do sleep $FORK_SLEEP & echo \$! >> '$FORKER_DIR/children'; sleep 0.1; done" &
BACKGROUND_PID=$!
sleep 0.5
FORKER_OUTPUT=$("$STOP_TREE" "$BACKGROUND_PID" 1)
wait "$BACKGROUND_PID" 2>/dev/null || true
BACKGROUND_PID=""
assert_contains "$FORKER_OUTPUT" "escalated to KILL" "stop-process-tree.sh output"
while IFS= read -r forked_pid; do
  assert_not_running "$forked_pid" "child forked during the grace period"
done < "$FORKER_DIR/children"
assert_no_process_matching "^sleep $FORK_SLEEP\$"

# ── quarantine-review-artifact.sh ─────────────────────────────────────────
QUARANTINE="$PLUGIN_DIR/scripts/quarantine-review-artifact.sh"
QUARANTINE_DIR="$TMP_DIR/quarantine"
mkdir -p "$QUARANTINE_DIR"
QUARANTINE_STATUS=0
"$QUARANTINE" >/dev/null 2>&1 || QUARANTINE_STATUS=$?
[ "$QUARANTINE_STATUS" -eq 2 ] || fail "quarantine without arguments exited $QUARANTINE_STATUS"
QUARANTINE_STATUS=0
"$QUARANTINE" "$QUARANTINE_DIR/review-1.md" >/dev/null 2>&1 || QUARANTINE_STATUS=$?
[ "$QUARANTINE_STATUS" -eq 1 ] || fail "quarantine of a missing file exited $QUARANTINE_STATUS"
printf 'existing\n' > "$QUARANTINE_DIR/review-1.md.reviewer-error.1"
printf 'review\n' > "$QUARANTINE_DIR/review-1.md"
printf 'capture\n' > "$QUARANTINE_DIR/capture"
[ "$("$QUARANTINE" "$QUARANTINE_DIR/review-1.md")" = "$QUARANTINE_DIR/review-1.md.reviewer-error.2" ] ||
  fail "quarantine did not take the next free number"
[ "$("$QUARANTINE" "$QUARANTINE_DIR/review-1.md" "$QUARANTINE_DIR/capture")" = \
  "$QUARANTINE_DIR/review-1.md.reviewer-error.3" ] || fail "quarantine of a second source did not continue the numbering"
[ "$(cat "$QUARANTINE_DIR/review-1.md.reviewer-error.1")" = "existing" ] ||
  fail "quarantine overwrote an earlier artifact"
[ ! -e "$QUARANTINE_DIR/review-1.md" ] && [ ! -e "$QUARANTINE_DIR/capture" ] ||
  fail "quarantine left its source behind"

printf 'review timeout tests passed\n'
