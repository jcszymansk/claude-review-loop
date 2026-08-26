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

cat > "$PROJECT_DIR/.claude/review-loop.local.md" <<'STATE_EOF'
---
active: true
phase: task
review_id: 20260826-113800-abcdef
started_at: 2026-08-26T11:38:00Z
---

Review the existing changes.
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

(
  cd "$SETUP_PROJECT_DIR"
  env HOME="$SETUP_HOME_DIR" XDG_CONFIG_HOME="$XDG_DIR" PATH="$BIN_DIR:$PATH" \
    "$SETUP" "Preserve the existing Codex workflow" >/dev/null
)
grep -q '^multi_agent = true$' "$SETUP_HOME_DIR/.codex/config.toml"
grep -q '^reviewer: codex$' "$SETUP_PROJECT_DIR/.claude/review-loop.local.md"

printf 'legacy Codex compatibility test passed\n'
