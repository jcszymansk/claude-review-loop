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
REVIEW_DIR="$PROJECT_DIR/reviews/$REVIEW_ID"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$PROJECT_DIR/.claude" "$HOME_DIR/.codex" "$BIN_DIR"

cat > "$HOME_DIR/.codex/config.toml" <<'CONFIG_EOF'
[features]
multi_agent = true
CONFIG_EOF

cat > "$BIN_DIR/codex" <<'CODEX_EOF'
#!/usr/bin/env bash
if [ -n "${FAKE_REVIEW_FILE:-}" ]; then
  printf 'VERDICT: FAIL\nprovider-created artifact\n' > "$FAKE_REVIEW_FILE"
  printf 'provider progress\n'
elif [ "${FAKE_REVIEW_MODE:-}" = empty ]; then
  exit 0
elif [ "${FAKE_REVIEW_MODE:-}" = malformed ]; then
  printf 'review output without a verdict\n'
elif [ "${FAKE_REVIEW_MODE:-}" = nonzero ]; then
  printf 'VERDICT: PASS\nstdout fallback\n'
  exit 7
else
  printf 'VERDICT: PASS\nstdout fallback\n'
fi
CODEX_EOF
chmod +x "$BIN_DIR/codex"

cat > "$STATE_FILE" <<STATE_EOF
{
  "active": true,
  "phase": "task",
  "reviewer": "codex",
  "task": "capture the reviewer result",
  "round": 1,
  "max_rounds": 4,
  "review_id": "$REVIEW_ID",
  "started_at": "2026-08-26T12:34:56Z"
}
STATE_EOF
expected_output=$'VERDICT: PASS\nstdout fallback'

hook_output=$(cd "$PROJECT_DIR" && env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" "$HOOK" <<< '{}')
jq -e '.decision == "block"' <<< "$hook_output" >/dev/null
if [ "$(cat "$REVIEW_DIR/review-1.md")" != "$expected_output" ]; then
  printf 'FAIL: stop hook did not run the configured reviewer\n' >&2
  exit 1
fi

RUNNER="$PROJECT_DIR/.claude/review-loop-run-codex.sh"
REVIEW_FILE="$REVIEW_DIR/review-1.md"
runner_output=$(cd "$PROJECT_DIR" && env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" "$RUNNER")

if [ "$runner_output" != "$expected_output" ]; then
  printf 'FAIL: runner did not stream reviewer output unchanged: %s\n' "$runner_output" >&2
  exit 1
fi
if [ "$(cat "$REVIEW_FILE")" != "$expected_output" ]; then
  printf 'FAIL: runner did not capture stdout into the review artifact\n' >&2
  exit 1
fi

jq '.phase = "task" | .round = 2' "$STATE_FILE" > "$STATE_FILE.tmp"
mv "$STATE_FILE.tmp" "$STATE_FILE"
hook_output=$(cd "$PROJECT_DIR" && env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" "$HOOK" <<< '{}')
jq -e '.decision == "block"' <<< "$hook_output" >/dev/null
rm -f "$REVIEW_DIR/review-2.md"

RUNNER="$PROJECT_DIR/.claude/review-loop-run-codex.sh"
REVIEW_FILE="$REVIEW_DIR/review-2.md"
(
  cd "$PROJECT_DIR"
  env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" FAKE_REVIEW_FILE="$REVIEW_FILE" "$RUNNER"
) >/dev/null
expected_artifact=$'VERDICT: FAIL\nprovider-created artifact'
if [ "$(cat "$REVIEW_FILE")" != "$expected_artifact" ]; then
  printf 'FAIL: runner overwrote a provider-created review artifact\n' >&2
  exit 1
fi

jq '.phase = "task" | .round = 3' "$STATE_FILE" > "$STATE_FILE.tmp"
mv "$STATE_FILE.tmp" "$STATE_FILE"
hook_output=$(cd "$PROJECT_DIR" && env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" "$HOOK" <<< '{}')
jq -e '.decision == "block"' <<< "$hook_output" >/dev/null
rm -f "$REVIEW_DIR/review-3.md"

RUNNER="$PROJECT_DIR/.claude/review-loop-run-codex.sh"
REVIEW_FILE="$REVIEW_DIR/review-3.md"
(
  cd "$PROJECT_DIR"
  env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" FAKE_REVIEW_MODE=malformed "$RUNNER"
) >/dev/null
if [ "$(cat "$REVIEW_FILE")" != 'review output without a verdict' ]; then
  printf 'FAIL: runner did not preserve malformed stdout for retry\n' >&2
  exit 1
fi

jq '.phase = "task" | .round = 3' "$STATE_FILE" > "$STATE_FILE.tmp"
mv "$STATE_FILE.tmp" "$STATE_FILE"
hook_output=$(cd "$PROJECT_DIR" && env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" "$HOOK" <<< '{}')
jq -e '.decision == "block"' <<< "$hook_output" >/dev/null
(
  cd "$PROJECT_DIR"
  env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" "$RUNNER"
) >/dev/null
if [ "$(cat "$REVIEW_FILE")" != "$expected_output" ]; then
  printf 'FAIL: runner did not replace a malformed fallback artifact\n' >&2
  exit 1
fi

jq '.phase = "task" | .round = 4' "$STATE_FILE" > "$STATE_FILE.tmp"
mv "$STATE_FILE.tmp" "$STATE_FILE"
hook_output=$(cd "$PROJECT_DIR" && env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" "$HOOK" <<< '{}')
jq -e '.decision == "block"' <<< "$hook_output" >/dev/null

RUNNER="$PROJECT_DIR/.claude/review-loop-run-codex.sh"
REVIEW_FILE="$REVIEW_DIR/review-4.md"
set +e
(
  cd "$PROJECT_DIR"
  env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" FAKE_REVIEW_MODE=nonzero "$RUNNER"
) >/dev/null
runner_status=$?
set -e
if [ "$runner_status" -ne 7 ]; then
  printf 'FAIL: runner masked reviewer exit status: %s\n' "$runner_status" >&2
  exit 1
fi
if [ -f "$REVIEW_FILE" ]; then
  printf 'FAIL: failed reviewer artifact remained in the canonical review path\n' >&2
  exit 1
fi
if [ "$(cat "$REVIEW_FILE.reviewer-error")" != "$expected_output" ]; then
  printf 'FAIL: runner did not preserve output from a failed reviewer\n' >&2
  exit 1
fi
jq '.phase = "task" | .round = 5' "$STATE_FILE" > "$STATE_FILE.tmp"
mv "$STATE_FILE.tmp" "$STATE_FILE"
hook_output=$(cd "$PROJECT_DIR" && env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" FAKE_REVIEW_MODE=empty "$HOOK" <<< '{}')
if ! jq -e \
  '.decision == "block" and (.reason | contains("did not produce a usable artifact"))' \
  <<< "$hook_output" >/dev/null; then
  printf 'FAIL: hook did not reject a missing review artifact: %s\n' "$hook_output" >&2
  exit 1
fi
if ! jq -e '.phase == "addressing"' "$STATE_FILE" >/dev/null; then
  printf 'FAIL: hook did not retain the addressing phase after artifact verification\n' >&2
  exit 1
fi


for temporary_file in "$REVIEW_DIR"/review-*.md.stdout.*; do
  if [ -e "$temporary_file" ]; then
    printf 'FAIL: runner left its temporary output behind\n' >&2
    exit 1
  fi
done

printf 'runner capture tests passed\n'
