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
printf 'VERDICT: PASS\nspec review test\n'
CODEX_EOF
chmod +x "$BIN_DIR/codex"

make_project() {
  local project_dir="$1"
  local review_id="$2"
  local with_spec="$3"

  mkdir -p "$project_dir/.claude" "$project_dir/reviews/$review_id"
  git init -q "$project_dir"
  git -C "$project_dir" config user.email test@example.com
  git -C "$project_dir" config user.name 'Review Loop Test'
  printf 'base\n' > "$project_dir/base.txt"
  if [ "$with_spec" = "true" ]; then
    printf '# Authentication plan\n\nImplement login and logout.\n' > "$project_dir/SPEC.md"
    printf '# Verification plan\n\nRun the authentication tests.\n' > "$project_dir/PLAN.md"
  fi
  git -C "$project_dir" add .
  git -C "$project_dir" commit -qm base
  printf '# Review Loop Task Context\n\nSpec review test\n' > \
    "$project_dir/reviews/$review_id/summary-0.md"
  cat > "$project_dir/.claude/review-loop.local.json" <<STATE_EOF
{
  "active": true,
  "phase": "task",
  "reviewer": "codex",
  "task": "test spec review",
  "round": 1,
  "max_rounds": 3,
  "review_id": "$review_id",
  "started_at": "2026-08-27T07:06:00Z"
}
STATE_EOF
}

run_hook() {
  local project_dir="$1"
  # shellcheck disable=SC2016 # $1/$2 are positional args of the inner bash
  env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" FAKE_PROMPT_FILE="$PROMPT_CAPTURE" \
    bash -c 'cd "$1" && "$2" <<< "{}"' _ "$project_dir" "$HOOK"
}

NO_SPEC_PROJECT="$TMP_DIR/no-spec"
make_project "$NO_SPEC_PROJECT" 20260827-073000-abcdef false
output=$(run_hook "$NO_SPEC_PROJECT")
jq -e '.decision == "block"' <<< "$output" >/dev/null
no_spec_prompt=$(cat "$PROMPT_CAPTURE")
case "$no_spec_prompt" in
  *'AGENT (SPEC): Specification and Plan Compliance Review'*)
    printf 'FAIL: spec review ran without a specification or plan\n' >&2
    exit 1
    ;;
esac

SPEC_PROJECT="$TMP_DIR/with-spec"
make_project "$SPEC_PROJECT" 20260827-073001-fedcba true
output=$(run_hook "$SPEC_PROJECT")
jq -e '.decision == "block"' <<< "$output" >/dev/null
spec_prompt=$(cat "$PROMPT_CAPTURE")
case "$spec_prompt" in
  *'AGENT (SPEC): Specification and Plan Compliance Review'*'SPEC.md'*'PLAN.md'*) ;;
  *)
    printf 'FAIL: spec review omitted detected specification or plan\n' >&2
    exit 1
    ;;
esac
case "$spec_prompt" in
  *__SPEC_FILES__*)
    printf 'FAIL: spec review prompt retained a placeholder\n' >&2
    exit 1
    ;;
esac
case "$spec_prompt" in
  *'Category: which review path found it (Diff, Holistic, Spec Compliance, Next.js, UX)'*) ;;
  *)
    printf 'FAIL: consolidation prompt omitted spec review category\n' >&2
    exit 1
    ;;
esac

printf 'spec compliance tests passed\n'
