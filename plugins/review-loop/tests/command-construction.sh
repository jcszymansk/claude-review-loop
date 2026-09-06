#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/../scripts/run-reviewer.sh"
RESOLVER="$SCRIPT_DIR/../scripts/resolve-reviewer.sh"
TMP_DIR="$(mktemp -d)"
BIN_DIR="$TMP_DIR/bin"
PROJECT_DIR="$TMP_DIR/project"
HOME_DIR="$TMP_DIR/home"
PROMPT_FILE="$TMP_DIR/prompt.md"
ARGS_FILE="$TMP_DIR/args"
STDIN_FILE="$TMP_DIR/stdin"
EXPECTED_ARGS="$TMP_DIR/expected-args"
REVIEW_FILE="$TMP_DIR/review-1.md"
ERROR_FILE="$TMP_DIR/error"
RESOLVED_REVIEWER="$TMP_DIR/resolved-reviewer"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$BIN_DIR" "$PROJECT_DIR" "$HOME_DIR"
export PATH="$BIN_DIR:$PATH"
export FAKE_ARGS_FILE="$ARGS_FILE" FAKE_STDIN_FILE="$STDIN_FILE"

# Never inherit reviewer or flag settings from the calling environment: the
# default-argv assertions below must pass on any developer or CI machine.
unset REVIEW_LOOP_REVIEWER REVIEW_LOOP_CODEX_FLAGS REVIEW_LOOP_GEMINI_FLAGS REVIEW_LOOP_CURSOR_FLAGS
unset REVIEW_LOOP_DEBUG REVIEW_LOOP_DEBUG_FILE

cat > "$BIN_DIR/fake-reviewer" <<'FAKE_EOF'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0")" >> "$FAKE_ARGS_FILE"
for arg in "$@"; do
  printf '<%s>\n' "$arg" >> "$FAKE_ARGS_FILE"
done
if [ -n "${FAKE_CAPTURE_STDIN:-}" ]; then
  cat > "$FAKE_STDIN_FILE"
fi
if [ -n "${FAKE_STDERR:-}" ]; then
  printf '%s\n' "$FAKE_STDERR" >&2
fi
case "${FAKE_MODE:-pass}" in
  pass) printf 'VERDICT: PASS\nfake review body\n' ;;
  fail) printf 'VERDICT: FAIL\nfake findings\n' ;;
  no-verdict) printf 'review text without a verdict\n' ;;
  empty) : ;;
  crash) exit 3 ;;
  pass-then-crash) printf 'VERDICT: PASS\ncrashed review\n'; exit 7 ;;
esac
FAKE_EOF
chmod +x "$BIN_DIR/fake-reviewer"
ln -s fake-reviewer "$BIN_DIR/codex"
ln -s fake-reviewer "$BIN_DIR/gemini"
ln -s fake-reviewer "$BIN_DIR/cursor-agent"

printf 'Review this diff.\nLine two.\n' > "$PROMPT_FILE"

assert_args() {
  local expected_file="$1"
  if ! diff -u "$expected_file" "$ARGS_FILE" >&2; then
    printf 'FAIL: unexpected command construction\n' >&2
    exit 1
  fi
  : > "$ARGS_FILE"
}

assert_failure() {
  local name="$1"
  local expected_status="$2"
  local expected_message="$3"
  shift 3
  set +e
  "$@" 2>"$ERROR_FILE"
  local status=$?
  set -e
  if [ "$status" -ne "$expected_status" ]; then
    printf 'FAIL: %s (expected status %s, got %s)\n' "$name" "$expected_status" "$status" >&2
    exit 1
  fi
  if ! grep -q "$expected_message" "$ERROR_FILE"; then
    printf 'FAIL: %s (unexpected error: %s)\n' "$name" "$(cat "$ERROR_FILE")" >&2
    exit 1
  fi
}

# ── Default command construction per provider ──────────────────────────────
export FAKE_MODE=pass

"$RUNNER" codex "$PROMPT_FILE"
{
  printf 'codex\n'
  printf '<--dangerously-bypass-approvals-and-sandbox>\n'
  printf '<exec>\n'
  printf '<%s>\n' "$(cat "$PROMPT_FILE")"
} > "$EXPECTED_ARGS"
assert_args "$EXPECTED_ARGS"

"$RUNNER" gemini "$PROMPT_FILE"
{
  printf 'gemini\n'
  printf '<-p>\n'
  printf '<%s>\n' "$(cat "$PROMPT_FILE")"
  printf '<--output-format>\n'
  printf '<text>\n'
} > "$EXPECTED_ARGS"
assert_args "$EXPECTED_ARGS"

export FAKE_CAPTURE_STDIN=1
"$RUNNER" cursor "$PROMPT_FILE"
unset FAKE_CAPTURE_STDIN
{
  printf 'cursor-agent\n'
  printf '<-p>\n'
  printf '<--output-format>\n'
  printf '<text>\n'
} > "$EXPECTED_ARGS"
assert_args "$EXPECTED_ARGS"
cmp "$PROMPT_FILE" "$STDIN_FILE"

unset FAKE_MODE

# ── Flag overrides ──────────────────────────────────────────────────────────
export FAKE_MODE=pass

export REVIEW_LOOP_CODEX_FLAGS='--quiet --yes'
"$RUNNER" codex "$PROMPT_FILE"
unset REVIEW_LOOP_CODEX_FLAGS
{
  printf 'codex\n'
  printf '<--quiet>\n'
  printf '<--yes>\n'
  printf '<exec>\n'
  printf '<%s>\n' "$(cat "$PROMPT_FILE")"
} > "$EXPECTED_ARGS"
assert_args "$EXPECTED_ARGS"

export REVIEW_LOOP_GEMINI_FLAGS='--model gemini-2.5-pro'
"$RUNNER" gemini "$PROMPT_FILE"
unset REVIEW_LOOP_GEMINI_FLAGS
{
  printf 'gemini\n'
  printf '<-p>\n'
  printf '<%s>\n' "$(cat "$PROMPT_FILE")"
  printf '<--model>\n'
  printf '<gemini-2.5-pro>\n'
} > "$EXPECTED_ARGS"
assert_args "$EXPECTED_ARGS"

export REVIEW_LOOP_CURSOR_FLAGS='--print-timing'
"$RUNNER" cursor "$PROMPT_FILE"
unset REVIEW_LOOP_CURSOR_FLAGS
{
  printf 'cursor-agent\n'
  printf '<-p>\n'
  printf '<--print-timing>\n'
} > "$EXPECTED_ARGS"
assert_args "$EXPECTED_ARGS"

unset FAKE_MODE

# ── Reviewer selection flows into command construction ─────────────────────
# Prove each selection source (environment, user config, project config)
# resolves to a reviewer whose command shape the runner actually builds.
# The resolver runs isolated so the caller's HOME, XDG_CONFIG_HOME, and
# working directory cannot leak into the selection.

export FAKE_MODE=pass

# Environment variable wins with no configuration present.
(
  cd "$PROJECT_DIR"
  env -i PATH="$PATH" HOME="$HOME_DIR" REVIEW_LOOP_REVIEWER=gemini "$RESOLVER"
) > "$RESOLVED_REVIEWER"
"$RUNNER" "$(cat "$RESOLVED_REVIEWER")" "$PROMPT_FILE"
{
  printf 'gemini\n'
  printf '<-p>\n'
  printf '<%s>\n' "$(cat "$PROMPT_FILE")"
  printf '<--output-format>\n'
  printf '<text>\n'
} > "$EXPECTED_ARGS"
assert_args "$EXPECTED_ARGS"

# User config selects codex when no project config exists.
mkdir -p "$HOME_DIR/.config/review-loop"
printf 'reviewer = "codex"\n' > "$HOME_DIR/.config/review-loop/config.toml"
(
  cd "$PROJECT_DIR"
  env -i PATH="$PATH" HOME="$HOME_DIR" "$RESOLVER"
) > "$RESOLVED_REVIEWER"
"$RUNNER" "$(cat "$RESOLVED_REVIEWER")" "$PROMPT_FILE"
{
  printf 'codex\n'
  printf '<--dangerously-bypass-approvals-and-sandbox>\n'
  printf '<exec>\n'
  printf '<%s>\n' "$(cat "$PROMPT_FILE")"
} > "$EXPECTED_ARGS"
assert_args "$EXPECTED_ARGS"

# Project config selects cursor and beats the user config.
printf 'reviewer = "cursor"\n' > "$PROJECT_DIR/.review-loop.toml"
(
  cd "$PROJECT_DIR"
  env -i PATH="$PATH" HOME="$HOME_DIR" "$RESOLVER"
) > "$RESOLVED_REVIEWER"
export FAKE_CAPTURE_STDIN=1
"$RUNNER" "$(cat "$RESOLVED_REVIEWER")" "$PROMPT_FILE"
unset FAKE_CAPTURE_STDIN
{
  printf 'cursor-agent\n'
  printf '<-p>\n'
  printf '<--output-format>\n'
  printf '<text>\n'
} > "$EXPECTED_ARGS"
assert_args "$EXPECTED_ARGS"
cmp "$PROMPT_FILE" "$STDIN_FILE"

unset FAKE_MODE

# ── Unsupported reviewer and usage errors ──────────────────────────────────
assert_failure "unsupported reviewer" 2 "Unsupported reviewer: bogus" \
  "$RUNNER" bogus "$PROMPT_FILE"
assert_failure "missing arguments" 2 "Usage: run-reviewer.sh" \
  "$RUNNER"
assert_failure "missing prompt file" 2 "Usage: run-reviewer.sh" \
  "$RUNNER" codex "$TMP_DIR/missing.md"

# ── Review-file capture by verdict and exit status ─────────────────────────
export FAKE_MODE=pass
"$RUNNER" codex "$PROMPT_FILE" "$REVIEW_FILE"
unset FAKE_MODE
[ "$(head -n 1 "$REVIEW_FILE")" = "VERDICT: PASS" ]
rm -f "$REVIEW_FILE"

# Output without a verdict is still captured for inspection; the verdict
# gate runs downstream in the hook.
export FAKE_MODE=no-verdict
"$RUNNER" codex "$PROMPT_FILE" "$REVIEW_FILE"
unset FAKE_MODE
[ "$(cat "$REVIEW_FILE")" = 'review text without a verdict' ]
rm -f "$REVIEW_FILE"

# Empty output is not captured either.
export FAKE_MODE=empty
"$RUNNER" codex "$PROMPT_FILE" "$REVIEW_FILE"
unset FAKE_MODE
[ ! -e "$REVIEW_FILE" ]

# A valid existing review file is preserved even when the rerun differs.
printf 'VERDICT: FAIL\nprevious findings\n' > "$REVIEW_FILE"
export FAKE_MODE=pass
"$RUNNER" codex "$PROMPT_FILE" "$REVIEW_FILE"
unset FAKE_MODE
[ "$(head -n 1 "$REVIEW_FILE")" = "VERDICT: FAIL" ]
rm -f "$REVIEW_FILE"

# An invalid existing review file is replaced by a verdict-bearing run.
printf 'garbage\n' > "$REVIEW_FILE"
export FAKE_MODE=pass
"$RUNNER" codex "$PROMPT_FILE" "$REVIEW_FILE"
unset FAKE_MODE
[ "$(head -n 1 "$REVIEW_FILE")" = "VERDICT: PASS" ]
rm -f "$REVIEW_FILE"

# A crash without output leaves no artifact and propagates the exit status.
export FAKE_MODE=crash
set +e
"$RUNNER" codex "$PROMPT_FILE" "$REVIEW_FILE" >/dev/null 2>&1
status=$?
set -e
unset FAKE_MODE
[ "$status" -eq 3 ]
[ ! -e "$REVIEW_FILE" ]
[ ! -e "$REVIEW_FILE.reviewer-error.1" ]

# A crash after writing a verdict quarantines the artifact and vacates the
# canonical review path so the round can never read a crashed review.
export FAKE_MODE=pass-then-crash
set +e
"$RUNNER" codex "$PROMPT_FILE" "$REVIEW_FILE" >/dev/null 2>&1
status=$?
set -e
unset FAKE_MODE
[ "$status" -eq 7 ]
[ ! -e "$REVIEW_FILE" ]
[ "$(head -n 1 "$REVIEW_FILE.reviewer-error.1")" = "VERDICT: PASS" ]

# Repeated failed invocations keep every quarantined artifact numbered.
export FAKE_MODE=pass-then-crash
set +e
"$RUNNER" codex "$PROMPT_FILE" "$REVIEW_FILE" >/dev/null 2>&1
set -e
unset FAKE_MODE
[ -f "$REVIEW_FILE.reviewer-error.2" ]
DEBUG_FILE="$TMP_DIR/reviewer-debug.log"
export FAKE_MODE=pass FAKE_STDERR='stderr from fake reviewer'
"$RUNNER" cursor "$PROMPT_FILE" "$REVIEW_FILE" >/dev/null
[ ! -e "$DEBUG_FILE" ]
rm -f "$REVIEW_FILE"

export REVIEW_LOOP_DEBUG=1 REVIEW_LOOP_DEBUG_FILE="$DEBUG_FILE"
"$RUNNER" cursor "$PROMPT_FILE" "$REVIEW_FILE" >/dev/null
unset REVIEW_LOOP_DEBUG REVIEW_LOOP_DEBUG_FILE FAKE_MODE FAKE_STDERR
[ -s "$DEBUG_FILE" ]
grep -q 'reviewer=cursor' "$DEBUG_FILE"
grep -q 'invoke=cursor-agent' "$DEBUG_FILE"
grep -q 'stderr from fake reviewer' "$DEBUG_FILE"
grep -q 'fake review body' "$DEBUG_FILE"

printf 'command construction tests passed\n'
