#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/stop-hook.sh"
SETUP="$SCRIPT_DIR/../scripts/setup-review-loop.sh"
TMP_DIR="$(mktemp -d)"
PROJECT_DIR="$TMP_DIR/project"
HOME_DIR="$TMP_DIR/home"
SETUP_PROJECT_DIR="$TMP_DIR/setup-project"
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
  "task": "preserve the existing Codex workflow",
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
grep -q "REVIEWER='codex'" "$PROJECT_DIR/.claude/review-loop-run-codex.sh"
jq -e '
  .phase == "addressing"
  and (.reviewer // "codex") == "codex"
  and .task == "preserve the existing Codex workflow"
  and .round == 1
  and .max_rounds == 3
' "$PROJECT_DIR/.claude/review-loop.local.json" >/dev/null

(
  cd "$SETUP_PROJECT_DIR"
  env HOME="$SETUP_HOME_DIR" XDG_CONFIG_HOME="$XDG_DIR" PATH="$BIN_DIR:$PATH" \
    "$SETUP" "Preserve the existing Codex workflow" >/dev/null
)
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

printf 'legacy Codex compatibility test passed\n'
