#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/stop-hook.sh"
TMP_DIR="$(mktemp -d)"
BIN_DIR="$TMP_DIR/bin"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/codex" <<'CODEX_EOF'
#!/usr/bin/env bash
count=0
if [ -f "$FAKE_COUNT_FILE" ]; then
  count=$(cat "$FAKE_COUNT_FILE")
fi
count=$((count + 1))
printf '%s\n' "$count" > "$FAKE_COUNT_FILE"
printf 'VERDICT: PASS\ncurrent round review\n'
CODEX_EOF
chmod +x "$BIN_DIR/codex"

PROJECT="$TMP_DIR/project"
HOME_DIR="$TMP_DIR/home"
COUNT_FILE="$TMP_DIR/count"
REVIEW_ID="20260826-123456-abcdef"
mkdir -p "$HOME_DIR/.codex" "$PROJECT/.claude" "$PROJECT/reviews/$REVIEW_ID"
printf '[features]\nmulti_agent = true\n' > "$HOME_DIR/.codex/config.toml"
printf '# Review Loop Task Context\n\nfirst round pass test\n' > \
  "$PROJECT/reviews/$REVIEW_ID/summary-0.md"
cat > "$PROJECT/.claude/review-loop.local.json" <<STATE_EOF
{
  "active": true,
  "phase": "task",
  "reviewer": "codex",
  "task": "test first round pass",
  "round": 1,
  "max_rounds": 3,
  "review_id": "$REVIEW_ID",
  "started_at": "2026-08-26T12:34:56Z"
}
STATE_EOF

run_hook() {
  (
    cd "$PROJECT"
    env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" FAKE_COUNT_FILE="$COUNT_FILE" \
      "$HOOK" <<< '{}'
  )
}

output=$(run_hook)
jq -e '.decision == "block"' <<< "$output" >/dev/null
jq -e '.phase == "addressing" and .round == 1' \
  "$PROJECT/.claude/review-loop.local.json" >/dev/null
[ "$(head -n 1 "$PROJECT/reviews/$REVIEW_ID/review-1.md")" = "VERDICT: PASS" ]
[ "$(cat "$COUNT_FILE")" = "1" ]

output=$(run_hook)
jq -e '.decision == "block"' <<< "$output" >/dev/null
[ "$(cat "$COUNT_FILE")" = "1" ]

cat > "$PROJECT/reviews/$REVIEW_ID/summary-1.md" <<SUMMARY_EOF
## Fixes
- no findings to fix; review passed on the first round

## Skipped findings
- None

## Quality gates
- shell test: PASS
SUMMARY_EOF

output=$(run_hook)
jq -e '.decision == "approve"' <<< "$output" >/dev/null
[ ! -f "$PROJECT/.claude/review-loop.local.json" ]
[ "$(cat "$COUNT_FILE")" = "1" ]
[ -f "$PROJECT/reviews/$REVIEW_ID/review-1.md" ]
[ -f "$PROJECT/reviews/$REVIEW_ID/summary-0.md" ]
[ -f "$PROJECT/reviews/$REVIEW_ID/summary-1.md" ]

printf 'first round pass tests passed\n'
