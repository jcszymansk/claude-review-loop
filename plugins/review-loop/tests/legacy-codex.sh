#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/stop-hook.sh"
SETUP="$SCRIPT_DIR/../scripts/setup-review-loop.sh"
TMP_DIR="$(mktemp -d)"
PROJECT_DIR="$TMP_DIR/project"
HOME_DIR="$TMP_DIR/home"
SETUP_PROJECT_DIR="$TMP_DIR/setup-project"
LOOP_DIR="$PROJECT_DIR/reviews/20260826-113800-abcdef"

SETUP_HOME_DIR="$TMP_DIR/setup-home"
XDG_DIR="$TMP_DIR/xdg"
BIN_DIR="$TMP_DIR/bin"
cleanup() {
  rm -rf "$TMP_DIR"
}
mkdir -p "$PROJECT_DIR/.claude" "$HOME_DIR/.codex" "$SETUP_PROJECT_DIR" "$SETUP_HOME_DIR" "$BIN_DIR"


cat > "$HOME_DIR/.codex/config.toml" <<'CONFIG_EOF'
[features]
multi_agent = true
CONFIG_EOF

cat > "$BIN_DIR/codex" <<'CODEX_EOF'
#!/usr/bin/env bash
exit 0
CODEX_EOF
chmod +x "$BIN_DIR/codex"

cat > "$PROJECT_DIR/.review-loop.toml" <<'CONFIG_EOF'
reviewer = "cursor"
CONFIG_EOF

cat > "$PROJECT_DIR/.claude/review-loop.local.json" <<'STATE_EOF'
{
  "active": true,
  "phase": "task",
  "task": "preserve the existing Codex workflow (__TASK__)",
  "round": 1,
  "max_rounds": 3,
  "review_id": "20260826-113800-abcdef",
  "started_at": "2026-08-26T11:38:00Z"
}
STATE_EOF
OUTPUT=$(cd "$PROJECT_DIR" && env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" "$HOOK" <<< '{}')

case "$OUTPUT" in
  *'"decision": "block"'*) ;;
  *)
    printf 'FAIL: legacy state was not blocked for Codex review: %s\n' "$OUTPUT" >&2
    exit 1
    ;;
esac
if [ ! -d "$LOOP_DIR" ]; then
  printf 'FAIL: legacy state did not create its loop directory\n' >&2
  exit 1
fi

grep -q "REVIEWER='codex'" "$PROJECT_DIR/.claude/review-loop-run-codex.sh"
grep -q 'reviews/20260826-113800-abcdef/review-1.md' \
  "$PROJECT_DIR/.claude/review-loop-codex-prompt.txt"
grep -Fxq 'preserve the existing Codex workflow (__TASK__)' \
  "$PROJECT_DIR/.claude/review-loop-codex-prompt.txt"
grep -Fq 'The first line of the consolidated review file MUST be exactly one of these two lines:' \
  "$PROJECT_DIR/.claude/review-loop-codex-prompt.txt"
grep -Fxq 'VERDICT: PASS' "$PROJECT_DIR/.claude/review-loop-codex-prompt.txt"
grep -Fxq 'VERDICT: FAIL' "$PROJECT_DIR/.claude/review-loop-codex-prompt.txt"
jq -e '
  .phase == "addressing"
  and (.reviewer // "codex") == "codex"
  and .task == "preserve the existing Codex workflow (__TASK__)"
  and .round == 1
  and .max_rounds == 3
' "$PROJECT_DIR/.claude/review-loop.local.json" >/dev/null

jq '.phase = "task" | .round = 2' \
  "$PROJECT_DIR/.claude/review-loop.local.json" > "$PROJECT_DIR/.claude/review-loop.local.json.tmp"
mv "$PROJECT_DIR/.claude/review-loop.local.json.tmp" "$PROJECT_DIR/.claude/review-loop.local.json"
OUTPUT=$(cd "$PROJECT_DIR" && env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" "$HOOK" <<< '{}')
case "$OUTPUT" in
  *'"decision": "block"'*) ;;
  *)
    printf 'FAIL: round 2 state was not blocked for Codex review: %s\n' "$OUTPUT" >&2
    exit 1
    ;;
esac
grep -q 'reviews/20260826-113800-abcdef/review-2.md' \
  "$PROJECT_DIR/.claude/review-loop-codex-prompt.txt"
grep -Fxq 'preserve the existing Codex workflow (__TASK__)' \
  "$PROJECT_DIR/.claude/review-loop-codex-prompt.txt"
jq -e '.phase == "addressing" and .round == 2' \
  "$PROJECT_DIR/.claude/review-loop.local.json" >/dev/null



SETUP_OUTPUT=$(
  cd "$SETUP_PROJECT_DIR"
  env HOME="$SETUP_HOME_DIR" XDG_CONFIG_HOME="$XDG_DIR" PATH="$BIN_DIR:$PATH" \
    "$SETUP" "Preserve the existing Codex workflow"
)
case "$SETUP_OUTPUT" in
  *summary-0.md*review-1.md*) ;;
  *)
    printf 'FAIL: setup did not report numbered round artifacts: %s\n' "$SETUP_OUTPUT" >&2
    exit 1
    ;;
esac
grep -q '^multi_agent = true$' "$SETUP_HOME_DIR/.codex/config.toml"
jq -e '
  .reviewer == "codex"
  and .active == true
  and .phase == "task"
  and .task == "Preserve the existing Codex workflow"
  and .round == 1
  and .max_rounds == 3
  and (.review_id | test("^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$"))
' "$SETUP_PROJECT_DIR/.claude/review-loop.local.json" >/dev/null
SETUP_REVIEW_ID=$(jq -r '.review_id' "$SETUP_PROJECT_DIR/.claude/review-loop.local.json")
if [ ! -d "$SETUP_PROJECT_DIR/reviews/$SETUP_REVIEW_ID" ]; then
  printf 'FAIL: setup did not create its loop directory\n' >&2
  exit 1
fi
if [ ! -f "$SETUP_PROJECT_DIR/reviews/$SETUP_REVIEW_ID/summary-0.md" ]; then
  printf 'FAIL: setup did not create summary-0.md\n' >&2
  exit 1
fi
grep -q 'Preserve the existing Codex workflow' \
  "$SETUP_PROJECT_DIR/reviews/$SETUP_REVIEW_ID/summary-0.md"

printf 'legacy Codex compatibility test passed\n'
