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
printf 'VERDICT: PASS\nactionable findings test\n'
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
  printf '# Review Loop Task Context\n\nActionable findings test\n' > \
    "$project_dir/reviews/$review_id/summary-0.md"
  cat > "$project_dir/.claude/review-loop.local.json" <<STATE_EOF
{
  "active": true,
  "phase": "task",
  "reviewer": "codex",
  "task": "test actionable findings",
  "round": 1,
  "max_rounds": 3,
  "review_id": "$review_id",
  "started_at": "2026-08-27T08:20:00Z"
}
STATE_EOF
}

run_hook() {
  local project_dir="$1"
  # shellcheck disable=SC2016 # $1/$2 are positional args of the inner bash
  env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" FAKE_PROMPT_FILE="$PROMPT_CAPTURE" \
    bash -c 'cd "$1" && "$2" <<< "{}"' _ "$project_dir" "$HOOK"
}

# The base requirement block must be in every rendered prompt.
assert_required_fields_rule() {
  local prompt="$1"
  local label="$2"
  case "$prompt" in
    *'ACTIONABLE FINDINGS REQUIREMENT'*'MUST NOT be reported by any agent'*) ;;
    *)
      printf 'FAIL: %s prompt dropped the actionable findings requirement\n' "$label" >&2
      exit 1
      ;;
  esac
  case "$prompt" in
    *'Severity: critical / high / medium / low'*) ;;
    *)
      printf 'FAIL: %s prompt dropped the severity field from the requirement\n' "$label" >&2
      exit 1
      ;;
  esac
}

# Every agent contract must name file, line, severity, explanation, and suggested fix.
assert_agent_contracts() {
  local prompt="$1"
  local label="$2"
  case "$prompt" in
    *'AGENT 1: Branch Diff Review'*'file path, line number, severity (critical/high/medium/low), category, explanation, and suggested fix'*) ;;
    *)
      printf 'FAIL: %s prompt dropped the diff agent finding contract\n' "$label" >&2
      exit 1
      ;;
  esac
  case "$prompt" in
    *'AGENT 2: Task-Related Structure Review'*'file path and line number (or directory for structural issues), severity (critical/high/medium/low), category, explanation, and suggested fix'*) ;;
    *)
      printf 'FAIL: %s prompt dropped the task-structure agent finding contract\n' "$label" >&2
      exit 1
      ;;
  esac
  case "$prompt" in
    *'CONSOLIDATION INSTRUCTIONS'*'Discard any finding that is missing a required field'*) ;;
    *)
      printf 'FAIL: %s prompt dropped the consolidation completeness rule\n' "$label" >&2
      exit 1
      ;;
  esac
}

PLAIN_PROJECT="$TMP_DIR/plain"
make_project "$PLAIN_PROJECT" 20260827-082000-aaaaaa
output=$(run_hook "$PLAIN_PROJECT")
jq -e '.decision == "block"' <<< "$output" >/dev/null
plain_prompt=$(cat "$PROMPT_CAPTURE")
assert_required_fields_rule "$plain_prompt" "plain"
assert_agent_contracts "$plain_prompt" "plain"
case "$plain_prompt" in
  *'AGENT 3: Next.js'*|*'AGENT (SPEC)'*|*'AGENT (UX)'*)
    printf 'FAIL: plain project got a conditional review section\n' >&2
    exit 1
    ;;
esac

ALL_FEATURES_PROJECT="$TMP_DIR/all-features"
make_project "$ALL_FEATURES_PROJECT" 20260827-082001-bbbbbb \
  next.config.mjs app/page.tsx SPEC.md PLAN.md
output=$(run_hook "$ALL_FEATURES_PROJECT")
jq -e '.decision == "block"' <<< "$output" >/dev/null
all_prompt=$(cat "$PROMPT_CAPTURE")
assert_required_fields_rule "$all_prompt" "all-features"
assert_agent_contracts "$all_prompt" "all-features"
case "$all_prompt" in
  *'AGENT 3: Task-Related Next.js & React Review'*'category, explanation, and suggested fix'*) ;;
  *)
    printf 'FAIL: all-features prompt dropped the Next.js agent finding contract\n' >&2
    exit 1
    ;;
esac
case "$all_prompt" in
  *'AGENT (SPEC): Specification and Plan Compliance Review'*'the closest line for task-level issues'*'explanation, and a concrete suggested fix'*) ;;
  *)
    printf 'FAIL: all-features prompt dropped the spec agent finding contract\n' >&2
    exit 1
    ;;
esac
case "$all_prompt" in
  *'AGENT (UX): Task-Related Browser UX Review'*'file path and line number of the component or page'*'suggested fix'*) ;;
  *)
    printf 'FAIL: all-features prompt dropped the UX agent finding contract\n' >&2
    exit 1
    ;;
esac

printf 'actionable findings tests passed\n'
