#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="$SCRIPT_DIR/../scripts/resolve-max-rounds.sh"
SETUP="$SCRIPT_DIR/../scripts/setup-review-loop.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

run_resolver() {
  local project_dir="$1"
  local home_dir="$2"
  shift 2
  (
    cd "$project_dir"
    env -i HOME="$home_dir" XDG_CONFIG_HOME="$home_dir/.config" PATH="$PATH" "$@" "$RESOLVER"
  )
}

assert_resolves() {
  local expected="$1"
  local project_dir="$2"
  local home_dir="$3"
  shift 3
  local output

  output=$(run_resolver "$project_dir" "$home_dir" "$@")
  if [ "$output" != "$expected" ]; then
    printf 'FAIL: expected round limit %s, got %s\n' "$expected" "$output" >&2
    exit 1
  fi
}

DEFAULT_PROJECT="$TMP_DIR/default-project"
DEFAULT_HOME="$TMP_DIR/default-home"
mkdir -p "$DEFAULT_PROJECT" "$DEFAULT_HOME"
assert_resolves 3 "$DEFAULT_PROJECT" "$DEFAULT_HOME"

CONFIG_PROJECT="$TMP_DIR/config-project"
CONFIG_HOME="$TMP_DIR/config-home"
mkdir -p "$CONFIG_PROJECT" "$CONFIG_HOME"
printf 'reviewer = "codex"\nmax_rounds = 5\n' > "$CONFIG_PROJECT/.review-loop.toml"
assert_resolves 5 "$CONFIG_PROJECT" "$CONFIG_HOME"

USER_PROJECT="$TMP_DIR/user-project"
USER_HOME="$TMP_DIR/user-home"
mkdir -p "$USER_PROJECT" "$USER_HOME/.config/review-loop"
printf 'max_rounds = 4\n' > "$USER_HOME/.config/review-loop/config.toml"
assert_resolves 4 "$USER_PROJECT" "$USER_HOME"

ENV_PROJECT="$TMP_DIR/env-project"
ENV_HOME="$TMP_DIR/env-home"
mkdir -p "$ENV_PROJECT" "$ENV_HOME/.config/review-loop"
printf 'reviewer = "codex"\nmax_rounds = 5\n' > "$ENV_PROJECT/.review-loop.toml"
printf 'max_rounds = 4\n' > "$ENV_HOME/.config/review-loop/config.toml"
assert_resolves 2 "$ENV_PROJECT" "$ENV_HOME" env REVIEW_LOOP_MAX_ROUNDS=2

for invalid in '' 0 11 abc; do
  if run_resolver "$DEFAULT_PROJECT" "$DEFAULT_HOME" env REVIEW_LOOP_MAX_ROUNDS="$invalid" >/dev/null 2>&1; then
    printf 'FAIL: invalid round limit was accepted: %q\n' "$invalid" >&2
    exit 1
  fi
done

INVALID_CONFIG_PROJECT="$TMP_DIR/invalid-config-project"
INVALID_CONFIG_HOME="$TMP_DIR/invalid-config-home"
mkdir -p "$INVALID_CONFIG_PROJECT" "$INVALID_CONFIG_HOME"
printf 'max_rounds = 0\n' > "$INVALID_CONFIG_PROJECT/.review-loop.toml"
if run_resolver "$INVALID_CONFIG_PROJECT" "$INVALID_CONFIG_HOME" >/dev/null 2>&1; then
  printf 'FAIL: invalid project round limit was accepted\n' >&2
  exit 1
fi

SETUP_PROJECT="$TMP_DIR/setup-project"
SETUP_HOME="$TMP_DIR/setup-home"
mkdir -p "$SETUP_PROJECT" "$SETUP_HOME"
(
  cd "$SETUP_PROJECT"
  env HOME="$SETUP_HOME" XDG_CONFIG_HOME="$SETUP_HOME/.config" \
    REVIEW_LOOP_REVIEWER=codex REVIEW_LOOP_MAX_ROUNDS=6 \
    "$SETUP" "configured rounds"
)
jq -e '.max_rounds == 6 and .round == 1 and .phase == "task"' \
  "$SETUP_PROJECT/.claude/review-loop.local.json" >/dev/null

printf 'round-limit tests passed\n'
