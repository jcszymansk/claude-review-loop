#!/usr/bin/env bash
# Claude Code runs the Stop hook in the session's current directory, which
# follows the main agent's last `cd`. The loop a session started must keep
# running wherever that directory is, but only for that session (issue #25).
# Setup records the loop directory in a per-user registry keyed by session id;
# without a registered loop the hook falls back to a loop in its own cwd.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$SCRIPT_DIR/.."
HOOK="$PLUGIN_DIR/hooks/stop-hook.sh"
CANCEL="$PLUGIN_DIR/scripts/cancel-review-loop.sh"
SETUP="$PLUGIN_DIR/scripts/setup-review-loop.sh"
REGISTRY="$PLUGIN_DIR/scripts/loop-registry.sh"
FINDER="$PLUGIN_DIR/scripts/find-loop-root.sh"
COMMAND_FILE="$PLUGIN_DIR/commands/review-loop.md"
CANCEL_COMMAND_FILE="$PLUGIN_DIR/commands/cancel-review.md"
TMP_DIR="$(mktemp -d)"
BIN_DIR="$TMP_DIR/bin"
HOME_DIR="$TMP_DIR/home"
SESSIONS_DIR="$HOME_DIR/.local/state/review-loop/sessions"
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
printf 'VERDICT: %s\nfinding from review %s\n' "${FAKE_VERDICT:-FAIL}" "$count"
CODEX_EOF
chmod +x "$BIN_DIR/codex"

# Every helper runs with a sanitized environment: the registry lives under the
# fake HOME, and no session id leaks in from a Claude Code session running
# this test.
sandbox() {
  env -i HOME="$HOME_DIR" XDG_CONFIG_HOME="$HOME_DIR/.config" PATH="$BIN_DIR:$PATH" "$@"
}

make_project() {
  local project="$1"

  mkdir -p "$project/sub/dir" "$project/sub/other"
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
# Writes the state the way setup does, including the registry entry.
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
  if [ -n "$session_id" ]; then
    sandbox "$REGISTRY" register "$session_id" "$loop_dir" ||
      fail "could not register the loop in $loop_dir"
  fi
}

write_summary() {
  local loop_dir="$1"
  local review_id="$2"
  local round="$3"

  cat > "$loop_dir/reviews/$review_id/summary-$round.md" <<'SUMMARY_EOF'
## Fixes
- fixed the finding

## Skipped findings
- None

## Quality gates
- shell test: PASS
SUMMARY_EOF
}

# run_hook <cwd> <session id or ""> <count file> [VAR=value...]
run_hook() {
  local cwd="$1"
  local session_id="$2"
  local count_file="$3"
  shift 3
  local input

  input=$(jq -cn --arg cwd "$cwd" --arg session_id "$session_id" '
    {hook_event_name:"Stop", cwd:$cwd}
    | if $session_id == "" then . else . + {session_id:$session_id} end')
  (
    cd "$cwd"
    sandbox FAKE_COUNT_FILE="$count_file" "$@" "$HOOK" <<< "$input"
  )
}

assert_no_loop_files() {
  local dir="$1"
  [ ! -e "$dir/.claude" ] || fail "loop files were written under $dir/.claude"
  [ ! -e "$dir/reviews" ] || fail "loop files were written under $dir/reviews"
}

assert_pointer() {
  local session_id="$1"
  local expected="$2"
  [ "$(cat "$SESSIONS_DIR/$session_id" 2>/dev/null)" = "$expected" ] ||
    fail "the registry entry of $session_id is not $expected"
}

assert_no_pointer() {
  local session_id="$1"
  [ ! -e "$SESSIONS_DIR/$session_id" ] || fail "the registry entry of $session_id was left behind"
}

# ── Addressing: a stop from a subdirectory advances the session's loop ────
PROJECT="$TMP_DIR/addressing"
SUBDIR="$PROJECT/sub/dir"
REVIEW_ID="20260927-120000-aaaaaa"
COUNT="$TMP_DIR/addressing-count"
make_project "$PROJECT"
write_state "$PROJECT" "$REVIEW_ID" addressing "$OWNER_SESSION"
assert_pointer "$OWNER_SESSION" "$PROJECT"
printf 'VERDICT: FAIL\nround one finding\n' > "$PROJECT/reviews/$REVIEW_ID/review-1.md"
write_summary "$PROJECT" "$REVIEW_ID" 1

output=$(run_hook "$SUBDIR" "$OWNER_SESSION" "$COUNT")
jq -e '.decision == "block"' <<< "$output" >/dev/null ||
  fail "a stop from a subdirectory did not continue the loop: $output"
jq -e '.phase == "addressing" and .round == 2' "$PROJECT/.claude/review-loop.local.json" >/dev/null ||
  fail "the loop did not advance to round 2"
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
assert_pointer "$OWNER_SESSION" "$PROJECT"

# ── The loop ends with PASS: state and registry entry are removed ─────────
write_summary "$PROJECT" "$REVIEW_ID" 2
printf 'VERDICT: PASS\nclean\n' > "$PROJECT/reviews/$REVIEW_ID/review-2.md"
output=$(run_hook "$SUBDIR" "$OWNER_SESSION" "$COUNT")
jq -e '.decision == "approve"' <<< "$output" >/dev/null || fail "PASS from a subdirectory did not approve: $output"
[ ! -f "$PROJECT/.claude/review-loop.local.json" ] || fail "PASS left the state file"
assert_no_pointer "$OWNER_SESSION"

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
  sandbox FAKE_COUNT_FILE="$COUNT" bash "$runner" >/dev/null 2>&1
) || fail "the runner failed when started from a subdirectory"
[ "$(head -n 1 "$PROJECT/reviews/$REVIEW_ID/review-1.md")" = "VERDICT: FAIL" ] ||
  fail "the rerun from a subdirectory did not write the review in the loop directory"
[ "$(tail -n 1 "$COUNT.cwd")" = "$PROJECT" ] || fail "the rerun reviewer did not run in the loop directory"
assert_no_loop_files "$SUBDIR"

# ── A loop that fails open removes its registry entry ─────────────────────
jq '.active = false' "$PROJECT/.claude/review-loop.local.json" > "$TMP_DIR/inactive.json"
cp "$TMP_DIR/inactive.json" "$PROJECT/.claude/review-loop.local.json"
output=$(run_hook "$SUBDIR" "$OWNER_SESSION" "$COUNT")
jq -e '.decision == "approve" and (.systemMessage | contains("inactive"))' <<< "$output" >/dev/null ||
  fail "an inactive loop did not fail open: $output"
assert_no_pointer "$OWNER_SESSION"

# ── A sibling directory is not an ancestor, but the loop still runs ───────
PROJECT="$TMP_DIR/sideways"
REVIEW_ID="20260927-120012-abab12"
COUNT="$TMP_DIR/sideways-count"
make_project "$PROJECT"
write_state "$PROJECT/sub/dir" "$REVIEW_ID" task "$OWNER_SESSION"
output=$(run_hook "$PROJECT/sub/other" "$OWNER_SESSION" "$COUNT")
jq -e '.decision == "block"' <<< "$output" >/dev/null ||
  fail "a stop from a sibling directory missed the loop: $output"
[ "$(cat "$COUNT.cwd")" = "$PROJECT/sub/dir" ] || fail "the sideways stop reviewed the wrong directory"
assert_no_loop_files "$PROJECT/sub/other"
sandbox "$REGISTRY" unregister "$OWNER_SESSION" "$PROJECT/sub/dir"

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

# A stop without a session id cannot claim it either.
output=$(run_hook "$SUBDIR" "" "$COUNT")
[ "$output" = '{"decision":"approve"}' ] || fail "a stop without a session id touched the loop: $output"
[ ! -f "$COUNT" ] || fail "a stop without a session id ran the reviewer"
sandbox "$REGISTRY" unregister "$OWNER_SESSION" "$PROJECT"

# ── A loop without an owner is only used from its own directory ───────────
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
sandbox "$REGISTRY" unregister "$OWNER_SESSION" "$PROJECT"
sandbox "$REGISTRY" unregister "$OTHER_SESSION" "$SUBDIR"

# ── After /clear the session id changes; the loop in the cwd keeps running ─
PROJECT="$TMP_DIR/foreign-here"
REVIEW_ID="20260927-120007-aabbcc"
COUNT="$TMP_DIR/foreign-here-count"
make_project "$PROJECT"
write_state "$PROJECT" "$REVIEW_ID" task "$OWNER_SESSION"

output=$(run_hook "$PROJECT" "$OTHER_SESSION" "$COUNT")
jq -e '.decision == "block"' <<< "$output" >/dev/null ||
  fail "a new session stopped running the loop in its own directory: $output"
jq -e '.phase == "addressing"' "$PROJECT/.claude/review-loop.local.json" >/dev/null ||
  fail "the loop in the cwd did not run for a new session"
grep -Fq "Stop hook for session $OTHER_SESSION is running the review loop in $PROJECT, started by session $OWNER_SESSION" \
  "$PROJECT/.claude/review-loop.log" || fail "running another session's loop is not logged"

# A Claude reviewer process runs there as a session of its own; it exits
# without touching the loop.
: > "$PROJECT/.claude/review-loop.log"
state_before=$(cat "$PROJECT/.claude/review-loop.local.json")
output=$(cd "$PROJECT" && sandbox REVIEW_LOOP_REVIEWER_PROCESS=1 FAKE_COUNT_FILE="$COUNT" \
  "$HOOK" <<< "{\"session_id\":\"$OTHER_SESSION\"}")
[ "$output" = '{"decision":"approve"}' ] || fail "the reviewer process was not approved: $output"
[ "$(cat "$PROJECT/.claude/review-loop.local.json")" = "$state_before" ] ||
  fail "the reviewer process changed the loop state"
grep -Fq 'Allowing Claude reviewer process to exit' "$PROJECT/.claude/review-loop.log" ||
  fail "the reviewer process exit is not logged"
if grep -Fq 'started by session' "$PROJECT/.claude/review-loop.log"; then
  fail "the reviewer process ran the loop"
fi

# A stop without a session id keeps the old behavior in the loop directory.
output=$(run_hook "$PROJECT" "" "$COUNT")
jq -e '.decision == "block"' <<< "$output" >/dev/null ||
  fail "a stop without a session id no longer runs the loop in its directory: $output"

# /cancel-review works there too, and removes the old session's entry.
cancel_output=$(cd "$PROJECT" && sandbox "$CANCEL" "$OTHER_SESSION")
case "$cancel_output" in
  *"Review loop cancelled"*"$REVIEW_ID"*) ;;
  *) fail "a new session could not cancel the loop in its directory: $cancel_output" ;;
esac
[ ! -f "$PROJECT/.claude/review-loop.local.json" ] || fail "cancel by a new session left the state"
assert_no_pointer "$OWNER_SESSION"

# ── Worktrees: the registry names the directory the loop was started in ───
PROJECT="$TMP_DIR/worktree-main"
WORKTREE="$PROJECT/.claude/worktrees/feature"
REVIEW_ID="20260927-120008-ddeeff"
COUNT="$TMP_DIR/worktree-count"
make_project "$PROJECT"
git -C "$PROJECT" worktree add -q "$WORKTREE" -b wt-feature
write_state "$WORKTREE" "$REVIEW_ID" task "$OWNER_SESSION"
output=$(run_hook "$WORKTREE/sub/dir" "$OWNER_SESSION" "$COUNT")
jq -e '.decision == "block"' <<< "$output" >/dev/null || fail "a worktree loop did not run: $output"
[ "$(cat "$COUNT.cwd")" = "$WORKTREE" ] || fail "the worktree loop was not reviewed in the worktree"
[ ! -e "$PROJECT/.claude/review-loop.local.json" ] || fail "the worktree loop wrote state in the main checkout"
sandbox "$REGISTRY" unregister "$OWNER_SESSION" "$WORKTREE"

# ── A symlinked subdirectory resolves through the registry ────────────────
PROJECT="$TMP_DIR/symlink"
REVIEW_ID="20260927-120009-a1b2c3"
COUNT="$TMP_DIR/symlink-count"
make_project "$PROJECT"
mkdir -p "$TMP_DIR/elsewhere"
ln -s "$TMP_DIR/elsewhere" "$PROJECT/link"
write_state "$PROJECT" "$REVIEW_ID" task "$OWNER_SESSION"
output=$(run_hook "$PROJECT/link" "$OWNER_SESSION" "$COUNT")
jq -e '.decision == "block"' <<< "$output" >/dev/null ||
  fail "a stop from a symlinked subdirectory missed the loop: $output"
assert_no_loop_files "$TMP_DIR/elsewhere"
sandbox "$REGISTRY" unregister "$OWNER_SESSION" "$PROJECT"

# ── A loop directory with spaces and quotes ───────────────────────────────
PROJECT="$TMP_DIR/odd \"dir\" \$HOME"
SUBDIR="$PROJECT/sub/dir"
REVIEW_ID="20260927-120011-0a0b0c"
COUNT="$TMP_DIR/odd-count"
make_project "$PROJECT"
write_state "$PROJECT" "$REVIEW_ID" task "$OWNER_SESSION"
output=$(run_hook "$SUBDIR" "$OWNER_SESSION" "$COUNT")
jq -e '.decision == "block"' <<< "$output" >/dev/null || fail "a loop in an odd directory did not run: $output"
rm -f "$PROJECT/reviews/$REVIEW_ID/review-1.md"
output=$(run_hook "$SUBDIR" "$OWNER_SESSION" "$COUNT")
reason=$(jq -r '.reason' <<< "$output")
printf -v quoted_runner '%q' "$PROJECT/.claude/review-loop-run-codex.sh"
case "$reason" in
  *"bash $quoted_runner"*) ;;
  *) fail "the rerun instruction does not quote the runner path: $reason" ;;
esac
(
  cd "$SUBDIR"
  sandbox FAKE_COUNT_FILE="$COUNT" bash -c "bash $quoted_runner" >/dev/null 2>&1
) || fail "the quoted rerun instruction failed"
[ -f "$PROJECT/reviews/$REVIEW_ID/review-1.md" ] || fail "the quoted rerun did not write the review"
sandbox "$REGISTRY" unregister "$OWNER_SESSION" "$PROJECT"

# ── Stale and invalid registry entries are ignored and pruned ─────────────
PROJECT="$TMP_DIR/stale"
SUBDIR="$PROJECT/sub/dir"
make_project "$PROJECT"
mkdir -p "$SESSIONS_DIR"

printf '%s\n' "$TMP_DIR/gone" > "$SESSIONS_DIR/$OWNER_SESSION"
output=$(run_hook "$SUBDIR" "$OWNER_SESSION" "$TMP_DIR/stale-count")
[ "$output" = '{"decision":"approve"}' ] || fail "a pointer to a missing directory was used: $output"
assert_no_pointer "$OWNER_SESSION"

write_state "$PROJECT" "20260927-120013-cdcdcd" task "$OTHER_SESSION"
printf '%s\n' "$PROJECT" > "$SESSIONS_DIR/$OWNER_SESSION"
output=$(run_hook "$SUBDIR" "$OWNER_SESSION" "$TMP_DIR/stale-count")
[ "$output" = '{"decision":"approve"}' ] || fail "a pointer to another session's loop was used: $output"
assert_no_pointer "$OWNER_SESSION"
assert_pointer "$OTHER_SESSION" "$PROJECT"
sandbox "$REGISTRY" unregister "$OTHER_SESSION" "$PROJECT"
rm -f "$PROJECT/.claude/review-loop.local.json"

printf 'relative/path\n' > "$SESSIONS_DIR/$OWNER_SESSION"
if sandbox "$REGISTRY" lookup "$OWNER_SESSION" >/dev/null; then
  fail "a relative registry entry was used"
fi
assert_no_pointer "$OWNER_SESSION"
[ ! -f "$TMP_DIR/stale-count" ] || fail "a stale registry entry ran the reviewer"

# ── loop-registry.sh ──────────────────────────────────────────────────────
[ "$(sandbox "$REGISTRY" dir)" = "$SESSIONS_DIR" ] || fail "the registry does not default to ~/.local/state"
[ "$(sandbox XDG_STATE_HOME="$TMP_DIR/state" "$REGISTRY" dir)" = "$TMP_DIR/state/review-loop/sessions" ] ||
  fail "the registry ignores XDG_STATE_HOME"
[ "$(sandbox XDG_STATE_HOME=relative/state "$REGISTRY" dir)" = "$SESSIONS_DIR" ] ||
  fail "the registry accepted a relative XDG_STATE_HOME"
if env -i PATH="$PATH" "$REGISTRY" dir >/dev/null 2>&1; then
  fail "the registry found a directory without HOME or XDG_STATE_HOME"
fi
status=0
sandbox "$REGISTRY" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "loop-registry.sh without arguments exited $status"
status=0
sandbox "$REGISTRY" register '../bad id' "$PROJECT" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "loop-registry.sh registered an invalid session id (exit $status)"
status=0
sandbox "$REGISTRY" register "$OWNER_SESSION" relative/dir >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "loop-registry.sh registered a relative directory (exit $status)"
status=0
sandbox "$REGISTRY" register "$OWNER_SESSION" "$TMP_DIR/line
break" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "loop-registry.sh registered a directory with a newline (exit $status)"
assert_no_pointer "$OWNER_SESSION"

# unregister only removes an entry that names the given directory.
sandbox "$REGISTRY" register "$OWNER_SESSION" "$PROJECT"
sandbox "$REGISTRY" unregister "$OWNER_SESSION" "$TMP_DIR/elsewhere"
assert_pointer "$OWNER_SESSION" "$PROJECT"
sandbox "$REGISTRY" unregister "$OWNER_SESSION" "$PROJECT"
assert_no_pointer "$OWNER_SESSION"

# ── find-loop-root.sh arguments ───────────────────────────────────────────
status=0
sandbox "$FINDER" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "find-loop-root.sh without arguments exited $status"
status=0
sandbox "$FINDER" "$TMP_DIR/does-not-exist" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "find-loop-root.sh with a missing directory exited $status"
if sandbox "$FINDER" "$SUBDIR" '../bad id' >/dev/null; then
  fail "find-loop-root.sh found a loop for an invalid session id"
fi

# ── No loop anywhere: silent approve, nothing written ─────────────────────
PROJECT="$TMP_DIR/empty"
SUBDIR="$PROJECT/sub/dir"
make_project "$PROJECT"
output=$(run_hook "$SUBDIR" "$OWNER_SESSION" "$TMP_DIR/empty-count")
[ "$output" = '{"decision":"approve"}' ] || fail "no-loop stop was not a silent approve: $output"
assert_no_loop_files "$SUBDIR"
assert_no_loop_files "$PROJECT"

# ── /cancel-review from a subdirectory cancels the session's loop ─────────
PROJECT="$TMP_DIR/cancel"
SUBDIR="$PROJECT/sub/dir"
REVIEW_ID="20260927-120006-abcabc"
make_project "$PROJECT"
write_state "$PROJECT" "$REVIEW_ID" addressing "$OWNER_SESSION"

cancel_output=$(cd "$SUBDIR" && sandbox "$CANCEL" "$OTHER_SESSION")
case "$cancel_output" in
  *"No active review loop found."*) ;;
  *) fail "cancel from another session reported: $cancel_output" ;;
esac
[ -f "$PROJECT/.claude/review-loop.local.json" ] || fail "another session cancelled the loop"

cancel_output=$(cd "$SUBDIR" && sandbox "$CANCEL" "$OWNER_SESSION")
case "$cancel_output" in
  *"Review loop cancelled"*"$REVIEW_ID"*) ;;
  *) fail "cancel from a subdirectory reported: $cancel_output" ;;
esac
[ ! -f "$PROJECT/.claude/review-loop.local.json" ] || fail "cancel from a subdirectory left the state"
[ -d "$PROJECT/reviews/$REVIEW_ID" ] || fail "cancel removed the review history"
assert_no_loop_files "$SUBDIR"
assert_no_pointer "$OWNER_SESSION"

# The /cancel-review command passes the session id, from the substitution or,
# when that is left unsubstituted, from the id Claude Code exports.
CANCEL_COMMAND_SCRIPT="$TMP_DIR/cancel-review-command.sh"
awk '
  /^```bash$/ { capture = 1; next }
  capture && /^```$/ { exit }
  capture { print }
' "$CANCEL_COMMAND_FILE" > "$CANCEL_COMMAND_SCRIPT"
chmod +x "$CANCEL_COMMAND_SCRIPT"
for session_var in CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID; do
  write_state "$PROJECT" "$REVIEW_ID" addressing "$OWNER_SESSION"
  cancel_output=$(cd "$SUBDIR" &&
    sandbox CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" "$session_var=$OWNER_SESSION" "$CANCEL_COMMAND_SCRIPT")
  case "$cancel_output" in
    *"Review loop cancelled"*"$REVIEW_ID"*) ;;
    *) fail "/cancel-review with $session_var reported: $cancel_output" ;;
  esac
  assert_no_pointer "$OWNER_SESSION"
done

# ── Setup records and registers the owning session ────────────────────────
PROJECT="$TMP_DIR/setup-script"
make_project "$PROJECT"
(
  cd "$PROJECT"
  sandbox REVIEW_LOOP_REVIEWER=codex CLAUDE_SESSION_ID="$OWNER_SESSION" "$SETUP" setup script task >/dev/null
)
jq -e --arg s "$OWNER_SESSION" '.session_id == $s' "$PROJECT/.claude/review-loop.local.json" >/dev/null ||
  fail "setup-review-loop.sh did not record the session id"
assert_pointer "$OWNER_SESSION" "$PROJECT"

# The same session cannot start a second loop anywhere: below, above or
# beside its first one.
for second_dir in "$PROJECT/sub/dir" "$TMP_DIR" "$TMP_DIR/empty"; do
  if setup_output=$(cd "$second_dir" &&
    sandbox REVIEW_LOOP_REVIEWER=codex CLAUDE_SESSION_ID="$OWNER_SESSION" "$SETUP" second task 2>&1); then
    fail "setup started a second loop for the same session in $second_dir"
  fi
  case "$setup_output" in
    *"already has an active review loop in $PROJECT"*) ;;
    *) fail "second setup error does not name the active loop: $setup_output" ;;
  esac
  [ ! -e "$second_dir/.claude/review-loop.local.json" ] || fail "second setup wrote a state file in $second_dir"
done
assert_pointer "$OWNER_SESSION" "$PROJECT"

# Another session may still start its own loop there.
(
  cd "$PROJECT/sub/dir"
  sandbox REVIEW_LOOP_REVIEWER=codex CLAUDE_SESSION_ID="$OTHER_SESSION" "$SETUP" other task >/dev/null
) || fail "setup refused a loop for another session"
jq -e --arg s "$OTHER_SESSION" '.session_id == $s' "$PROJECT/sub/dir/.claude/review-loop.local.json" >/dev/null ||
  fail "the other session's loop does not record its owner"
assert_pointer "$OTHER_SESSION" "$PROJECT/sub/dir"

# A stale entry does not block setup.
PROJECT="$TMP_DIR/setup-stale"
make_project "$PROJECT"
printf '%s\n' "$TMP_DIR/gone" > "$SESSIONS_DIR/$OWNER_SESSION"
(
  cd "$PROJECT"
  sandbox REVIEW_LOOP_REVIEWER=codex CLAUDE_SESSION_ID="$OWNER_SESSION" "$SETUP" stale task >/dev/null
) || fail "a stale registry entry blocked setup"
assert_pointer "$OWNER_SESSION" "$PROJECT"
sandbox "$REGISTRY" unregister "$OWNER_SESSION" "$PROJECT"

# The CLI setup takes the session id only from CLAUDE_SESSION_ID: a test or
# script run inside a Claude Code session must not claim that session.
PROJECT="$TMP_DIR/setup-script-inherited"
make_project "$PROJECT"
(
  cd "$PROJECT"
  sandbox REVIEW_LOOP_REVIEWER=codex CLAUDE_CODE_SESSION_ID="$OWNER_SESSION" "$SETUP" inherited task >/dev/null
)
jq -e 'has("session_id") | not' "$PROJECT/.claude/review-loop.local.json" >/dev/null ||
  fail "setup-review-loop.sh claimed the ambient Claude Code session"
assert_no_pointer "$OWNER_SESSION"

PROJECT="$TMP_DIR/setup-script-invalid"
make_project "$PROJECT"
(
  cd "$PROJECT"
  sandbox REVIEW_LOOP_REVIEWER=codex CLAUDE_SESSION_ID='../bad id' "$SETUP" setup script task >/dev/null
)
jq -e 'has("session_id") | not' "$PROJECT/.claude/review-loop.local.json" >/dev/null ||
  fail "setup-review-loop.sh recorded an invalid session id"
[ -z "$(find "$SESSIONS_DIR" -type f ! -name "$OTHER_SESSION" 2>/dev/null)" ] ||
  fail "setup-review-loop.sh registered an invalid session id"

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
  sandbox ARGUMENTS='command task' CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" REVIEW_LOOP_REVIEWER=codex \
    CLAUDE_SESSION_ID="$OWNER_SESSION" "$COMMAND_SCRIPT" >/dev/null
)
jq -e --arg s "$OWNER_SESSION" '.session_id == $s' "$PROJECT/.claude/review-loop.local.json" >/dev/null ||
  fail "/review-loop did not record the session id"
assert_pointer "$OWNER_SESSION" "$PROJECT"
sandbox "$REGISTRY" unregister "$OWNER_SESSION" "$PROJECT"

# Unsubstituted ${CLAUDE_SESSION_ID} falls back to the id Claude Code exports.
PROJECT="$TMP_DIR/setup-command-env"
make_project "$PROJECT"
(
  cd "$PROJECT"
  sandbox ARGUMENTS='command task' CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" REVIEW_LOOP_REVIEWER=codex \
    CLAUDE_CODE_SESSION_ID="$OWNER_SESSION" "$COMMAND_SCRIPT" >/dev/null
)
jq -e --arg s "$OWNER_SESSION" '.session_id == $s' "$PROJECT/.claude/review-loop.local.json" >/dev/null ||
  fail "/review-loop did not fall back to CLAUDE_CODE_SESSION_ID"
assert_pointer "$OWNER_SESSION" "$PROJECT"

printf 'session cwd tests passed\n'
