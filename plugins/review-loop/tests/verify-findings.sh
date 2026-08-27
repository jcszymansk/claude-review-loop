#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/stop-hook.sh"
COMMANDS_DIR="$SCRIPT_DIR/../commands"
TMP_DIR="$(mktemp -d)"
PROJECT_DIR="$TMP_DIR/project"
HOME_DIR="$TMP_DIR/home"
BIN_DIR="$TMP_DIR/bin"
REVIEW_ID="20260827-120000-aaaaaa"
STATE_FILE="$PROJECT_DIR/.claude/review-loop.local.json"
REVIEW_FILE="$PROJECT_DIR/reviews/$REVIEW_ID/review-1.md"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$PROJECT_DIR/.claude" "$HOME_DIR/.codex" "$BIN_DIR" "$PROJECT_DIR/reviews/$REVIEW_ID"
printf '[features]\nmulti_agent = true\n' > "$HOME_DIR/.codex/config.toml"
cat > "$BIN_DIR/codex" <<'CODEX_EOF'
#!/usr/bin/env bash
printf 'VERDICT: PASS\nno findings\n' > "$FAKE_REVIEW_FILE"
CODEX_EOF
chmod +x "$BIN_DIR/codex"

cat > "$STATE_FILE" <<STATE_EOF
{
  "active": true,
  "phase": "task",
  "reviewer": "codex",
  "task": "verify findings regression test",
  "round": 1,
  "max_rounds": 3,
  "review_id": "$REVIEW_ID",
  "started_at": "2026-08-27T12:00:00Z"
}
STATE_EOF
printf '# Review Loop Task Context\n\nverify findings regression test\n' > \
  "$PROJECT_DIR/reviews/$REVIEW_ID/summary-0.md"

# A PASS verdict needs no correction session, so the hook blocks with the
# addressing-review prompt. Its reason must require per-finding verification.
hook_output=$(cd "$PROJECT_DIR" && env \
  HOME="$HOME_DIR" \
  PATH="$BIN_DIR:$PATH" \
  FAKE_REVIEW_FILE="$REVIEW_FILE" \
  "$HOOK" <<< '{}')
jq -e '.decision == "block"' <<< "$hook_output" >/dev/null
reason=$(jq -r '.reason' <<< "$hook_output")
case "$reason" in
  *"Verify each item against the codebase before changing anything"*) ;;
  *)
    printf 'FAIL: addressing review prompt dropped the verify-before-apply step\n' >&2
    exit 1
    ;;
esac
case "$reason" in
  *"file and line (or directory)"*) ;;
  *)
    printf 'FAIL: addressing review prompt dropped the directory allowance for structural findings\n' >&2
    exit 1
    ;;
esac
case "$reason" in
  *"reproducing it when applicable"*"by inspecting the code"*) ;;
  *)
    printf 'FAIL: addressing review prompt did not allow static findings verified by inspection\n' >&2
    exit 1
    ;;
esac
case "$reason" in
  *"could not verify, or that are"*"Skipped"*"findings"*) ;;
  *)
    printf 'FAIL: addressing review prompt did not route unverified findings to skipped findings\n' >&2
    exit 1
    ;;
esac
case "$reason" in
  *"performed for each"*"Fixes section"*) ;;
  *)
    printf 'FAIL: addressing review prompt did not require recording fix verification\n' >&2
    exit 1
    ;;
esac

# The slash-command workflow must carry the same requirement.
command_doc=$(cat "$COMMANDS_DIR/review-loop.md")
case "$command_doc" in
  *"Verify each finding against the codebase before applying any change"*) ;;
  *)
    printf 'FAIL: review-loop command doc dropped the verify-before-apply step\n' >&2
    exit 1
    ;;
esac
case "$command_doc" in
  *"could not verify, that are already fixed"*"## Skipped findings"*) ;;
  *)
    printf 'FAIL: review-loop command doc did not route unverified findings to skipped findings\n' >&2
    exit 1
    ;;
esac
case "$command_doc" in
  *"reproducing it when applicable"*"by inspecting the code"*) ;;
  *)
    printf 'FAIL: review-loop command doc did not allow static findings verified by inspection\n' >&2
    exit 1
    ;;
esac

printf 'verify findings tests passed\n'
