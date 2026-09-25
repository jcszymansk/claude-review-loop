#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/stop-hook.sh"
TMP_DIR="$(mktemp -d)"
BIN_DIR="$TMP_DIR/bin"
HOME_DIR="$TMP_DIR/home"
REVIEW_ID="20260925-140000-fa11ed"

cleanup() {
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
  break-state)
    rm -f .claude/review-loop.local.json
    mkdir .claude/review-loop.local.json
    printf 'VERDICT: PASS\nreview that broke the state file\n'
    ;;
  *)
    printf 'VERDICT: PASS\nclean review\n'
    ;;
esac
CODEX_EOF
chmod +x "$BIN_DIR/codex"

# write_state <project> [phase] [reviewer] [review_id] [active]
write_state() {
  local project_dir="$1"
  local phase="${2:-task}"
  local reviewer="${3:-codex}"
  local review_id="${4:-$REVIEW_ID}"
  local active="${5:-true}"

  mkdir -p "$project_dir/.claude" "$project_dir/reviews/$REVIEW_ID"
  printf '# Review Loop Task Context\n\nfail-open test\n' > \
    "$project_dir/reviews/$REVIEW_ID/summary-0.md"
  cat > "$project_dir/.claude/review-loop.local.json" <<STATE_EOF
{
  "active": $active,
  "phase": "$phase",
  "reviewer": "$reviewer",
  "task": "fail-open test",
  "round": 1,
  "max_rounds": 3,
  "review_timeout": 600,
  "review_id": "$review_id",
  "started_at": "2026-09-25T14:00:00Z"
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

# run_hook <project> [hook] [VAR=value ...]
run_hook() {
  local project_dir="$1"
  local hook="${2:-$HOOK}"
  shift
  [ "$#" -gt 0 ] && shift
  (
    cd "$project_dir"
    env -i HOME="$HOME_DIR" XDG_CONFIG_HOME="$HOME_DIR/.config" \
      PATH="$BIN_DIR:$PATH" "$@" "$hook" <<< '{}'
  )
}

# assert_fail_open <label> <hook output> <expected cause>
assert_fail_open() {
  local label="$1"
  local output="$2"
  local cause="$3"
  local message

  jq -e -s 'length == 1 and (.[0] | type == "object")' <<< "$output" >/dev/null ||
    fail "$label: hook stdout is not exactly one JSON object: $output"
  jq -e '.decision == "approve"' <<< "$output" >/dev/null ||
    fail "$label: decision is not approve: $output"
  message=$(jq -r '.systemMessage // empty' <<< "$output")
  case "$message" in
    *"$cause"*) ;;
    *) fail "$label: systemMessage does not name the cause '$cause': $output" ;;
  esac
  case "$message" in
    *".claude/review-loop.log"*) ;;
    *) fail "$label: systemMessage does not name the log file: $output" ;;
  esac
}

assert_silent_approve() {
  local label="$1"
  local output="$2"

  jq -e -s 'length == 1' <<< "$output" >/dev/null || fail "$label: not one JSON object: $output"
  jq -e '.decision == "approve" and (has("systemMessage") | not)' <<< "$output" >/dev/null ||
    fail "$label: expected a silent approve: $output"
}

# ── Silent approves: no active loop, and an accepted PASS ─────────────────
NO_STATE_PROJECT="$TMP_DIR/no-state"
mkdir -p "$NO_STATE_PROJECT"
assert_silent_approve "no active loop" "$(run_hook "$NO_STATE_PROJECT")"

PASS_PROJECT="$TMP_DIR/pass"
write_state "$PASS_PROJECT" addressing
printf 'VERDICT: PASS\nall good\n' > "$PASS_PROJECT/reviews/$REVIEW_ID/review-1.md"
write_summary "$PASS_PROJECT"
assert_silent_approve "PASS" "$(run_hook "$PASS_PROJECT")"

# ── Retry exhausted ───────────────────────────────────────────────────────
RETRY_PROJECT="$TMP_DIR/retry"
write_state "$RETRY_PROJECT" addressing
printf '#!/usr/bin/env bash\nexit 1\n' > "$RETRY_PROJECT/.claude/review-loop-run-codex.sh"
printf '1\n' > "$RETRY_PROJECT/.claude/review-loop-retries"
assert_fail_open "retry exhausted" "$(run_hook "$RETRY_PROJECT")" \
  "no codex review was produced after the retry"
[ ! -e "$RETRY_PROJECT/.claude/review-loop.local.json" ] || fail "retry exhausted: state left behind"

# ── Orphaned state ────────────────────────────────────────────────────────
ORPHAN_PROJECT="$TMP_DIR/orphan"
write_state "$ORPHAN_PROJECT" addressing
assert_fail_open "orphaned state" "$(run_hook "$ORPHAN_PROJECT")" "orphaned state"

# ── Malformed state ───────────────────────────────────────────────────────
MALFORMED_PROJECT="$TMP_DIR/malformed"
mkdir -p "$MALFORMED_PROJECT/.claude"
printf '{not json\n' > "$MALFORMED_PROJECT/.claude/review-loop.local.json"
assert_fail_open "malformed JSON" "$(run_hook "$MALFORMED_PROJECT")" "malformed state file"

BAD_ID_PROJECT="$TMP_DIR/bad-id"
write_state "$BAD_ID_PROJECT" task codex "../../escape"
assert_fail_open "invalid review_id" "$(run_hook "$BAD_ID_PROJECT")" \
  "malformed state file (invalid review_id)"

UNSUPPORTED_PROJECT="$TMP_DIR/unsupported"
write_state "$UNSUPPORTED_PROJECT" task gemini
assert_fail_open "unsupported reviewer" "$(run_hook "$UNSUPPORTED_PROJECT")" "unsupported reviewer"

UNKNOWN_PHASE_PROJECT="$TMP_DIR/unknown-phase"
write_state "$UNKNOWN_PHASE_PROJECT" reviewing
assert_fail_open "unknown phase" "$(run_hook "$UNKNOWN_PHASE_PROJECT")" "unknown phase"

INACTIVE_PROJECT="$TMP_DIR/inactive"
write_state "$INACTIVE_PROJECT" task codex "$REVIEW_ID" false
assert_fail_open "inactive state" "$(run_hook "$INACTIVE_PROJECT")" "marks the loop as inactive"

# ── Phase transition failure ──────────────────────────────────────────────
TRANSITION_PROJECT="$TMP_DIR/transition"
write_state "$TRANSITION_PROJECT"
assert_fail_open "phase transition" \
  "$(run_hook "$TRANSITION_PROJECT" "$HOOK" FAKE_REVIEW_MODE=break-state 2>/dev/null)" "phase transition failed"

# ── Prompt that cannot be rendered ────────────────────────────────────────
BROKEN_PROMPTS_PLUGIN="$TMP_DIR/broken-prompts-plugin"
mkdir -p "$BROKEN_PROMPTS_PLUGIN"
cp -R "$PLUGIN_DIR/hooks" "$PLUGIN_DIR/scripts" "$PLUGIN_DIR/prompts" "$BROKEN_PROMPTS_PLUGIN/"
rm "$BROKEN_PROMPTS_PLUGIN/prompts/addressing-verdict.md"
RENDER_PROJECT="$TMP_DIR/render"
write_state "$RENDER_PROJECT" addressing
printf 'no verdict here\n' > "$RENDER_PROJECT/reviews/$REVIEW_ID/review-1.md"
write_summary "$RENDER_PROJECT"
assert_fail_open "missing prompt template" \
  "$(run_hook "$RENDER_PROJECT" "$BROKEN_PROMPTS_PLUGIN/hooks/stop-hook.sh")" \
  "the verdict prompt could not be rendered"

# ── ERR trap ──────────────────────────────────────────────────────────────
# A directory where the prompt file belongs makes an unguarded write fail.
ERR_PROJECT="$TMP_DIR/err"
write_state "$ERR_PROJECT"
mkdir -p "$ERR_PROJECT/.claude/review-loop-codex-prompt.txt"
ERR_OUTPUT=$(run_hook "$ERR_PROJECT" 2>/dev/null)
assert_fail_open "ERR trap" "$ERR_OUTPUT" "internal error in the Stop hook"
grep -q 'ERROR: hook exited via ERR trap' "$ERR_PROJECT/.claude/review-loop.log" ||
  fail "ERR trap was not logged"

# ── jq missing: the printf fallback still produces the message ────────────
NO_JQ_BIN="$TMP_DIR/no-jq-bin"
mkdir -p "$NO_JQ_BIN"
for tool in bash env cat date dirname mkdir rm tr printf; do
  tool_path=$(command -v "$tool" 2>/dev/null || true)
  case "$tool_path" in
    /*) ln -s "$tool_path" "$NO_JQ_BIN/$tool" ;;
  esac
done
NO_JQ_PROJECT="$TMP_DIR/no-jq"
write_state "$NO_JQ_PROJECT"
NO_JQ_OUTPUT=$(
  cd "$NO_JQ_PROJECT"
  env -i HOME="$HOME_DIR" PATH="$NO_JQ_BIN" "$NO_JQ_BIN/bash" "$HOOK" <<< '{}'
)
assert_fail_open "jq missing" "$NO_JQ_OUTPUT" "jq is not installed"

# ── Loop-ending blocks also tell the user ────────────────────────────────
assert_ending_block() {
  local label="$1"
  local output="$2"
  local cause="$3"

  jq -e -s 'length == 1' <<< "$output" >/dev/null || fail "$label: not one JSON object: $output"
  jq -e --arg cause "$cause" '.decision == "block" and (.systemMessage | contains($cause))
    and (.systemMessage | contains(".claude/review-loop.log"))' <<< "$output" >/dev/null ||
    fail "$label: block does not tell the user why the loop ended: $output"
}

# PATH without any directory that provides cursor-agent; jq and git are
# linked back in case they shared such a directory.
NO_CURSOR_BIN="$TMP_DIR/no-cursor-bin"
mkdir -p "$NO_CURSOR_BIN"
for tool in jq git; do
  ln -s "$(command -v "$tool")" "$NO_CURSOR_BIN/$tool"
done
PATH_WITHOUT_CURSOR="$NO_CURSOR_BIN"
IFS=: read -r -a PATH_ENTRIES <<< "$PATH"
for path_entry in "${PATH_ENTRIES[@]}"; do
  if [ -n "$path_entry" ] && [ ! -e "$path_entry/cursor-agent" ]; then
    PATH_WITHOUT_CURSOR="$PATH_WITHOUT_CURSOR:$path_entry"
  fi
done
MISSING_CLI_PROJECT="$TMP_DIR/missing-cli"
write_state "$MISSING_CLI_PROJECT" task cursor
MISSING_CLI_OUTPUT=$(
  cd "$MISSING_CLI_PROJECT"
  env -i HOME="$HOME_DIR" PATH="$PATH_WITHOUT_CURSOR" "$HOOK" <<< '{}'
)
assert_ending_block "missing CLI" "$MISSING_CLI_OUTPUT" "CLI (cursor-agent) is not installed"

NO_MULTI_AGENT_PROJECT="$TMP_DIR/no-multi-agent"
NO_MULTI_AGENT_HOME="$TMP_DIR/no-multi-agent-home"
mkdir -p "$NO_MULTI_AGENT_HOME"
write_state "$NO_MULTI_AGENT_PROJECT"
NO_MULTI_AGENT_OUTPUT=$(
  cd "$NO_MULTI_AGENT_PROJECT"
  env -i HOME="$NO_MULTI_AGENT_HOME" PATH="$BIN_DIR:$PATH" "$HOOK" <<< '{}'
)
assert_ending_block "multi-agent disabled" "$NO_MULTI_AGENT_OUTPUT" "multi-agent is not enabled"

printf 'fail-open message tests passed\n'
