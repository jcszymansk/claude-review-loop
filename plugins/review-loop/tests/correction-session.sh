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
CLAUDE_ARGS_FILE="$TMP_DIR/claude-args"
CLAUDE_PROMPT_FILE="$TMP_DIR/claude-prompt"
CLAUDE_ENV_FILE="$TMP_DIR/claude-env"
CLAUDECODE_FILE="$TMP_DIR/claudecode"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$PROJECT_DIR/.claude" "$HOME_DIR/.codex" "$BIN_DIR" "$PROJECT_DIR/reviews/$REVIEW_ID"

cat > "$HOME_DIR/.codex/config.toml" <<'CONFIG_EOF'
[features]
multi_agent = true
CONFIG_EOF

cat > "$BIN_DIR/codex" <<'CODEX_EOF'
#!/usr/bin/env bash
printf 'VERDICT: FAIL\nneeds correction\n' > "$FAKE_REVIEW_FILE"
CODEX_EOF
chmod +x "$BIN_DIR/codex"

cat > "$BIN_DIR/claude" <<'CLAUDE_EOF'
#!/usr/bin/env bash
printf '%s' "$*" > "$FAKE_CLAUDE_ARGS_FILE"
printf '%s' "${!#}" > "$FAKE_CLAUDE_PROMPT_FILE"
printf '%s' "${REVIEW_LOOP_CORRECTION:-}" > "$FAKE_CLAUDE_ENV_FILE"
printf '%s' "${CLAUDECODE:-}" > "$FAKE_CLAUDECODE_FILE"
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

hook_output=$(
  cd "$PROJECT_DIR"
  env \
    HOME="$HOME_DIR" \
    PATH="$BIN_DIR:$PATH" \
    FAKE_REVIEW_FILE="$REVIEW_FILE" \
    FAKE_CLAUDE_ARGS_FILE="$CLAUDE_ARGS_FILE" \
    FAKE_CLAUDE_PROMPT_FILE="$CLAUDE_PROMPT_FILE" \
    FAKE_CLAUDE_ENV_FILE="$CLAUDE_ENV_FILE" \
    FAKE_CLAUDECODE_FILE="$CLAUDECODE_FILE" \
    CLAUDECODE=parent-marker \
    "$HOOK" <<< '{}'
)

jq -e '.decision == "block"' <<< "$hook_output" >/dev/null
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
  *"reviews/$REVIEW_ID/summary-1.md"*) ;;
  *)
    printf 'FAIL: correction prompt omitted summary path\n' >&2
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

printf 'correction session tests passed\n'
