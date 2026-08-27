#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/stop-hook.sh"
TMP_DIR="$(mktemp -d)"
BIN_DIR="$TMP_DIR/bin"
HOME_DIR="$TMP_DIR/home"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$BIN_DIR" "$HOME_DIR/.codex"
printf '[features]\nmulti_agent = true\n' > "$HOME_DIR/.codex/config.toml"

cat > "$BIN_DIR/codex" <<'CODEX_EOF'
#!/usr/bin/env bash
# Barrier: block until both concurrent reviews have started, so the two hook
# runs genuinely overlap regardless of scheduling. Bounded to avoid hangs.
if [ -n "${FAKE_BARRIER_FILE:-}" ]; then
  printf 'started\n' >> "$FAKE_BARRIER_FILE"
  waited=0
  while [ "$waited" -lt 200 ]; do
    if [ "$(wc -l < "$FAKE_BARRIER_FILE" 2>/dev/null || echo 0)" -ge 2 ]; then
      break
    fi
    sleep 0.05
    waited=$((waited + 1))
  done
fi
count=0
if [ -f "$FAKE_COUNT_FILE" ]; then
  count=$(cat "$FAKE_COUNT_FILE")
fi
count=$((count + 1))
printf '%s\n' "$count" > "$FAKE_COUNT_FILE"
if [ "$count" -eq 1 ]; then
  printf 'VERDICT: FAIL\nneeds correction\n'
else
  printf 'VERDICT: PASS\ncurrent round review\n'
fi
CODEX_EOF
chmod +x "$BIN_DIR/codex"
cat > "$BIN_DIR/claude" <<'CLAUDE_EOF'
#!/usr/bin/env bash
exit 0
CLAUDE_EOF
chmod +x "$BIN_DIR/claude"

write_state() {
  local run_dir="$1"
  local review_id="$2"
  local task="$3"

  mkdir -p "$run_dir/.claude" "$run_dir/reviews/$review_id"
  printf '# Review Loop Task Context\n\n%s\n' "$task" > \
    "$run_dir/reviews/$review_id/summary-0.md"
  cat > "$run_dir/.claude/review-loop.local.json" <<STATE_EOF
{
  "active": true,
  "phase": "task",
  "reviewer": "codex",
  "task": "$task",
  "round": 1,
  "max_rounds": 3,
  "review_id": "$review_id",
  "started_at": "2026-08-27T12:00:00Z"
}
STATE_EOF
}

write_summary() {
  local run_dir="$1"
  local review_id="$2"
  local round="$3"

  cat > "$run_dir/reviews/$review_id/summary-$round.md" <<SUMMARY_EOF
## Fixes
- addressed findings for round $round

## Skipped findings
- None

## Quality gates
- shell test: PASS
SUMMARY_EOF
}

# Run the hook once from run_dir; returns 0 and prints the JSON decision.
run_hook_once() {
  local run_dir="$1"
  local count_file="$2"
  local output_file="$3"
  local barrier_file="${4:-}"
  (
    cd "$run_dir"
    env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" FAKE_COUNT_FILE="$count_file" \
      ${barrier_file:+FAKE_BARRIER_FILE="$barrier_file"} \
      "$HOOK" <<< '{}' > "$output_file" 2>&1
  )
}

# ── Two loops, one repo: root loop + nested-dir loop, run concurrently ────
PROJECT="$TMP_DIR/project"
NESTED_DIR="$PROJECT/sub/deep"
ROOT_REVIEW_ID="20260827-120000-aaaaaa"
NESTED_REVIEW_ID="20260827-120001-bbbbbb"
ROOT_COUNT="$TMP_DIR/root-count"
NESTED_COUNT="$TMP_DIR/nested-count"

mkdir -p "$NESTED_DIR"
git init "$PROJECT" >/dev/null
git -C "$PROJECT" config user.email test@example.com
git -C "$PROJECT" config user.name 'Review Loop Test'
git -C "$PROJECT" checkout -b main >/dev/null 2>&1
printf '.claude/\nreviews/\n' > "$PROJECT/.gitignore"
printf 'base\n' > "$PROJECT/base.txt"
git -C "$PROJECT" add .
git -C "$PROJECT" commit -qm base
git -C "$PROJECT" checkout -b feature >/dev/null 2>&1
printf 'root work\n' > "$PROJECT/root.txt"
git -C "$PROJECT" add .
git -C "$PROJECT" commit -qm 'root work'
printf 'nested work\n' > "$NESTED_DIR/nested.txt"

write_state "$PROJECT" "$ROOT_REVIEW_ID" "concurrent root loop"
write_state "$NESTED_DIR" "$NESTED_REVIEW_ID" "concurrent nested loop"

# Round 1 for both loops at the same time: each hook writes its own runner,
# prompt, pid, review artifact, and log from its own working directory. The
# shared barrier makes both reviewers block until both have started, so the
# hook runs genuinely overlap.
ROUND1_BARRIER="$TMP_DIR/round1-barrier"
run_hook_once "$PROJECT" "$ROOT_COUNT" "$TMP_DIR/root-r1.out" "$ROUND1_BARRIER" &
ROOT_PID=$!
run_hook_once "$NESTED_DIR" "$NESTED_COUNT" "$TMP_DIR/nested-r1.out" "$ROUND1_BARRIER" &
NESTED_PID=$!
wait "$ROOT_PID"
wait "$NESTED_PID"

# Both fake reviewers reached the barrier: the loops were active concurrently.
[ "$(wc -l < "$ROUND1_BARRIER")" = "2" ]

jq -e '.decision == "block"' "$TMP_DIR/root-r1.out" >/dev/null
jq -e '.decision == "block"' "$TMP_DIR/nested-r1.out" >/dev/null
jq -e '.phase == "addressing" and .round == 1' \
  "$PROJECT/.claude/review-loop.local.json" >/dev/null
jq -e '.phase == "addressing" and .round == 1' \
  "$NESTED_DIR/.claude/review-loop.local.json" >/dev/null
[ "$(head -n 1 "$PROJECT/reviews/$ROOT_REVIEW_ID/review-1.md")" = "VERDICT: FAIL" ]
[ "$(head -n 1 "$NESTED_DIR/reviews/$NESTED_REVIEW_ID/review-1.md")" = "VERDICT: FAIL" ]

# Each loop's state, prompt, runner script, and log reference only its own
# review id, and each review dir holds only its own loop's artifacts.
jq -e '.review_id == "'"$ROOT_REVIEW_ID"'" and .review_id != "'"$NESTED_REVIEW_ID"'"' \
  "$PROJECT/.claude/review-loop.local.json" >/dev/null
jq -e '.review_id == "'"$NESTED_REVIEW_ID"'" and .review_id != "'"$ROOT_REVIEW_ID"'"' \
  "$NESTED_DIR/.claude/review-loop.local.json" >/dev/null
[ ! -d "$PROJECT/reviews/$NESTED_REVIEW_ID" ]
[ ! -d "$NESTED_DIR/reviews/$ROOT_REVIEW_ID" ]
[ -f "$PROJECT/.claude/review-loop-codex-prompt.txt" ]
[ -f "$NESTED_DIR/.claude/review-loop-codex-prompt.txt" ]
grep -q "$ROOT_REVIEW_ID" "$PROJECT/.claude/review-loop-codex-prompt.txt"
grep -q "$NESTED_REVIEW_ID" "$PROJECT/.claude/review-loop-codex-prompt.txt" && exit 1
grep -q "$NESTED_REVIEW_ID" "$NESTED_DIR/.claude/review-loop-codex-prompt.txt"
grep -q "$ROOT_REVIEW_ID" "$NESTED_DIR/.claude/review-loop-codex-prompt.txt" && exit 1
grep -q "reviews/$ROOT_REVIEW_ID/review-1.md" "$PROJECT/.claude/review-loop-run-codex.sh"
grep -q "reviews/$NESTED_REVIEW_ID/review-1.md" "$NESTED_DIR/.claude/review-loop-run-codex.sh"
grep -q "$ROOT_REVIEW_ID" "$PROJECT/.claude/review-loop.log"
grep -q "$NESTED_REVIEW_ID" "$PROJECT/.claude/review-loop.log" && exit 1
grep -q "$NESTED_REVIEW_ID" "$NESTED_DIR/.claude/review-loop.log"
grep -q "$ROOT_REVIEW_ID" "$NESTED_DIR/.claude/review-loop.log" && exit 1
[ ! -f "$PROJECT/.claude/review-loop-child.pid" ]
[ ! -f "$NESTED_DIR/.claude/review-loop-child.pid" ]

# The nested loop's generated files stay in the nested dir, never at the root.
[ ! -f "$PROJECT/sub/.claude/review-loop.local.json" ]
[ ! -d "$PROJECT/sub/reviews" ]

write_summary "$PROJECT" "$ROOT_REVIEW_ID" 1
write_summary "$NESTED_DIR" "$NESTED_REVIEW_ID" 1

# Round 2 for both loops concurrently: each advances independently to PASS,
# again synchronized so both reviews overlap.
ROUND2_BARRIER="$TMP_DIR/round2-barrier"
run_hook_once "$PROJECT" "$ROOT_COUNT" "$TMP_DIR/root-r2.out" "$ROUND2_BARRIER" &
ROOT_PID=$!
run_hook_once "$NESTED_DIR" "$NESTED_COUNT" "$TMP_DIR/nested-r2.out" "$ROUND2_BARRIER" &
NESTED_PID=$!
wait "$ROOT_PID"
wait "$NESTED_PID"

[ "$(wc -l < "$ROUND2_BARRIER")" = "2" ]

jq -e '.decision == "block"' "$TMP_DIR/root-r2.out" >/dev/null
jq -e '.decision == "block"' "$TMP_DIR/nested-r2.out" >/dev/null
jq -e '.phase == "addressing" and .round == 2' \
  "$PROJECT/.claude/review-loop.local.json" >/dev/null
jq -e '.phase == "addressing" and .round == 2' \
  "$NESTED_DIR/.claude/review-loop.local.json" >/dev/null
[ "$(head -n 1 "$PROJECT/reviews/$ROOT_REVIEW_ID/review-2.md")" = "VERDICT: PASS" ]
[ "$(head -n 1 "$NESTED_DIR/reviews/$NESTED_REVIEW_ID/review-2.md")" = "VERDICT: PASS" ]

write_summary "$PROJECT" "$ROOT_REVIEW_ID" 2
write_summary "$NESTED_DIR" "$NESTED_REVIEW_ID" 2

# Finish the root loop first; its cleanup must leave the nested loop fully
# intact (state, runner, review history).
run_hook_once "$PROJECT" "$ROOT_COUNT" "$TMP_DIR/root-r3.out"
jq -e '.decision == "approve"' "$TMP_DIR/root-r3.out" >/dev/null
[ ! -f "$PROJECT/.claude/review-loop.local.json" ]
[ ! -f "$PROJECT/.claude/review-loop-run-codex.sh" ]
[ -f "$NESTED_DIR/.claude/review-loop.local.json" ]
jq -e '.review_id == "'"$NESTED_REVIEW_ID"'"' \
  "$NESTED_DIR/.claude/review-loop.local.json" >/dev/null
[ -f "$NESTED_DIR/.claude/review-loop-run-codex.sh" ]
[ -f "$NESTED_DIR/reviews/$NESTED_REVIEW_ID/review-1.md" ]
[ -f "$NESTED_DIR/reviews/$NESTED_REVIEW_ID/review-2.md" ]

# Then the nested loop finishes and cleans up only its own files.
run_hook_once "$NESTED_DIR" "$NESTED_COUNT" "$TMP_DIR/nested-r3.out"
jq -e '.decision == "approve"' "$TMP_DIR/nested-r3.out" >/dev/null
[ ! -f "$NESTED_DIR/.claude/review-loop.local.json" ]
[ ! -f "$NESTED_DIR/.claude/review-loop-run-codex.sh" ]

# Both loops keep their full review history.
for pair in \
  "$PROJECT $ROOT_REVIEW_ID" \
  "$NESTED_DIR $NESTED_REVIEW_ID"; do
  # shellcheck disable=SC2086 # deliberate split of "$project $review_id"
  set -- $pair
  for artifact in review-1.md review-2.md summary-1.md summary-2.md branch-diff.md; do
    [ -f "$1/reviews/$2/$artifact" ]
  done
done

printf 'concurrent loop isolation tests passed\n'
