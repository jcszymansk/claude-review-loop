#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="$SCRIPT_DIR/../scripts/resolve-reviewer.sh"
TMP_DIR="$(mktemp -d)"
PROJECT_DIR="$TMP_DIR/project"
HOME_DIR="$TMP_DIR/home"
XDG_DIR="$TMP_DIR/xdg"
ERROR_FILE="$TMP_DIR/error"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$PROJECT_DIR" "$HOME_DIR/.config/review-loop" "$XDG_DIR/review-loop"

resolve_without_xdg() (
  cd "$PROJECT_DIR"
  env -i PATH="$PATH" HOME="$HOME_DIR" "$RESOLVER"
)

resolve_with_xdg() (
  cd "$PROJECT_DIR"
  env -i PATH="$PATH" HOME="$HOME_DIR" XDG_CONFIG_HOME="$XDG_DIR" "$RESOLVER"
)

resolve_with_environment() (
  cd "$PROJECT_DIR"
  env -i PATH="$PATH" HOME="$HOME_DIR" REVIEW_LOOP_REVIEWER=codex "$RESOLVER"
)
resolve_with_invalid_environment() (
  cd "$PROJECT_DIR"
  env -i PATH="$PATH" HOME="$HOME_DIR" REVIEW_LOOP_REVIEWER=unknown "$RESOLVER"
)
resolve_with_removed_environment() (
  cd "$PROJECT_DIR"
  env -i PATH="$PATH" HOME="$HOME_DIR" REVIEW_LOOP_REVIEWER=gemini "$RESOLVER"
)


assert_output() {
  local name="$1"
  local expected="$2"
  shift 2
  local actual
  actual=$("$@")
  if [ "$actual" != "$expected" ]; then
    printf 'FAIL: %s (expected %s, got %s)\n' "$name" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_failure() {
  local name="$1"
  local expected_message="$2"
  shift 2
  if "$@" 2>"$ERROR_FILE"; then
    printf 'FAIL: %s (expected failure)\n' "$name" >&2
    exit 1
  fi
  local actual_message
  actual_message=$(cat "$ERROR_FILE")
  if [[ "$actual_message" != *"$expected_message"* ]]; then
    printf 'FAIL: %s (unexpected error: %s)\n' "$name" "$actual_message" >&2
    exit 1
  fi
}

assert_output "default reviewer" codex resolve_without_xdg

printf 'reviewer = "gemini"\n' > "$HOME_DIR/.config/review-loop/config.toml"
assert_failure "removed user reviewer" "unsupported reviewer 'gemini'" resolve_without_xdg

printf 'reviewer = "cursor"\n' > "$XDG_DIR/review-loop/config.toml"
assert_output "xdg config reviewer" cursor resolve_with_xdg

printf 'reviewer = "cursor"\n' > "$PROJECT_DIR/.review-loop.toml"
assert_output "project config precedence" cursor resolve_with_xdg
assert_output "environment precedence" codex resolve_with_environment

printf 'reviewer = "unknown"\n' > "$PROJECT_DIR/.review-loop.toml"
assert_failure "unsupported project reviewer" "unsupported reviewer 'unknown'" resolve_with_xdg
assert_failure "unsupported environment reviewer" "unsupported reviewer 'unknown'" resolve_with_invalid_environment
assert_failure "removed environment reviewer" "unsupported reviewer 'gemini'" resolve_with_removed_environment

printf 'review = "cursor"\n' > "$PROJECT_DIR/.review-loop.toml"
assert_failure "malformed project config" "must define reviewer" resolve_with_xdg

printf 'review = "codex"\n' > "$HOME_DIR/.config/review-loop/config.toml"
rm -f "$PROJECT_DIR/.review-loop.toml"
assert_failure "malformed user config" "must define reviewer" resolve_without_xdg

printf 'resolver tests passed\n'
