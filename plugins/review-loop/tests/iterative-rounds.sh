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
if [ "${FAKE_ALWAYS_FAIL:-}" = "1" ] || [ "$count" -eq 1 ]; then
  printf 'VERDICT: FAIL\nneeds correction\n'
else
  printf 'VERDICT: PASS\nno remaining findings\n'
fi
CODEX_EOF
chmod +x "$BIN_DIR/codex"
cat > "$BIN_DIR/claude" <<'CLAUDE_EOF'
#!/usr/bin/env bash
exit 0
CLAUDE_EOF
chmod +x "$BIN_DIR/claude"

write_state() {
  local project_dir="$1"
  local review_id="$2"
  local max_rounds="$3"

  mkdir -p "$project_dir/.claude" "$project_dir/reviews/$review_id"
  printf '# Review Loop Task Context\n\niterative test\n' > \
    "$project_dir/reviews/$review_id/summary-0.md"
  cat > "$project_dir/.claude/review-loop.local.json" <<STATE_EOF
{
  "active": true,
  "phase": "task",
  "reviewer": "codex",
  "task": "test iterative rounds",
  "round": 1,
  "max_rounds": $max_rounds,
  "review_id": "$review_id",
  "started_at": "2026-08-26T12:34:56Z"
}
STATE_EOF
}

write_summary() {
  local project_dir="$1"
  local review_id="$2"
  local round="$3"

  cat > "$project_dir/reviews/$review_id/summary-$round.md" <<SUMMARY_EOF
## Fixes
- addressed findings for round $round

## Skipped findings
- None

## Quality gates
- shell test: PASS
SUMMARY_EOF
}

run_hook() {
  local project_dir="$1"
  local home_dir="$2"
  local count_file="$3"
  (
    cd "$project_dir"
    env HOME="$home_dir" PATH="$BIN_DIR:$PATH" FAKE_COUNT_FILE="$count_file" \
      "$HOOK" <<< '{}'
  )
}

PASS_PROJECT="$TMP_DIR/pass-project"
PASS_HOME="$TMP_DIR/pass-home"
PASS_COUNT="$TMP_DIR/pass-count"
PASS_REVIEW_ID="20260826-123456-abcdef"
mkdir -p "$PASS_HOME/.codex"
printf '[features]\nmulti_agent = true\n' > "$PASS_HOME/.codex/config.toml"
write_state "$PASS_PROJECT" "$PASS_REVIEW_ID" 3


output=$(run_hook "$PASS_PROJECT" "$PASS_HOME" "$PASS_COUNT")
jq -e '.decision == "block"' <<< "$output" >/dev/null
jq -e '.phase == "addressing" and .round == 1' \
  "$PASS_PROJECT/.claude/review-loop.local.json" >/dev/null
write_summary "$PASS_PROJECT" "$PASS_REVIEW_ID" 1

output=$(run_hook "$PASS_PROJECT" "$PASS_HOME" "$PASS_COUNT")
jq -e '.decision == "block"' <<< "$output" >/dev/null
jq -e '.phase == "addressing" and .round == 2' \
  "$PASS_PROJECT/.claude/review-loop.local.json" >/dev/null
write_summary "$PASS_PROJECT" "$PASS_REVIEW_ID" 2
grep -Fq 'needs correction' \
  "$PASS_PROJECT/.claude/review-loop-codex-prompt.txt"
grep -Fq 'addressed findings for round 1' \
  "$PASS_PROJECT/.claude/review-loop-codex-prompt.txt"

output=$(run_hook "$PASS_PROJECT" "$PASS_HOME" "$PASS_COUNT")
jq -e '.decision == "approve"' <<< "$output" >/dev/null
[ ! -f "$PASS_PROJECT/.claude/review-loop.local.json" ]
[ -f "$PASS_PROJECT/reviews/$PASS_REVIEW_ID/review-1.md" ]
[ -f "$PASS_PROJECT/reviews/$PASS_REVIEW_ID/review-2.md" ]

MAX_PROJECT="$TMP_DIR/max-project"
MAX_HOME="$TMP_DIR/max-home"
MAX_COUNT="$TMP_DIR/max-count"
MAX_REVIEW_ID="20260826-123456-fedcba"
mkdir -p "$MAX_HOME/.codex"
printf '[features]\nmulti_agent = true\n' > "$MAX_HOME/.codex/config.toml"
write_state "$MAX_PROJECT" "$MAX_REVIEW_ID" 2

output=$(FAKE_ALWAYS_FAIL=1 run_hook "$MAX_PROJECT" "$MAX_HOME" "$MAX_COUNT")
jq -e '.decision == "block"' <<< "$output" >/dev/null
write_summary "$MAX_PROJECT" "$MAX_REVIEW_ID" 1

output=$(FAKE_ALWAYS_FAIL=1 run_hook "$MAX_PROJECT" "$MAX_HOME" "$MAX_COUNT")
jq -e '.decision == "block"' <<< "$output" >/dev/null
jq -e '.phase == "addressing" and .round == 2' \
  "$MAX_PROJECT/.claude/review-loop.local.json" >/dev/null
write_summary "$MAX_PROJECT" "$MAX_REVIEW_ID" 2

output=$(FAKE_ALWAYS_FAIL=1 run_hook "$MAX_PROJECT" "$MAX_HOME" "$MAX_COUNT")
jq -e '.decision == "block"' <<< "$output" >/dev/null
case "$output" in
  *MAX_ROUNDS_REACHED*) ;;
  *)
    printf 'FAIL: max-round outcome was not reported: %s\n' "$output" >&2
    exit 1
    ;;
esac
[ ! -f "$MAX_PROJECT/.claude/review-loop.local.json" ]
[ -f "$MAX_PROJECT/reviews/$MAX_REVIEW_ID/review-1.md" ]
[ -f "$MAX_PROJECT/reviews/$MAX_REVIEW_ID/review-2.md" ]

printf 'iterative round tests passed\n'
