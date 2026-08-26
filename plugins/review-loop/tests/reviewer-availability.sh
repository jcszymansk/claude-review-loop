#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/stop-hook.sh"
TMP_DIR="$(mktemp -d)"
PROJECT_DIR="$TMP_DIR/project"
HOME_DIR="$TMP_DIR/home"
BIN_DIR="$TMP_DIR/bin"
STATE_FILE="$PROJECT_DIR/.claude/review-loop.local.md"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$PROJECT_DIR/.claude" "$HOME_DIR" "$BIN_DIR"

link_command() {
  local name="$1"
  ln -s "$(command -v "$name")" "$BIN_DIR/$name"
}

for command_name in awk bash cat date dirname grep head jq mkdir rm sed; do
  link_command "$command_name"
done

write_state() {
  local reviewer="$1"
  cat > "$STATE_FILE" <<STATE_EOF
---
active: true
phase: task
reviewer: ${reviewer}
review_id: 20260826-123456-abcdef
started_at: 2026-08-26T12:34:56Z
---

Review the existing changes.
STATE_EOF
}

assert_missing_cli() {
  local reviewer="$1"
  local cli="$2"
  local name="$3"
  local install="$4"
  local output

  write_state "$reviewer"
  output=$(cd "$PROJECT_DIR" && env -i HOME="$HOME_DIR" PATH="$BIN_DIR" "$HOOK" <<< '{}')

  if ! jq -e --arg cli "$cli" --arg name "$name" --arg install "$install" \
    '.decision == "block" and (.reason | contains($cli)) and (.reason | contains($name)) and (.reason | contains($install))' \
    <<< "$output" >/dev/null; then
    printf 'FAIL: missing %s CLI response: %s\n' "$reviewer" "$output" >&2
    exit 1
  fi

  if [ -f "$STATE_FILE" ]; then
    printf 'FAIL: missing %s CLI left active state behind\n' "$reviewer" >&2
    exit 1
  fi
}

assert_missing_cli codex codex Codex 'npm install -g @openai/codex'
assert_missing_cli gemini gemini Gemini 'npm install -g @google/gemini-cli'
assert_missing_cli cursor cursor-agent 'Cursor Agent' 'curl https://cursor.com/install -fsS | bash'

printf 'reviewer availability tests passed\n'
