#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/stop-hook.sh"
SETUP="$SCRIPT_DIR/../scripts/setup-review-loop.sh"
RESOLVER="$SCRIPT_DIR/../scripts/resolve-pr-url.sh"
COMMAND_FILE="$SCRIPT_DIR/../commands/review-loop.md"
TMP_DIR="$(mktemp -d)"
BIN_DIR="$TMP_DIR/bin"
PROMPT_CAPTURE="$TMP_DIR/prompt"
CURL_CAPTURE="$TMP_DIR/curl-args"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$BIN_DIR"
mkdir -p "$TMP_DIR/home/.codex"
printf '[features]\nmulti_agent = true\n' > "$TMP_DIR/home/.codex/config.toml"
cat > "$BIN_DIR/codex" <<'CODEX_EOF'
#!/usr/bin/env bash
printf '%s' "${!#}" > "$FAKE_PROMPT_FILE"
printf 'VERDICT: PASS\nPR scope review\n'
CODEX_EOF
chmod +x "$BIN_DIR/codex"
cat > "$BIN_DIR/curl" <<'CURL_EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_CURL_ARGS"
if [ "${FAKE_CURL_FAIL:-0}" = "1" ]; then
  exit 22
fi
printf 'diff --git a/pr.txt b/pr.txt\n+pull-request-only\n'
CURL_EOF
COMMAND_SCRIPT="$TMP_DIR/review-loop-command.sh"
awk '
  /^```bash$/ { capture = 1; next }
  capture && /^```$/ { exit }
  capture { print }
' "$COMMAND_FILE" > "$COMMAND_SCRIPT"
chmod +x "$COMMAND_SCRIPT"
chmod +x "$BIN_DIR/curl"

"$RESOLVER" https://github.com/acme/api/pull/42 | grep -Fqx $'github\thttps\tgithub.com\tacme\tapi\t42'
"$RESOLVER" http://gitea.example:3000/acme/api/pulls/7 | grep -Fqx $'gitea\thttp\tgitea.example:3000\tacme\tapi\t7'
if "$RESOLVER" https://github.com/acme/api/pulls/42 >/dev/null 2>&1; then
  printf 'FAIL: accepted an invalid GitHub URL\n' >&2
  exit 1
fi

make_project() {
  local project_dir="$1"
  local review_id="$2"
  local pr_url="$3"

  mkdir -p "$project_dir/.claude" "$project_dir/reviews/$review_id"
  git init -q "$project_dir"
  git -C "$project_dir" config user.email test@example.com
  git -C "$project_dir" config user.name 'Review Loop Test'
  printf 'base\n' > "$project_dir/base.txt"
  git -C "$project_dir" add base.txt
  git -C "$project_dir" commit -qm base
  printf 'branch-only\n' > "$project_dir/branch.txt"
  printf '# Review Loop Task Context\n\nPR scope test\n' > \
    "$project_dir/reviews/$review_id/summary-0.md"
  cat > "$project_dir/.claude/review-loop.local.json" <<STATE_EOF
{
  "active": true,
  "phase": "task",
  "reviewer": "codex",
  "task": "test pull request scope",
  "round": 1,
  "max_rounds": 3,
  "review_id": "$review_id",
  "started_at": "2026-08-27T07:06:00Z",
  "pr_url": "$pr_url"
}
STATE_EOF
}

GITHUB_PROJECT="$TMP_DIR/github-project"
make_project "$GITHUB_PROJECT" 20260827-070700-abcdef https://github.com/acme/api/pull/42
output=$(cd "$GITHUB_PROJECT" && \
  env PATH="$BIN_DIR:$PATH" HOME="$TMP_DIR/home" FAKE_PROMPT_FILE="$PROMPT_CAPTURE" \
    FAKE_CURL_ARGS="$CURL_CAPTURE" GITHUB_TOKEN=github-secret "$HOOK" <<< '{}')
jq -e '.decision == "block"' <<< "$output" >/dev/null
jq -e '.pr_url == "https://github.com/acme/api/pull/42"' \
  "$GITHUB_PROJECT/.claude/review-loop.local.json" >/dev/null
github_diff=$(cat "$GITHUB_PROJECT/reviews/20260827-070700-abcdef/branch-diff.md")
case "$github_diff" in
  *'Pull request: https://github.com/acme/api/pull/42'*'pull-request-only'*) ;;
  *) printf 'FAIL: GitHub PR diff was not recorded\n' >&2; exit 1 ;;
esac
case "$github_diff" in
  *'branch-only'*) printf 'FAIL: GitHub PR scope included branch diff\n' >&2; exit 1 ;;
esac
grep -Fqx 'Authorization: Bearer github-secret' "$CURL_CAPTURE"
grep -Fqx 'https://github.com/acme/api/pull/42.diff' "$CURL_CAPTURE"

GITEA_PROJECT="$TMP_DIR/gitea-project"
make_project "$GITEA_PROJECT" 20260827-070701-fedcba http://gitea.example:3000/acme/api/pulls/7
output=$(cd "$GITEA_PROJECT" && \
  env PATH="$BIN_DIR:$PATH" HOME="$TMP_DIR/home" FAKE_PROMPT_FILE="$PROMPT_CAPTURE" \
    FAKE_CURL_ARGS="$CURL_CAPTURE" GITEA_TOKEN=gitea-secret "$HOOK" <<< '{}')
jq -e '.decision == "block"' <<< "$output" >/dev/null
grep -Fqx 'Authorization: token gitea-secret' "$CURL_CAPTURE"
grep -Fqx 'http://gitea.example:3000/api/v1/repos/acme/api/pulls/7.diff' "$CURL_CAPTURE"

FALLBACK_PROJECT="$TMP_DIR/fallback-project"
make_project "$FALLBACK_PROJECT" 20260827-070702-fedcba https://github.com/acme/api/pull/43
output=$(cd "$FALLBACK_PROJECT" && \
  env PATH="$BIN_DIR:$PATH" HOME="$TMP_DIR/home" FAKE_PROMPT_FILE="$PROMPT_CAPTURE" \
    FAKE_CURL_ARGS="$CURL_CAPTURE" FAKE_CURL_FAIL=1 "$HOOK" <<< '{}')
jq -e '.decision == "block"' <<< "$output" >/dev/null
fallback_diff=$(cat "$FALLBACK_PROJECT/reviews/20260827-070702-fedcba/branch-diff.md")
case "$fallback_diff" in
  *'WARNING: Failed to fetch the pull request diff'*) ;;
  *) printf 'FAIL: PR fetch failure omitted warning\n' >&2; exit 1 ;;
esac
case "$fallback_diff" in
  *'branch-only'*) ;;
  *) printf 'FAIL: PR fetch failure omitted branch diff\n' >&2; exit 1 ;;
esac
fallback_prompt=$(cat "$PROMPT_CAPTURE")
case "$fallback_prompt" in
  *'The active scope is `local branch diff (pull request fetch failed; see warning in artifact)`'*) ;;
  *) printf 'FAIL: fallback prompt retained strict PR scope\n' >&2; exit 1 ;;
esac
case "$fallback_prompt" in
  *'When the active diff scope starts with `local branch diff`, read the full project directory structure'*) ;;
  *) printf 'FAIL: fallback prompt lost holistic review coverage\n' >&2; exit 1 ;;
esac

COMMAND_PROJECT="$TMP_DIR/command-project"
mkdir -p "$COMMAND_PROJECT"
git init -q "$COMMAND_PROJECT"
git -C "$COMMAND_PROJECT" config user.email test@example.com
git -C "$COMMAND_PROJECT" config user.name 'Review Loop Test'
printf 'base\n' > "$COMMAND_PROJECT/base.txt"
git -C "$COMMAND_PROJECT" add base.txt
git -C "$COMMAND_PROJECT" commit -qm base
(
  cd "$COMMAND_PROJECT"
  env PATH="$BIN_DIR:$PATH" HOME="$TMP_DIR/home" ARGUMENTS='--pr https://github.com/acme/api/pull/55 command path task' \
    CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR/.." REVIEW_LOOP_PR= REVIEW_LOOP_REVIEWER=codex \
    "$COMMAND_SCRIPT" >/dev/null
)
command_state="$COMMAND_PROJECT/.claude/review-loop.local.json"
jq -e '.pr_url == "https://github.com/acme/api/pull/55" and .task == "command path task"' \
  "$command_state" >/dev/null
command_output=$(cd "$COMMAND_PROJECT" && \
  env PATH="$BIN_DIR:$PATH" HOME="$TMP_DIR/home" FAKE_PROMPT_FILE="$PROMPT_CAPTURE" \
    FAKE_CURL_ARGS="$CURL_CAPTURE" GITHUB_TOKEN=github-secret "$HOOK" <<< '{}')
jq -e '.decision == "block"' <<< "$command_output" >/dev/null
command_prompt=$(cat "$PROMPT_CAPTURE")
case "$command_prompt" in
  *'https://github.com/acme/api/pull/55'*) ;;
  *) printf 'FAIL: command setup did not pass PR scope to the hook prompt\n' >&2; exit 1 ;;
esac
case "$command_prompt" in
  *'__PR_URL__'*)
    printf 'FAIL: PR review prompt retained PR placeholder\n' >&2
    exit 1
    ;;
esac

SETUP_PROJECT="$TMP_DIR/setup-project"
mkdir -p "$SETUP_PROJECT"
(
  cd "$SETUP_PROJECT"
  env PATH="$BIN_DIR:$PATH" REVIEW_LOOP_REVIEWER=codex \
    HOME="$TMP_DIR/home" REVIEW_LOOP_PR=https://github.com/acme/api/pull/44 \
    "$SETUP" --pr https://gitea.example/acme/api/pulls/8 setup-test >/dev/null
)
setup_state="$SETUP_PROJECT/.claude/review-loop.local.json"
jq -e '.pr_url == "https://gitea.example/acme/api/pulls/8" and .task == "setup-test"' \
  "$setup_state" >/dev/null

printf 'pull request scope tests passed\n'
