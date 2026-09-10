#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/stop-hook.sh"
TMP_DIR="$(mktemp -d)"
BIN_DIR="$TMP_DIR/bin"
HOME_DIR="$TMP_DIR/home"
REVIEW_ID="20260826-123456-abcdef"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$BIN_DIR" "$HOME_DIR/.codex"
printf '[features]\nmulti_agent = true\n' > "$HOME_DIR/.codex/config.toml"

cat > "$BIN_DIR/codex" <<'CODEX_EOF'
#!/usr/bin/env bash
printf 'VERDICT: FAIL\nneeds correction\n'
CODEX_EOF
chmod +x "$BIN_DIR/codex"

cat > "$BIN_DIR/claude" <<'CLAUDE_EOF'
#!/usr/bin/env bash
printf 'invoked\n' > "$FAKE_CLAUDE_FILE"
exit 1
CLAUDE_EOF
chmod +x "$BIN_DIR/claude"

write_state() {
  local project_dir="$1"
  mkdir -p "$project_dir/.claude" "$project_dir/reviews/$REVIEW_ID"
  printf '# Review Loop Task Context\n\nfix failing behavior\n' > \
    "$project_dir/reviews/$REVIEW_ID/summary-0.md"
  cat > "$project_dir/.claude/review-loop.local.json" <<STATE_EOF
{
  "active": true,
  "phase": "task",
  "reviewer": "codex",
  "task": "fix failing behavior",
  "round": 1,
  "max_rounds": 3,
  "review_id": "$REVIEW_ID",
  "started_at": "2026-08-26T12:34:56Z"
}
STATE_EOF
}

run_hook() {
  local project_dir="$1"
  local output_file="$2"
  local claude_file="$3"
  (
    cd "$project_dir"
    env \
      HOME="$HOME_DIR" \
      PATH="$BIN_DIR:$PATH" \
      FAKE_CLAUDE_FILE="$claude_file" \
      "$HOOK" <<< '{}'
  ) > "$output_file"
}

NONPTY_PROJECT="$TMP_DIR/non-pty-project"
NONPTY_OUTPUT="$TMP_DIR/non-pty-output"
NONPTY_CLAUDE_FILE="$TMP_DIR/non-pty-claude"
write_state "$NONPTY_PROJECT"
run_hook "$NONPTY_PROJECT" "$NONPTY_OUTPUT" "$NONPTY_CLAUDE_FILE"

PTY_PROJECT="$TMP_DIR/pty-project"
PTY_OUTPUT="$TMP_DIR/pty-output"
PTY_CLAUDE_FILE="$TMP_DIR/pty-claude"
PTY_WRAPPER="$TMP_DIR/pty-wrapper.sh"
write_state "$PTY_PROJECT"
cat > "$PTY_WRAPPER" <<HOOK_EOF
#!/usr/bin/env bash
cd "$PTY_PROJECT"
exec env \
  HOME="$HOME_DIR" \
  PATH="$BIN_DIR:\$PATH" \
  FAKE_CLAUDE_FILE="$PTY_CLAUDE_FILE" \
  "$HOOK" <<< '{}' > "$PTY_OUTPUT"
HOOK_EOF
chmod +x "$PTY_WRAPPER"
script -qefc "$PTY_WRAPPER" /dev/null <<< '{}' >/dev/null 2>&1

for output_file in "$NONPTY_OUTPUT" "$PTY_OUTPUT"; do
  jq -e '.decision == "block"' "$output_file" >/dev/null
  jq -e '.systemMessage | contains("Phase 2/2")' "$output_file" >/dev/null
  reason=$(jq -r '.reason' "$output_file")
  for required in \
    "reviews/$REVIEW_ID/review-1.md" \
    "reviews/$REVIEW_ID/summary-1.md" \
    "fix failing behavior" \
    "round 1" \
    "full round history" \
    "review-*.md" \
    "summary-*.md" \
    "Verify each item against the codebase before changing anything" \
    "## Fixes" \
    "## Skipped findings" \
    "## Quality gates"; do
    case "$reason" in
      *"$required"*) ;;
      *)
        printf 'FAIL: handoff omitted required text: %s\n' "$required" >&2
        exit 1
        ;;
    esac
  done
  case "$reason" in
    *"file and line (or directory)"*) ;;
      *)
        printf 'FAIL: handoff omitted structural finding location guidance\n' >&2
        exit 1
        ;;
  esac
  case "$reason" in
    *"reproducing it when applicable"*"by inspecting the code"*) ;;
      *)
        printf 'FAIL: handoff omitted static verification guidance\n' >&2
        exit 1
        ;;
  esac
  case "$reason" in
    *"could not verify"*"already fixed"*"Skipped findings"*) ;;
    *)
      printf 'FAIL: handoff omitted skipped-finding guidance\n' >&2
      exit 1
      ;;
  esac
done

jq -S . "$NONPTY_OUTPUT" > "$TMP_DIR/non-pty-sorted.json"
jq -S . "$PTY_OUTPUT" > "$TMP_DIR/pty-sorted.json"
cmp "$TMP_DIR/non-pty-sorted.json" "$TMP_DIR/pty-sorted.json"

for project_dir in "$NONPTY_PROJECT" "$PTY_PROJECT"; do
  jq -e '.phase == "addressing" and .round == 1' \
    "$project_dir/.claude/review-loop.local.json" >/dev/null
  [ -f "$project_dir/reviews/$REVIEW_ID/review-1.md" ]
  [ "$(head -n 1 "$project_dir/reviews/$REVIEW_ID/review-1.md")" = "VERDICT: FAIL" ]
done
[ ! -e "$NONPTY_CLAUDE_FILE" ]
[ ! -e "$PTY_CLAUDE_FILE" ]

# The Stop hook inside a reviewer process must approve exit without touching
# loop state, otherwise the reviewer re-enters the review loop recursively.
GUARD_OUTPUT="$TMP_DIR/guard-output"
(
  cd "$NONPTY_PROJECT"
  env \
    HOME="$HOME_DIR" \
    PATH="$BIN_DIR:$PATH" \
    REVIEW_LOOP_REVIEWER_PROCESS=1 \
    FAKE_CLAUDE_FILE="$NONPTY_CLAUDE_FILE" \
    "$HOOK" <<< '{}'
) > "$GUARD_OUTPUT"
jq -e '.decision == "approve"' "$GUARD_OUTPUT" >/dev/null
jq -e '.phase == "addressing" and .round == 1' \
  "$NONPTY_PROJECT/.claude/review-loop.local.json" >/dev/null
[ ! -e "$NONPTY_CLAUDE_FILE" ]

cat > "$NONPTY_PROJECT/reviews/$REVIEW_ID/summary-1.md" <<'SUMMARY_EOF'
## Fixes
- verified and fixed the failing behavior; verification: shell test PASS

## Skipped findings
- None

## Quality gates
- shell test: PASS
SUMMARY_EOF

NEXT_OUTPUT="$TMP_DIR/next-output"
run_hook "$NONPTY_PROJECT" "$NEXT_OUTPUT" "$NONPTY_CLAUDE_FILE"
jq -e '.decision == "block"' "$NEXT_OUTPUT" >/dev/null
jq -e '.phase == "addressing" and .round == 2' \
  "$NONPTY_PROJECT/.claude/review-loop.local.json" >/dev/null
[ -f "$NONPTY_PROJECT/reviews/$REVIEW_ID/review-2.md" ]
[ ! -e "$NONPTY_CLAUDE_FILE" ]

printf 'main session handoff tests passed\n'
