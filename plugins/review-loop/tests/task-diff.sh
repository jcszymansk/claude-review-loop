#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/stop-hook.sh"
SNAPSHOT="$SCRIPT_DIR/../scripts/capture-worktree-tree.sh"
TMP_DIR="$(mktemp -d)"
BIN_DIR="$TMP_DIR/bin"
HOME_DIR="$TMP_DIR/home"
PROMPT_CAPTURE="$TMP_DIR/prompt"
REVIEW_ID="20260906-120000-abcdef"
PROJECT_DIR="$TMP_DIR/project"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$BIN_DIR" "$HOME_DIR/.codex" "$PROJECT_DIR"
printf '[features]\nmulti_agent = true\n' > "$HOME_DIR/.codex/config.toml"
cat > "$BIN_DIR/codex" <<'CODEX_EOF'
#!/usr/bin/env bash
printf '%s' "${!#}" > "$FAKE_PROMPT_FILE"
printf 'VERDICT: PASS\ntask diff test\n'
CODEX_EOF
chmod +x "$BIN_DIR/codex"

git init -q "$PROJECT_DIR"
git -C "$PROJECT_DIR" config user.email test@example.com
git -C "$PROJECT_DIR" config user.name 'Review Loop Test'
printf 'base\n' > "$PROJECT_DIR/base.txt"
printf 'before\n' > "$PROJECT_DIR/existing.txt"
git -C "$PROJECT_DIR" add .
git -C "$PROJECT_DIR" commit -qm base

printf '.claude/\n' > "$PROJECT_DIR/.git/info/exclude"
mkdir -p "$PROJECT_DIR/.claude"
mkdir -p "$PROJECT_DIR/reviews/pre-existing"
printf 'pre-existing review artifact\n' > \
  "$PROJECT_DIR/reviews/pre-existing/review.md"

BASELINE_TREE=$(cd "$PROJECT_DIR" && "$SNAPSHOT")
BASELINE_FILES=$(git -C "$PROJECT_DIR" ls-tree -r --name-only "$BASELINE_TREE")
case "$BASELINE_FILES" in
  *'reviews/pre-existing/review.md'*)
    printf 'FAIL: baseline tree included a review artifact\n' >&2
    exit 1
    ;;
esac

printf 'reviews/\n' > "$PROJECT_DIR/.git/info/exclude"
printf 'pre-existing loop state\n' > \
  "$PROJECT_DIR/.claude/review-loop.local.json"
REVERSE_TREE=$(cd "$PROJECT_DIR" && "$SNAPSHOT")
REVERSE_FILES=$(git -C "$PROJECT_DIR" ls-tree -r --name-only "$REVERSE_TREE")
case "$REVERSE_FILES" in
  *'.claude/review-loop.local.json'*)
    printf 'FAIL: snapshot tree included loop state\n' >&2
    exit 1
    ;;
esac
printf '.claude/\n' > "$PROJECT_DIR/.git/info/exclude"

printf 'pre-existing unstaged\n' > "$PROJECT_DIR/existing.txt"
printf 'pre-existing staged\n' > "$PROJECT_DIR/staged.txt"
git -C "$PROJECT_DIR" add staged.txt
printf 'pre-existing untracked\n' > "$PROJECT_DIR/untracked.txt"
BASELINE_TREE=$(cd "$PROJECT_DIR" && "$SNAPSHOT")

printf 'task change\n' > "$PROJECT_DIR/task.txt"
mkdir -p "$PROJECT_DIR/.claude" "$PROJECT_DIR/reviews/$REVIEW_ID"
printf '# Review Loop Task Context\n\nTask diff test\n' > \
  "$PROJECT_DIR/reviews/$REVIEW_ID/summary-0.md"
cat > "$PROJECT_DIR/.claude/review-loop.local.json" <<STATE_EOF
{
  "active": true,
  "phase": "task",
  "reviewer": "codex",
  "task": "test task-start diff isolation",
  "round": 1,
  "max_rounds": 3,
  "review_id": "$REVIEW_ID",
  "started_at": "2026-09-06T12:00:00Z",
  "baseline_tree": "$BASELINE_TREE"
}
STATE_EOF

output=$(cd "$PROJECT_DIR" && \
  env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" FAKE_PROMPT_FILE="$PROMPT_CAPTURE" \
  "$HOOK" <<< '{}')
jq -e '.decision == "block"' <<< "$output" >/dev/null

TASK_DIFF="$PROJECT_DIR/reviews/$REVIEW_ID/task-diff.md"
[ -s "$TASK_DIFF" ]
grep -q 'task.txt' "$TASK_DIFF"
if grep -qE 'existing.txt|staged.txt|untracked.txt' "$TASK_DIFF"; then
  printf 'FAIL: task diff included pre-existing worktree changes\n' >&2
  exit 1
fi
PROMPT=$(cat "$PROMPT_CAPTURE")
case "$PROMPT" in
  *"reviews/$REVIEW_ID/task-diff.md"*'authoritative diff for work performed after this review loop started'*) ;;
  *)
    printf 'FAIL: review prompt omitted the authoritative task diff\n' >&2
    exit 1
    ;;
esac

printf 'task-start diff tests passed\n'
