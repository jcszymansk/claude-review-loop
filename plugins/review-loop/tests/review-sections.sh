#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/stop-hook.sh"
TMP_DIR="$(mktemp -d)"
BIN_DIR="$TMP_DIR/bin"
HOME_DIR="$TMP_DIR/home"
PROMPT_CAPTURE="$TMP_DIR/prompt"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$BIN_DIR" "$HOME_DIR/.codex"
printf '[features]\nmulti_agent = true\n' > "$HOME_DIR/.codex/config.toml"
cat > "$BIN_DIR/codex" <<'CODEX_EOF'
#!/usr/bin/env bash
printf '%s' "${!#}" > "$FAKE_PROMPT_FILE"
printf 'VERDICT: PASS\nreview sections test\n'
CODEX_EOF
chmod +x "$BIN_DIR/codex"

make_project() {
  local project_dir="$1"
  local review_id="$2"
  shift 2
  local marker_file

  mkdir -p "$project_dir/.claude" "$project_dir/reviews/$review_id"
  git init -q "$project_dir"
  git -C "$project_dir" config user.email test@example.com
  git -C "$project_dir" config user.name 'Review Loop Test'
  printf 'base\n' > "$project_dir/base.txt"
  for marker_file in "$@"; do
    mkdir -p "$project_dir/$(dirname "$marker_file")"
    printf 'marker\n' > "$project_dir/$marker_file"
  done
  git -C "$project_dir" add .
  git -C "$project_dir" commit -qm base
  printf '# Review Loop Task Context\n\nReview sections test\n' > \
    "$project_dir/reviews/$review_id/summary-0.md"
  cat > "$project_dir/.claude/review-loop.local.json" <<STATE_EOF
{
  "active": true,
  "phase": "task",
  "reviewer": "codex",
  "task": "test review sections",
  "round": 1,
  "max_rounds": 3,
  "review_id": "$review_id",
  "started_at": "2026-08-27T08:10:00Z"
}
STATE_EOF
}

run_hook() {
  local project_dir="$1"
  env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" FAKE_PROMPT_FILE="$PROMPT_CAPTURE" \
    bash -c 'cd "$1" && "$2" <<< "{}"' _ "$project_dir" "$HOOK"
}

# Diff and architecture sections must survive in every rendered prompt.
assert_always_sections() {
  local prompt="$1"
  local label="$2"
  case "$prompt" in
    *'AGENT 1: Branch Diff Review'*'OWASP Top 10'*) ;;
    *)
      printf 'FAIL: %s prompt dropped the diff review section\n' "$label" >&2
      exit 1
      ;;
  esac
  case "$prompt" in
    *'AGENT 2: Holistic Review'*'Architecture:'*) ;;
    *)
      printf 'FAIL: %s prompt dropped the architecture review section\n' "$label" >&2
      exit 1
      ;;
  esac
}

PLAIN_PROJECT="$TMP_DIR/plain"
make_project "$PLAIN_PROJECT" 20260827-081000-aaaaaa
output=$(run_hook "$PLAIN_PROJECT")
jq -e '.decision == "block"' <<< "$output" >/dev/null
plain_prompt=$(cat "$PROMPT_CAPTURE")
assert_always_sections "$plain_prompt" "plain"
case "$plain_prompt" in
  *'AGENT 3: Next.js'*|*'AGENT (UX)'*)
    printf 'FAIL: plain project got conditional framework or UX review\n' >&2
    exit 1
    ;;
esac

NEXTJS_PROJECT="$TMP_DIR/nextjs"
make_project "$NEXTJS_PROJECT" 20260827-081001-bbbbbb \
  next.config.mjs app/page.tsx
output=$(run_hook "$NEXTJS_PROJECT")
jq -e '.decision == "block"' <<< "$output" >/dev/null
nextjs_prompt=$(cat "$PROMPT_CAPTURE")
assert_always_sections "$nextjs_prompt" "nextjs"
case "$nextjs_prompt" in
  *'AGENT 3: Next.js & React Best Practices Review'*'App Router & Server Components'*) ;;
  *)
    printf 'FAIL: Next.js project omitted the framework review section\n' >&2
    exit 1
    ;;
esac
case "$nextjs_prompt" in
  *'AGENT (UX): Browser-Based UX Review'*) ;;
  *)
    printf 'FAIL: Next.js project omitted the UX review section\n' >&2
    exit 1
    ;;
esac

UI_PROJECT="$TMP_DIR/ui-only"
make_project "$UI_PROJECT" 20260827-081002-cccccc index.html
output=$(run_hook "$UI_PROJECT")
jq -e '.decision == "block"' <<< "$output" >/dev/null
ui_prompt=$(cat "$PROMPT_CAPTURE")
assert_always_sections "$ui_prompt" "ui-only"
case "$ui_prompt" in
  *'AGENT (UX): Browser-Based UX Review'*) ;;
  *)
    printf 'FAIL: UI project omitted the UX review section\n' >&2
    exit 1
    ;;
esac
case "$ui_prompt" in
  *'AGENT 3: Next.js'*)
    printf 'FAIL: UI-only project got the Next.js review section\n' >&2
    exit 1
    ;;
esac

JS_PROJECT="$TMP_DIR/plain-js"
make_project "$JS_PROJECT" 20260827-081003-dddddd package.json
output=$(run_hook "$JS_PROJECT")
jq -e '.decision == "block"' <<< "$output" >/dev/null
js_prompt=$(cat "$PROMPT_CAPTURE")
assert_always_sections "$js_prompt" "plain-js"
case "$js_prompt" in
  *'AGENT 3: Next.js'*|*'AGENT (UX)'*)
    printf 'FAIL: non-Next.js JS project got conditional framework or UX review\n' >&2
    exit 1
    ;;
esac

printf 'review sections tests passed\n'
