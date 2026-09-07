#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/stop-hook.sh"
TMP_DIR="$(mktemp -d)"
PROJECT_DIR="$TMP_DIR/project"
HOME_DIR="$TMP_DIR/home"
BIN_DIR="$TMP_DIR/bin"
REVIEW_ID="20260826-123456-abcdef"
STATE_FILE="$PROJECT_DIR/.claude/review-loop.local.json"
REVIEW_FILE="$PROJECT_DIR/reviews/$REVIEW_ID/review-1.md"
SUMMARY_FILE="$PROJECT_DIR/reviews/$REVIEW_ID/summary-1.md"
CLAUDE_ARGS_FILE="$TMP_DIR/claude-args"
CLAUDE_PROMPT_FILE="$TMP_DIR/claude-prompt"
CLAUDE_ENV_FILE="$TMP_DIR/claude-env"
CLAUDECODE_FILE="$TMP_DIR/claudecode"
ENTRYPOINT_FILE="$TMP_DIR/claude-code-entrypoint"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

NO_CLAUDE_BIN_DIR="$TMP_DIR/no-claude-bin"
FALLBACK_PROJECT_DIR="$TMP_DIR/fallback-project"
FALLBACK_REVIEW_ID="20260826-123456-fedcba"
FALLBACK_STATE_FILE="$FALLBACK_PROJECT_DIR/.claude/review-loop.local.json"
FALLBACK_REVIEW_FILE="$FALLBACK_PROJECT_DIR/reviews/$FALLBACK_REVIEW_ID/review-1.md"
mkdir -p "$PROJECT_DIR/.claude" "$HOME_DIR/.codex" "$BIN_DIR" "$PROJECT_DIR/reviews/$REVIEW_ID" \
  "$NO_CLAUDE_BIN_DIR" "$FALLBACK_PROJECT_DIR/.claude" "$FALLBACK_PROJECT_DIR/reviews/$FALLBACK_REVIEW_ID"

cat > "$HOME_DIR/.codex/config.toml" <<'CONFIG_EOF'
[features]
multi_agent = true
CONFIG_EOF

cat > "$BIN_DIR/codex" <<'CODEX_EOF'
#!/usr/bin/env bash
printf 'VERDICT: FAIL\nneeds correction\n' > "$FAKE_REVIEW_FILE"
CODEX_EOF
chmod +x "$BIN_DIR/codex"
for command_name in bash cat chmod date dirname env grep head jq mkdir mv ps rm tee; do
  ln -s "$(command -v "$command_name")" "$NO_CLAUDE_BIN_DIR/$command_name"
done
ln -s "$BIN_DIR/codex" "$NO_CLAUDE_BIN_DIR/codex"

cat > "$BIN_DIR/claude" <<'CLAUDE_EOF'
#!/usr/bin/env bash
printf '%s' "$*" > "$FAKE_CLAUDE_ARGS_FILE"
printf '%s' "${!#}" > "$FAKE_CLAUDE_PROMPT_FILE"
printf '%s' "${REVIEW_LOOP_CORRECTION:-}" > "$FAKE_CLAUDE_ENV_FILE"
printf '%s' "${CLAUDECODE:-}" > "$FAKE_CLAUDECODE_FILE"
printf '%s' "${CLAUDE_CODE_ENTRYPOINT:-}" > "$FAKE_ENTRYPOINT_FILE"
cat > "$FAKE_CLAUDE_SUMMARY_FILE" <<'SUMMARY_EOF'
## Fixes
- fixed the failing behavior

## Skipped findings
- None

## Quality gates
- shell test: PASS
SUMMARY_EOF
CLAUDE_EOF
chmod +x "$BIN_DIR/claude"

cat > "$STATE_FILE" <<STATE_EOF
{
  "active": true,
  "phase": "task",
  "reviewer": "codex",
  "task": "fix the failing behavior",
  "round": 1,
  "max_rounds": 3,
  "review_id": "$REVIEW_ID",
  "started_at": "2026-08-26T12:34:56Z"
}
STATE_EOF

PTY_HOOK="$TMP_DIR/pty-hook.sh"
cat > "$PTY_HOOK" <<HOOK_EOF
#!/usr/bin/env bash
cd "$PROJECT_DIR"
exec env \
  HOME="$HOME_DIR" \
  PATH="$BIN_DIR:$PATH" \
  FAKE_REVIEW_FILE="$REVIEW_FILE" \
  FAKE_CLAUDE_ARGS_FILE="$CLAUDE_ARGS_FILE" \
  FAKE_CLAUDE_PROMPT_FILE="$CLAUDE_PROMPT_FILE" \
  FAKE_CLAUDE_ENV_FILE="$CLAUDE_ENV_FILE" \
  FAKE_CLAUDECODE_FILE="$CLAUDECODE_FILE" \
  FAKE_ENTRYPOINT_FILE="$ENTRYPOINT_FILE" \
  FAKE_CLAUDE_SUMMARY_FILE="$SUMMARY_FILE" \
  CLAUDECODE=parent-marker \
  CLAUDE_CODE_ENTRYPOINT=parent-marker \
  "$HOOK"
HOOK_EOF
chmod +x "$PTY_HOOK"

script -qefc "$PTY_HOOK" /dev/null <<< '{}' >/dev/null

jq -e '.phase == "addressing" and .round == 1' "$STATE_FILE" >/dev/null

if [ ! -s "$CLAUDE_ARGS_FILE" ] || [ ! -s "$CLAUDE_PROMPT_FILE" ]; then
  printf 'FAIL: fresh Claude correction session was not started\n' >&2
  exit 1
fi

claude_args=$(cat "$CLAUDE_ARGS_FILE")
case "$claude_args" in
  *"--dangerously-skip-permissions"*) ;;
  *)
    printf 'FAIL: correction session did not use interactive permission flags: %s\n' "$claude_args" >&2
    exit 1
    ;;
esac
case "$claude_args" in
  *" -p "*|*"--bare"*)
    printf 'FAIL: first correction session was not interactive: %s\n' "$claude_args" >&2
    exit 1
    ;;
esac

claude_prompt=$(cat "$CLAUDE_PROMPT_FILE")
case "$claude_prompt" in
  *"reviews/$REVIEW_ID/review-1.md"*) ;;
  *)
    printf 'FAIL: correction prompt omitted review path\n' >&2
    exit 1
    ;;
esac
case "$claude_prompt" in
  *"review-*.md"*) ;;
  *)
    printf 'FAIL: correction prompt omitted review history glob\n' >&2
    exit 1
    ;;
esac
case "$claude_prompt" in
  *"summary-*.md"*) ;;
  *)
    printf 'FAIL: correction prompt omitted summary history glob\n' >&2
    exit 1
    ;;
esac
case "$claude_prompt" in
  *"full round history"*) ;;
  *)
    printf 'FAIL: correction prompt omitted full round history instruction\n' >&2
    exit 1
    ;;
esac
case "$claude_prompt" in
  *"reviews/$REVIEW_ID/summary-0.md"*) ;;
  *)
    printf 'FAIL: correction prompt omitted initial task summary path\n' >&2
    exit 1
    ;;
esac
case "$claude_prompt" in
  *"reviews/$REVIEW_ID/summary-1.md"*) ;;
  *)
    printf 'FAIL: correction prompt omitted summary path\n' >&2
    exit 1
    ;;
esac
case "$claude_prompt" in
  *"## Fixes"*) ;;
  *)
    printf 'FAIL: correction prompt omitted fixes section\n' >&2
    exit 1
    ;;
esac
case "$claude_prompt" in
  *"## Skipped findings"*) ;;
  *)
    printf 'FAIL: correction prompt omitted skipped findings section\n' >&2
    exit 1
    ;;
esac
case "$claude_prompt" in
  *"## Quality gates"*) ;;
  *)
    printf 'FAIL: correction prompt omitted quality gates section\n' >&2
    exit 1
    ;;
esac
case "$claude_prompt" in
  *"fix the failing behavior"*) ;;
  *)
    printf 'FAIL: correction prompt omitted task context\n' >&2
    exit 1
    ;;
esac
case "$claude_prompt" in
  *"Verify each finding against the codebase"*"before changing anything"*) ;;
  *)
    printf 'FAIL: correction prompt did not require verification before fixes\n' >&2
    exit 1
    ;;
esac
case "$claude_prompt" in
  *"file and line (or directory)"*) ;;
  *)
    printf 'FAIL: correction prompt dropped the directory allowance for structural findings\n' >&2
    exit 1
    ;;
esac
case "$claude_prompt" in
  *"reproducing it when applicable"*"by inspecting the code"*) ;;
  *)
    printf 'FAIL: correction prompt did not allow static findings verified by inspection\n' >&2
    exit 1
    ;;
esac
case "$claude_prompt" in
  *"could not verify, that are already fixed"*"findings with the reason"*) ;;
  *)
    printf 'FAIL: correction prompt did not route unverified findings to skipped findings\n' >&2
    exit 1
    ;;
esac
case "$claude_prompt" in
  *"performed for each"*"fix in the Fixes section"*) ;;
  *)
    printf 'FAIL: correction prompt did not require recording fix verification\n' >&2
    exit 1
    ;;
esac

case "$(cat "$PROJECT_DIR/.claude/review-loop.log")" in
  *"Fresh interactive Claude correction session finished"*) ;;
  *)
    printf 'FAIL: correction session completion was not logged\n' >&2
    exit 1
    ;;
esac

if [ "$(cat "$CLAUDE_ENV_FILE")" != "1" ]; then
  printf 'FAIL: correction session did not set its recursion guard\n' >&2
  exit 1
fi
if [ -s "$CLAUDECODE_FILE" ]; then
  printf 'FAIL: correction session inherited CLAUDECODE\n' >&2
  exit 1
fi
if [ -s "$ENTRYPOINT_FILE" ]; then
  printf 'FAIL: correction session inherited CLAUDE_CODE_ENTRYPOINT\n' >&2
  exit 1
fi

guard_output=$(
  cd "$PROJECT_DIR"
  env \
    HOME="$HOME_DIR" \
    PATH="$BIN_DIR:$PATH" \
    REVIEW_LOOP_CORRECTION=1 \
    CLAUDECODE=parent-marker \
    "$HOOK" <<< '{}'
)
jq -e '.decision == "approve"' <<< "$guard_output" >/dev/null
if [ ! -f "$STATE_FILE" ]; then
  printf 'FAIL: correction-session guard removed active state\n' >&2
  exit 1
fi

reviewer_guard_output=$(
  cd "$PROJECT_DIR"
  env \
    HOME="$HOME_DIR" \
    PATH="$BIN_DIR:$PATH" \
    REVIEW_LOOP_REVIEWER_PROCESS=1 \
    CLAUDECODE=parent-marker \
    "$HOOK" <<< '{}'
)
jq -e '.decision == "approve"' <<< "$reviewer_guard_output" >/dev/null
if [ ! -f "$STATE_FILE" ]; then
  printf 'FAIL: Claude reviewer recursion guard removed active state\n' >&2
  exit 1
fi
for section in "## Fixes" "## Skipped findings" "## Quality gates"; do
  if ! grep -Fxq "$section" "$SUMMARY_FILE"; then
    printf 'FAIL: correction session did not write %s\n' "$section" >&2
    exit 1
  fi
done

printf 'VERDICT: PASS\nno remaining findings\n' > "$REVIEW_FILE"
pass_output=$(
  cd "$PROJECT_DIR"
  env \
    HOME="$HOME_DIR" \
    PATH="$BIN_DIR:$PATH" \
    "$HOOK" <<< '{}'
)
jq -e '.decision == "approve"' <<< "$pass_output" >/dev/null
if [ -f "$STATE_FILE" ]; then
  printf 'FAIL: complete correction summary did not allow exit\n' >&2
  exit 1
fi


printf '# Review Loop Task Context\n\nfallback task\n' > "$FALLBACK_PROJECT_DIR/reviews/$FALLBACK_REVIEW_ID/summary-0.md"
cat > "$FALLBACK_STATE_FILE" <<STATE_EOF
{
  "active": true,
  "phase": "task",
  "reviewer": "codex",
  "task": "fallback correction task",
  "round": 1,
  "max_rounds": 3,
  "review_id": "$FALLBACK_REVIEW_ID",
  "started_at": "2026-08-26T12:34:56Z"
}
STATE_EOF

fallback_output=$(
  cd "$FALLBACK_PROJECT_DIR"
  env \
    HOME="$HOME_DIR" \
    PATH="$NO_CLAUDE_BIN_DIR:$PATH" \
    FAKE_REVIEW_FILE="$FALLBACK_REVIEW_FILE" \
    "$HOOK" <<< '{}'
)
jq -e '
  .decision == "block"
  and (.reason | contains("full round history"))
  and (.reason | contains("review-*.md"))
  and (.reason | contains("summary-*.md"))
  and (.reason | contains("Verify each finding against the codebase before applying"))
  and (.reason | contains("reproducing it when applicable"))
' <<< "$fallback_output" >/dev/null

printf 'correction session tests passed\n'
