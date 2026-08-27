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
if [ "${FAKE_ALWAYS_PASS:-}" = "1" ]; then
  printf 'VERDICT: PASS\ncurrent round review\n'
  exit 0
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

  mkdir -p "$run_dir/.claude" "$run_dir/reviews/$review_id"
  printf '# Review Loop Task Context\n\nnested worktree test\n' > \
    "$run_dir/reviews/$review_id/summary-0.md"
  cat > "$run_dir/.claude/review-loop.local.json" <<STATE_EOF
{
  "active": true,
  "phase": "task",
  "reviewer": "codex",
  "task": "test nested working directories",
  "round": 1,
  "max_rounds": 3,
  "review_id": "$review_id",
  "started_at": "2026-08-26T12:34:56Z"
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

run_hook() {
  local run_dir="$1"
  local count_file="$2"
  local extra_env="${3:-}"
  (
    cd "$run_dir"
    # shellcheck disable=SC2086
    env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" FAKE_COUNT_FILE="$count_file" $extra_env \
      "$HOOK" <<< '{}'
  )
}

# ── Nested working directory: full FAIL → PASS lifecycle ──────────────────
PROJECT="$TMP_DIR/project"
NESTED_DIR="$PROJECT/sub/deep"
REVIEW_ID="20260827-090000-abcdef"
COUNT_FILE="$TMP_DIR/nested-count"

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
printf 'feature work\n' > "$PROJECT/feature.txt"
git -C "$PROJECT" add .
git -C "$PROJECT" commit -qm 'feature work'
printf 'untracked\n' > "$NESTED_DIR/untracked.txt"

write_state "$NESTED_DIR" "$REVIEW_ID"

output=$(run_hook "$NESTED_DIR" "$COUNT_FILE")
jq -e '.decision == "block"' <<< "$output" >/dev/null
jq -e '.phase == "addressing" and .round == 1' \
  "$NESTED_DIR/.claude/review-loop.local.json" >/dev/null
[ "$(head -n 1 "$NESTED_DIR/reviews/$REVIEW_ID/review-1.md")" = "VERDICT: FAIL" ]

nested_diff="$NESTED_DIR/reviews/$REVIEW_ID/branch-diff.md"
grep -q '^# Branch diff' "$nested_diff"
grep -q '^Branch: feature$' "$nested_diff"
grep -q '+feature work' "$nested_diff"
grep -q '^--- Untracked file: untracked.txt ---$' "$nested_diff"
! grep -q 'Untracked file: reviews/' "$nested_diff"

write_summary "$NESTED_DIR" "$REVIEW_ID" 1

output=$(run_hook "$NESTED_DIR" "$COUNT_FILE")
jq -e '.decision == "block"' <<< "$output" >/dev/null
jq -e '.phase == "addressing" and .round == 2' \
  "$NESTED_DIR/.claude/review-loop.local.json" >/dev/null
[ "$(head -n 1 "$NESTED_DIR/reviews/$REVIEW_ID/review-2.md")" = "VERDICT: PASS" ]

write_summary "$NESTED_DIR" "$REVIEW_ID" 2

output=$(run_hook "$NESTED_DIR" "$COUNT_FILE")
jq -e '.decision == "approve"' <<< "$output" >/dev/null
[ ! -f "$NESTED_DIR/.claude/review-loop.local.json" ]
[ ! -f "$NESTED_DIR/.claude/review-loop-codex-prompt.txt" ]
[ -f "$NESTED_DIR/reviews/$REVIEW_ID/review-1.md" ]
[ -f "$NESTED_DIR/reviews/$REVIEW_ID/review-2.md" ]
[ -f "$NESTED_DIR/reviews/$REVIEW_ID/summary-1.md" ]
[ -f "$NESTED_DIR/reviews/$REVIEW_ID/summary-2.md" ]

# Loop state stays in the session directory; nothing leaks to the repo root.
[ ! -f "$PROJECT/.claude/review-loop.local.json" ]
[ ! -d "$PROJECT/reviews" ]

# ── Git worktree: first-round PASS lifecycle ──────────────────────────────
MAIN_REPO="$TMP_DIR/main-repo"
WORKTREE="$TMP_DIR/worktree"
WT_REVIEW_ID="20260827-090001-fedcba"
WT_COUNT="$TMP_DIR/wt-count"

git init "$MAIN_REPO" >/dev/null
git -C "$MAIN_REPO" config user.email test@example.com
git -C "$MAIN_REPO" config user.name 'Review Loop Test'
git -C "$MAIN_REPO" checkout -b main >/dev/null 2>&1
printf '.claude/\nreviews/\n' > "$MAIN_REPO/.gitignore"
printf 'base\n' > "$MAIN_REPO/base.txt"
git -C "$MAIN_REPO" add .
git -C "$MAIN_REPO" commit -qm base
git -C "$MAIN_REPO" worktree add "$WORKTREE" -b wt-branch >/dev/null 2>&1
printf 'worktree work\n' > "$WORKTREE/wt.txt"
git -C "$WORKTREE" add .
git -C "$WORKTREE" commit -qm 'worktree work'

write_state "$WORKTREE" "$WT_REVIEW_ID"

output=$(run_hook "$WORKTREE" "$WT_COUNT" "FAKE_ALWAYS_PASS=1")
jq -e '.decision == "block"' <<< "$output" >/dev/null
jq -e '.phase == "addressing" and .round == 1' \
  "$WORKTREE/.claude/review-loop.local.json" >/dev/null
[ "$(head -n 1 "$WORKTREE/reviews/$WT_REVIEW_ID/review-1.md")" = "VERDICT: PASS" ]

wt_diff="$WORKTREE/reviews/$WT_REVIEW_ID/branch-diff.md"
grep -q '^Branch: wt-branch$' "$wt_diff"
grep -q '+worktree work' "$wt_diff"

write_summary "$WORKTREE" "$WT_REVIEW_ID" 1

output=$(run_hook "$WORKTREE" "$WT_COUNT")
jq -e '.decision == "approve"' <<< "$output" >/dev/null
[ ! -f "$WORKTREE/.claude/review-loop.local.json" ]
[ -f "$WORKTREE/reviews/$WT_REVIEW_ID/review-1.md" ]
[ -f "$WORKTREE/reviews/$WT_REVIEW_ID/summary-1.md" ]

# The main checkout is untouched by the worktree loop.
[ ! -f "$MAIN_REPO/.claude/review-loop.local.json" ]
[ ! -d "$MAIN_REPO/reviews" ]

printf 'nested working directory and worktree tests passed\n'
