#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/stop-hook.sh"
TMP_DIR="$(mktemp -d)"
BIN_DIR="$TMP_DIR/bin"
PROJECT_DIR="$TMP_DIR/project"
HOME_DIR="$TMP_DIR/home"
REVIEW_ID="20260827-070600-abcdef"
PROMPT_CAPTURE="$TMP_DIR/prompt"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$BIN_DIR" "$HOME_DIR/.codex" "$PROJECT_DIR"
printf '[features]\nmulti_agent = true\n' > "$HOME_DIR/.codex/config.toml"

cat > "$BIN_DIR/codex" <<'CODEX_EOF'
#!/usr/bin/env bash
printf '%s' "${!#}" > "$FAKE_PROMPT_FILE"
printf 'VERDICT: PASS\nbranch diff review\n'
CODEX_EOF
chmod +x "$BIN_DIR/codex"

git init "$PROJECT_DIR" >/dev/null
git -C "$PROJECT_DIR" config user.email test@example.com
git -C "$PROJECT_DIR" config user.name 'Review Loop Test'
git -C "$PROJECT_DIR" checkout -b main >/dev/null
cat > "$PROJECT_DIR/.gitignore" <<'IGNORE_EOF'
.claude/review-loop.local.json
.claude/review-loop.log
.claude/review-loop-child.pid
reviews/
IGNORE_EOF
printf 'base-only\n' > "$PROJECT_DIR/base.txt"
git -C "$PROJECT_DIR" add .
git -C "$PROJECT_DIR" commit -m base >/dev/null
git init --bare "$TMP_DIR/origin.git" >/dev/null
git -C "$PROJECT_DIR" remote add origin "$TMP_DIR/origin.git"
git -C "$PROJECT_DIR" push origin main >/dev/null
git -C "$PROJECT_DIR" remote set-head origin main
git -C "$PROJECT_DIR" checkout -b feature >/dev/null
for commit_number in 1 2 3 4 5 6; do
  printf 'branch-%s\n' "$commit_number" > "$PROJECT_DIR/branch-$commit_number.txt"
  git -C "$PROJECT_DIR" add "branch-$commit_number.txt"
  git -C "$PROJECT_DIR" commit -m "feature $commit_number" >/dev/null
done
printf 'staged-only\n' > "$PROJECT_DIR/staged.txt"
git -C "$PROJECT_DIR" add staged.txt
printf 'worktree-only\n' > "$PROJECT_DIR/worktree.txt"

mkdir -p "$PROJECT_DIR/.claude" "$PROJECT_DIR/reviews/$REVIEW_ID"
printf '# Review Loop Task Context\n\nbranch diff test\n' > \
  "$PROJECT_DIR/reviews/$REVIEW_ID/summary-0.md"
cat > "$PROJECT_DIR/.claude/review-loop.local.json" <<STATE_EOF
{
  "active": true,
  "phase": "task",
  "reviewer": "codex",
  "task": "test branch diff",
  "round": 1,
  "max_rounds": 3,
  "review_id": "$REVIEW_ID",
  "started_at": "2026-08-27T07:06:00Z"
}
STATE_EOF

output=$(cd "$PROJECT_DIR" && \
  env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" FAKE_PROMPT_FILE="$PROMPT_CAPTURE" \
  "$HOOK" <<< '{}')
jq -e '.decision == "block"' <<< "$output" >/dev/null
jq -e '.phase == "addressing"' \
  "$PROJECT_DIR/.claude/review-loop.local.json" >/dev/null

branch_diff=$(cat "$PROJECT_DIR/reviews/$REVIEW_ID/branch-diff.md")
case "$branch_diff" in
  *'Branch: feature'*'Base: '*'(merge-base with origin/main)'*'+branch-1'*'+branch-6'*'+staged-only'*'+worktree-only'*) ;;
  *)
    printf 'FAIL: branch diff omitted deep branch, base, staged, or worktree changes\n' >&2
    exit 1
    ;;
esac
case "$branch_diff" in
  *'base-only'*)
    printf 'FAIL: branch diff included unrelated base content\n' >&2
    exit 1
    ;;
esac

review_prompt=$(cat "$PROMPT_CAPTURE")
case "$review_prompt" in
  *"reviews/$REVIEW_ID/branch-diff.md"*) ;;
  *)
    printf 'FAIL: review prompt omitted branch diff artifact\n' >&2
    exit 1
    ;;
esac
case "$review_prompt" in
  *'HEAD~5'*)
    printf 'FAIL: review prompt retained fixed commit window\n' >&2
    exit 1
    ;;
esac
case "$review_prompt" in
  *'__PR_URL__'*)
    printf 'FAIL: branch review prompt retained PR placeholder\n' >&2
    exit 1
    ;;
esac
# shellcheck disable=SC2016 # backticks are literal prompt text
case "$review_prompt" in
  *'When the active diff scope starts with `local branch diff`, read the full project directory structure'*) ;;
  *)
    printf 'FAIL: no-PR review prompt lost full holistic review\n' >&2
    exit 1
    ;;
esac
case "$review_prompt" in
  *'holistic and conditional agents retain their documented full-project review coverage'*) ;;
  *)
    printf 'FAIL: local branch scope lost holistic review coverage\n' >&2
    exit 1
    ;;
esac

git -C "$PROJECT_DIR" push --set-upstream origin feature >/dev/null
git -C "$PROJECT_DIR" symbolic-ref --delete refs/remotes/origin/HEAD
SECOND_REVIEW_ID="20260827-070601-fedcba"
rm -f "$PROJECT_DIR/.claude/review-loop.local.json"
mkdir -p "$PROJECT_DIR/reviews/$SECOND_REVIEW_ID"
printf '# Review Loop Task Context\n\nupstream fallback test\n' > \
  "$PROJECT_DIR/reviews/$SECOND_REVIEW_ID/summary-0.md"
cat > "$PROJECT_DIR/.claude/review-loop.local.json" <<STATE_EOF
{
  "active": true,
  "phase": "task",
  "reviewer": "codex",
  "task": "test upstream fallback",
  "round": 1,
  "max_rounds": 3,
  "review_id": "$SECOND_REVIEW_ID",
  "started_at": "2026-08-27T07:06:01Z"
}
STATE_EOF

output=$(cd "$PROJECT_DIR" && \
  env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" FAKE_PROMPT_FILE="$PROMPT_CAPTURE" \
  "$HOOK" <<< '{}')
jq -e '.decision == "block"' <<< "$output" >/dev/null
upstream_fallback_diff=$(cat "$PROJECT_DIR/reviews/$SECOND_REVIEW_ID/branch-diff.md")
case "$upstream_fallback_diff" in
  *'(merge-base with main)'*) ;;
  *)
    printf 'FAIL: feature upstream was not rejected in favor of main\n' >&2
    exit 1
    ;;
esac
case "$upstream_fallback_diff" in
  *'origin/feature'*)
    printf 'FAIL: feature upstream hid committed branch changes\n' >&2
    exit 1
    ;;
esac


EMPTY_PROJECT_DIR="$TMP_DIR/empty-project"
EMPTY_REVIEW_ID="20260827-070602-a1b2c3"
mkdir -p "$EMPTY_PROJECT_DIR/.claude" "$EMPTY_PROJECT_DIR/reviews/$EMPTY_REVIEW_ID"
git init "$EMPTY_PROJECT_DIR" >/dev/null
printf 'staged-unborn-only\n' > "$EMPTY_PROJECT_DIR/staged.txt"
git -C "$EMPTY_PROJECT_DIR" add staged.txt
printf '# Review Loop Task Context\n\nunborn repository test\n' > \
  "$EMPTY_PROJECT_DIR/reviews/$EMPTY_REVIEW_ID/summary-0.md"
cat > "$EMPTY_PROJECT_DIR/.claude/review-loop.local.json" <<STATE_EOF
{
  "active": true,
  "phase": "task",
  "reviewer": "codex",
  "task": "test unborn repository",
  "round": 1,
  "max_rounds": 3,
  "review_id": "$EMPTY_REVIEW_ID",
  "started_at": "2026-08-27T07:06:02Z"
}
STATE_EOF

output=$(cd "$EMPTY_PROJECT_DIR" && \
  env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" FAKE_PROMPT_FILE="$PROMPT_CAPTURE" \
  "$HOOK" <<< '{}')
jq -e '.decision == "block"' <<< "$output" >/dev/null
empty_diff=$(cat "$EMPTY_PROJECT_DIR/reviews/$EMPTY_REVIEW_ID/branch-diff.md")
case "$empty_diff" in
  *"Untracked file: reviews/$EMPTY_REVIEW_ID/branch-diff.md"*)
    printf 'FAIL: unborn branch diff included itself\n' >&2
    exit 1
    ;;
esac
case "$empty_diff" in
  *'Repository has no commits yet.'*) ;;
  *)
    printf 'FAIL: unborn branch diff omitted repository status\n' >&2
    exit 1
    ;;
esac
case "$empty_diff" in
  *'staged-unborn-only'*) ;;
  *)
    printf 'FAIL: unborn branch diff omitted staged changes\n' >&2
    exit 1
    ;;
esac

printf 'branch diff tests passed\n'
