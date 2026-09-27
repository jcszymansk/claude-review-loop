#!/usr/bin/env bash
# Claude Code runs the Stop hook in the session's current directory, which
# follows the main agent's last `cd`. A loop started in the project root must
# keep running when that directory is a subdirectory of the loop, but only for
# the session that owns the loop (issue #25).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$SCRIPT_DIR/.."
HOOK="$PLUGIN_DIR/hooks/stop-hook.sh"
CANCEL="$PLUGIN_DIR/scripts/cancel-review-loop.sh"
SETUP="$PLUGIN_DIR/scripts/setup-review-loop.sh"
COMMAND_FILE="$PLUGIN_DIR/commands/review-loop.md"
CANCEL_COMMAND_FILE="$PLUGIN_DIR/commands/cancel-review.md"
TMP_DIR="$(mktemp -d)"
BIN_DIR="$TMP_DIR/bin"
HOME_DIR="$TMP_DIR/home"
OWNER_SESSION="3f0c9a52-1b7e-4d6a-9c1e-5a2b7d8e9f01"
OTHER_SESSION="9b8a7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$BIN_DIR" "$HOME_DIR/.codex"
printf '[features]\nmulti_agent = true\n' > "$HOME_DIR/.codex/config.toml"

cat > "$BIN_DIR/codex" <<'CODEX_EOF'
#!/usr/bin/env bash
count=0
if [ -f "$FAKE_COUNT_FILE" ]; then
  count=$(cat "$FAKE_COUNT_FILE")
fi
count=$((count + 1))
printf '%s\n' "$count" > "$FAKE_COUNT_FILE"
printf '%s\n' "$PWD" >> "$FAKE_COUNT_FILE.cwd"
printf 'VERDICT: FAIL\nfinding from review %s\n' "$count"
CODEX_EOF
chmod +x "$BIN_DIR/codex"

make_project() {
  local project="$1"

  mkdir -p "$project/sub/dir"
  git init -q "$project"
  git -C "$project" config user.email test@example.com
  git -C "$project" config user.name 'Review Loop Test'
  git -C "$project" checkout -qb main
  printf '.claude/\nreviews/\n' > "$project/.gitignore"
  printf 'base\n' > "$project/base.txt"
  printf 'nested\n' > "$project/sub/dir/nested.txt"
  git -C "$project" add .
  git -C "$project" commit -qm base
}

# write_state <loop dir> <review id> <phase> <session id or "">
write_state() {
  local loop_dir="$1"
  local review_id="$2"
  local phase="$3"
  local session_id="$4"

  mkdir -p "$loop_dir/.claude" "$loop_dir/reviews/$review_id"
  printf '# Review Loop Task Context\n\nsession cwd test\n' > \
    "$loop_dir/reviews/$review_id/summary-0.md"
  jq -n --arg phase "$phase" --arg review_id "$review_id" --arg session_id "$session_id" '
    {active:true, phase:$phase, reviewer:"codex", task:"session cwd test",
     round:1, max_rounds:3, review_id:$review_id,
     started_at:"2026-09-27T12:00:00Z"}
    | if $session_id == "" then . else . + {session_id:$session_id} end
  ' > "$loop_dir/.claude/review-loop.local.json"
}

write_failed_round() {
  local loop_dir="$1"
  local review_id="$2"

  printf 'VERDICT: FAIL\nround one finding\n' > "$loop_dir/reviews/$review_id/review-1.md"
  cat > "$loop_dir/reviews/$review_id/summary-1.md" <<'SUMMARY_EOF'
## Fixes
- fixed the round one finding

## Skipped findings
- None

## Quality gates
- shell test: PASS
SUMMARY_EOF
}

# run_hook <cwd> <session id or ""> <count file>
run_hook() {
  local cwd="$1"
  local session_id="$2"
  local count_file="$3"
  local input

  input=$(jq -cn --arg cwd "$cwd" --arg session_id "$session_id" '
    {hook_event_name:"Stop", cwd:$cwd}
    | if $session_id == "" then . else . + {session_id:$session_id} end')
  (
    cd "$cwd"
    env -i HOME="$HOME_DIR" XDG_CONFIG_HOME="$HOME_DIR/.config" PATH="$BIN_DIR:$PATH" \
      FAKE_COUNT_FILE="$count_file" "$HOOK" <<< "$input"
  )
}

assert_no_loop_files() {
  local dir="$1"
  [ ! -e "$dir/.claude" ] || fail "loop files were written under $dir/.claude"
  [ ! -e "$dir/reviews" ] || fail "loop files were written under $dir/reviews"
}

# ── Addressing: a stop from a subdirectory advances the owned root loop ───
PROJECT="$TMP_DIR/addressing"
SUBDIR="$PROJECT/sub/dir"
REVIEW_ID="20260927-120000-aaaaaa"
COUNT="$TMP_DIR/addressing-count"
make_project "$PROJECT"
write_state "$PROJECT" "$REVIEW_ID" addressing "$OWNER_SESSION"
write_failed_round "$PROJECT" "$REVIEW_ID"

output=$(run_hook "$SUBDIR" "$OWNER_SESSION" "$COUNT")
jq -e '.decision == "block"' <<< "$output" >/dev/null ||
  fail "a stop from a subdirectory did not continue the loop: $output"
jq -e '.phase == "addressing" and .round == 2' "$PROJECT/.claude/review-loop.local.json" >/dev/null ||
  fail "the root loop did not advance to round 2"
[ "$(head -n 1 "$PROJECT/reviews/$REVIEW_ID/review-2.md")" = "VERDICT: FAIL" ] ||
  fail "round 2 review was not written in the loop directory"
[ "$(cat "$COUNT.cwd")" = "$PROJECT" ] || fail "the reviewer did not run in the loop directory"
assert_no_loop_files "$SUBDIR"
grep -Fq "Stop hook ran in $SUBDIR; using the review loop in $PROJECT" "$PROJECT/.claude/review-loop.log" ||
  fail "the log does not say the hook ran from another directory"
reason=$(jq -r '.reason' <<< "$output")
case "$reason" in
  *"$PROJECT/reviews/$REVIEW_ID"*) ;;
  *) fail "the block reason does not give the loop directory: $reason" ;;
esac

# ── Task phase: the first stop from a subdirectory runs round 1 ───────────
PROJECT="$TMP_DIR/task"
SUBDIR="$PROJECT/sub/dir"
REVIEW_ID="20260927-120001-bbbbbb"
COUNT="$TMP_DIR/task-count"
make_project "$PROJECT"
write_state "$PROJECT" "$REVIEW_ID" task "$OWNER_SESSION"

output=$(run_hook "$SUBDIR" "$OWNER_SESSION" "$COUNT")
jq -e '.decision == "block"' <<< "$output" >/dev/null ||
  fail "the task-phase stop from a subdirectory did not run the review: $output"
jq -e '.phase == "addressing" and .round == 1' "$PROJECT/.claude/review-loop.local.json" >/dev/null ||
  fail "the task-phase loop did not move to addressing"
[ -f "$PROJECT/reviews/$REVIEW_ID/review-1.md" ] || fail "round 1 review missing"
assert_no_loop_files "$SUBDIR"

# ── Retry gate: the rerun instruction works from any directory ────────────
rm -f "$PROJECT/reviews/$REVIEW_ID/review-1.md"
output=$(run_hook "$SUBDIR" "$OWNER_SESSION" "$COUNT")
jq -e '.decision == "block"' <<< "$output" >/dev/null || fail "missing review did not block: $output"
reason=$(jq -r '.reason' <<< "$output")
runner="$PROJECT/.claude/review-loop-run-codex.sh"
case "$reason" in
  *"bash $runner"*) ;;
  *) fail "the rerun instruction does not use the absolute runner path: $reason" ;;
esac
(
  cd "$SUBDIR"
  env -i HOME="$HOME_DIR" XDG_CONFIG_HOME="$HOME_DIR/.config" PATH="$BIN_DIR:$PATH" \
    FAKE_COUNT_FILE="$COUNT" bash "$runner" >/dev/null 2>&1
) || fail "the runner failed when started from a subdirectory"
[ "$(head -n 1 "$PROJECT/reviews/$REVIEW_ID/review-1.md")" = "VERDICT: FAIL" ] ||
  fail "the rerun from a subdirectory did not write the review in the loop directory"
[ "$(tail -n 1 "$COUNT.cwd")" = "$PROJECT" ] || fail "the rerun reviewer did not run in the loop directory"
assert_no_loop_files "$SUBDIR"

# ── Another session's loop in a parent directory is left alone ────────────
PROJECT="$TMP_DIR/foreign"
SUBDIR="$PROJECT/sub/dir"
REVIEW_ID="20260927-120002-cccccc"
COUNT="$TMP_DIR/foreign-count"
make_project "$PROJECT"
write_state "$PROJECT" "$REVIEW_ID" task "$OWNER_SESSION"
state_before=$(cat "$PROJECT/.claude/review-loop.local.json")

output=$(run_hook "$SUBDIR" "$OTHER_SESSION" "$COUNT")
[ "$output" = '{"decision":"approve"}' ] || fail "another session's stop touched the loop: $output"
[ "$(cat "$PROJECT/.claude/review-loop.local.json")" = "$state_before" ] ||
  fail "another session's stop changed the loop state"
[ ! -f "$COUNT" ] || fail "another session's stop ran the reviewer"
assert_no_loop_files "$SUBDIR"

# A stop without a session id cannot claim a parent loop either.
output=$(run_hook "$SUBDIR" "" "$COUNT")
[ "$output" = '{"decision":"approve"}' ] || fail "a stop without a session id touched the loop: $output"
[ ! -f "$COUNT" ] || fail "a stop without a session id ran the reviewer"

# ── A parent loop without an owner is only used from its own directory ───
PROJECT="$TMP_DIR/ownerless"
SUBDIR="$PROJECT/sub/dir"
REVIEW_ID="20260927-120003-dddddd"
COUNT="$TMP_DIR/ownerless-count"
make_project "$PROJECT"
write_state "$PROJECT" "$REVIEW_ID" task ""

output=$(run_hook "$SUBDIR" "$OWNER_SESSION" "$COUNT")
[ "$output" = '{"decision":"approve"}' ] || fail "a stop claimed a loop without an owner: $output"
[ ! -f "$COUNT" ] || fail "a stop from a subdirectory ran an ownerless loop"
assert_no_loop_files "$SUBDIR"

output=$(run_hook "$PROJECT" "$OWNER_SESSION" "$COUNT")
jq -e '.decision == "block"' <<< "$output" >/dev/null ||
  fail "an ownerless loop no longer runs from its own directory: $output"

# ── Nested loops: each session finds its own loop from the nested dir ─────
PROJECT="$TMP_DIR/nested"
SUBDIR="$PROJECT/sub/dir"
ROOT_REVIEW_ID="20260927-120004-eeeeee"
NESTED_REVIEW_ID="20260927-120005-ffffff"
make_project "$PROJECT"
write_state "$PROJECT" "$ROOT_REVIEW_ID" task "$OWNER_SESSION"
write_state "$SUBDIR" "$NESTED_REVIEW_ID" task "$OTHER_SESSION"

output=$(run_hook "$SUBDIR" "$OWNER_SESSION" "$TMP_DIR/nested-root-count")
jq -e '.decision == "block"' <<< "$output" >/dev/null || fail "the owner's stop skipped its root loop: $output"
jq -e '.phase == "addressing"' "$PROJECT/.claude/review-loop.local.json" >/dev/null ||
  fail "the root loop did not run"
jq -e '.phase == "task"' "$SUBDIR/.claude/review-loop.local.json" >/dev/null ||
  fail "the owner's stop ran the nested loop of another session"
[ ! -f "$SUBDIR/reviews/$NESTED_REVIEW_ID/review-1.md" ] || fail "nested loop review written by the wrong session"

output=$(run_hook "$SUBDIR" "$OTHER_SESSION" "$TMP_DIR/nested-sub-count")
jq -e '.decision == "block"' <<< "$output" >/dev/null || fail "the nested loop did not run: $output"
jq -e '.phase == "addressing"' "$SUBDIR/.claude/review-loop.local.json" >/dev/null ||
  fail "the nested loop did not advance"

# ── A loop of another session in the hook's own directory is skipped ──────
PROJECT="$TMP_DIR/foreign-here"
REVIEW_ID="20260927-120007-aabbcc"
COUNT="$TMP_DIR/foreign-here-count"
make_project "$PROJECT"
write_state "$PROJECT" "$REVIEW_ID" task "$OWNER_SESSION"
state_before=$(cat "$PROJECT/.claude/review-loop.local.json")

output=$(run_hook "$PROJECT" "$OTHER_SESSION" "$COUNT")
[ "$output" = '{"decision":"approve"}' ] || fail "another session's stop ran the loop in its directory: $output"
[ "$(cat "$PROJECT/.claude/review-loop.local.json")" = "$state_before" ] ||
  fail "another session's stop changed the loop state in its directory"
[ ! -f "$COUNT" ] || fail "another session's stop ran the reviewer in its directory"
grep -Fq "Stop hook for session $OTHER_SESSION ignored the review loop in $PROJECT, which belongs to another session" \
  "$PROJECT/.claude/review-loop.log" || fail "the skipped loop is not logged"

# A Claude reviewer process runs there as a session of its own; it exits
# without touching the loop and is not reported as a foreign session.
: > "$PROJECT/.claude/review-loop.log"
output=$(cd "$PROJECT" && env -i HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" REVIEW_LOOP_REVIEWER_PROCESS=1 \
  FAKE_COUNT_FILE="$COUNT" "$HOOK" <<< "{\"session_id\":\"$OTHER_SESSION\"}")
[ "$output" = '{"decision":"approve"}' ] || fail "the reviewer process was not approved: $output"
[ "$(cat "$PROJECT/.claude/review-loop.local.json")" = "$state_before" ] ||
  fail "the reviewer process changed the loop state"
grep -Fq 'Allowing Claude reviewer process to exit' "$PROJECT/.claude/review-loop.log" ||
  fail "the reviewer process exit is not logged"
if grep -Fq 'belongs to another session' "$PROJECT/.claude/review-loop.log"; then
  fail "the reviewer process was logged as a foreign session"
fi

# A stop without a session id keeps the old behavior in the loop directory.
output=$(run_hook "$PROJECT" "" "$COUNT")
jq -e '.decision == "block"' <<< "$output" >/dev/null ||
  fail "a stop without a session id no longer runs the loop in its directory: $output"

# ── find-loop-root.sh arguments ───────────────────────────────────────────
FINDER="$PLUGIN_DIR/scripts/find-loop-root.sh"
status=0
"$FINDER" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "find-loop-root.sh without arguments exited $status"
status=0
"$FINDER" "$TMP_DIR/does-not-exist" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "find-loop-root.sh with a missing directory exited $status"
[ "$("$FINDER" "$PROJECT/sub/dir" "$OWNER_SESSION")" = "$PROJECT" ] ||
  fail "find-loop-root.sh did not find the owned parent loop"
if "$FINDER" "$PROJECT/sub/dir" '../bad id' >/dev/null; then
  fail "find-loop-root.sh matched a parent loop with an invalid session id"
fi
if "$FINDER" / "$OWNER_SESSION" >/dev/null; then
  fail "find-loop-root.sh found a loop above the filesystem root"
fi

# ── No loop anywhere: silent approve, nothing written ─────────────────────
PROJECT="$TMP_DIR/empty"
SUBDIR="$PROJECT/sub/dir"
make_project "$PROJECT"
output=$(run_hook "$SUBDIR" "$OWNER_SESSION" "$TMP_DIR/empty-count")
[ "$output" = '{"decision":"approve"}' ] || fail "no-loop stop was not a silent approve: $output"
assert_no_loop_files "$SUBDIR"
assert_no_loop_files "$PROJECT"

# ── /cancel-review from a subdirectory cancels the owned loop ─────────────
PROJECT="$TMP_DIR/cancel"
SUBDIR="$PROJECT/sub/dir"
REVIEW_ID="20260927-120006-abcabc"
make_project "$PROJECT"
write_state "$PROJECT" "$REVIEW_ID" addressing "$OWNER_SESSION"

cancel_output=$(cd "$SUBDIR" && "$CANCEL" "$OTHER_SESSION")
case "$cancel_output" in
  *"No active review loop found."*) ;;
  *) fail "cancel from another session reported: $cancel_output" ;;
esac
[ -f "$PROJECT/.claude/review-loop.local.json" ] || fail "another session cancelled the loop"

cancel_output=$(cd "$SUBDIR" && "$CANCEL" "$OWNER_SESSION")
case "$cancel_output" in
  *"Review loop cancelled"*"$REVIEW_ID"*) ;;
  *) fail "cancel from a subdirectory reported: $cancel_output" ;;
esac
[ ! -f "$PROJECT/.claude/review-loop.local.json" ] || fail "cancel from a subdirectory left the state"
[ -d "$PROJECT/reviews/$REVIEW_ID" ] || fail "cancel removed the review history"
assert_no_loop_files "$SUBDIR"

# shellcheck disable=SC2016 # the command file holds these tokens literally
grep -Fq '"${CLAUDE_PLUGIN_ROOT}/scripts/cancel-review-loop.sh" "${CLAUDE_SESSION_ID}"' "$CANCEL_COMMAND_FILE" ||
  fail "/cancel-review does not pass the session id to the helper"

# ── Setup records the owning session ──────────────────────────────────────
PROJECT="$TMP_DIR/setup-script"
make_project "$PROJECT"
(
  cd "$PROJECT"
  env -i HOME="$HOME_DIR" XDG_CONFIG_HOME="$HOME_DIR/.config" PATH="$BIN_DIR:$PATH" \
    REVIEW_LOOP_REVIEWER=codex CLAUDE_SESSION_ID="$OWNER_SESSION" "$SETUP" setup script task >/dev/null
)
jq -e --arg s "$OWNER_SESSION" '.session_id == $s' "$PROJECT/.claude/review-loop.local.json" >/dev/null ||
  fail "setup-review-loop.sh did not record the session id"

# The same session cannot start a second loop below its first one.
if setup_output=$(cd "$PROJECT/sub/dir" &&
  env -i HOME="$HOME_DIR" XDG_CONFIG_HOME="$HOME_DIR/.config" PATH="$BIN_DIR:$PATH" \
    REVIEW_LOOP_REVIEWER=codex CLAUDE_SESSION_ID="$OWNER_SESSION" "$SETUP" nested task 2>&1); then
  fail "setup started a second loop for the same session"
fi
case "$setup_output" in
  *"already has an active review loop in $PROJECT"*) ;;
  *) fail "nested setup error does not name the active loop: $setup_output" ;;
esac
[ ! -e "$PROJECT/sub/dir/.claude/review-loop.local.json" ] || fail "nested setup wrote a state file"

# Another session may still start its own loop there.
(
  cd "$PROJECT/sub/dir"
  env -i HOME="$HOME_DIR" XDG_CONFIG_HOME="$HOME_DIR/.config" PATH="$BIN_DIR:$PATH" \
    REVIEW_LOOP_REVIEWER=codex CLAUDE_SESSION_ID="$OTHER_SESSION" "$SETUP" other task >/dev/null
) || fail "setup refused a loop for another session"
jq -e --arg s "$OTHER_SESSION" '.session_id == $s' "$PROJECT/sub/dir/.claude/review-loop.local.json" >/dev/null ||
  fail "the other session's loop does not record its owner"

PROJECT="$TMP_DIR/setup-script-invalid"
make_project "$PROJECT"
(
  cd "$PROJECT"
  env -i HOME="$HOME_DIR" XDG_CONFIG_HOME="$HOME_DIR/.config" PATH="$BIN_DIR:$PATH" \
    REVIEW_LOOP_REVIEWER=codex CLAUDE_SESSION_ID='../bad id' "$SETUP" setup script task >/dev/null
)
jq -e 'has("session_id") | not' "$PROJECT/.claude/review-loop.local.json" >/dev/null ||
  fail "setup-review-loop.sh recorded an invalid session id"

COMMAND_SCRIPT="$TMP_DIR/review-loop-command.sh"
awk '
  /^```bash$/ { capture = 1; next }
  capture && /^```$/ { exit }
  capture { print }
' "$COMMAND_FILE" > "$COMMAND_SCRIPT"
chmod +x "$COMMAND_SCRIPT"
PROJECT="$TMP_DIR/setup-command"
make_project "$PROJECT"
(
  cd "$PROJECT"
  env -i HOME="$HOME_DIR" XDG_CONFIG_HOME="$HOME_DIR/.config" PATH="$BIN_DIR:$PATH" \
    ARGUMENTS='command task' CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" REVIEW_LOOP_REVIEWER=codex \
    CLAUDE_SESSION_ID="$OWNER_SESSION" "$COMMAND_SCRIPT" >/dev/null
)
jq -e --arg s "$OWNER_SESSION" '.session_id == $s' "$PROJECT/.claude/review-loop.local.json" >/dev/null ||
  fail "/review-loop did not record the session id"

printf 'session cwd tests passed\n'
