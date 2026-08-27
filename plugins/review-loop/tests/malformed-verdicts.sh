#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/stop-hook.sh"
TMP_DIR="$(mktemp -d)"
PROJECT_DIR="$TMP_DIR/project"
HOME_DIR="$TMP_DIR/home"
BIN_DIR="$TMP_DIR/bin"
REVIEW_ID="20260827-120000-bbbbbb"
STATE_FILE="$PROJECT_DIR/.claude/review-loop.local.json"
REVIEW_DIR="$PROJECT_DIR/reviews/$REVIEW_ID"
REVIEW_FILE="$REVIEW_DIR/review-1.md"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$PROJECT_DIR/.claude" "$PROJECT_DIR/reviews/$REVIEW_ID" \
  "$HOME_DIR/.codex" "$BIN_DIR"
printf '[features]\nmulti_agent = true\n' > "$HOME_DIR/.codex/config.toml"

write_state() {
  local phase="$1"
  cat > "$STATE_FILE" <<STATE_EOF
{
  "active": true,
  "phase": "$phase",
  "reviewer": "codex",
  "task": "malformed verdict and missing artifact test",
  "round": 1,
  "max_rounds": 3,
  "review_id": "$REVIEW_ID",
  "started_at": "2026-08-27T12:00:00Z"
}
STATE_EOF
}

write_summary() {
  cat > "$REVIEW_DIR/summary-1.md" <<'SUMMARY_EOF'
## Fixes
- fixed the reviewed issue

## Skipped findings
- None

## Quality gates
- shell test: PASS
SUMMARY_EOF
}

run_hook() {
  (
    cd "$PROJECT_DIR"
    env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" "$HOOK" <<< '{}'
  )
}

assert_verdict_prompt() {
  local verdict_content="$1"
  local output
  output=$(run_hook)
  jq -e '.decision == "block"' <<< "$output" >/dev/null
  case "$(jq -r '.reason' <<< "$output")" in
    *"absent or malformed"*)
      ;;
    *)
      printf 'FAIL: malformed verdict %q did not produce the verdict prompt\n' \
        "$verdict_content" >&2
      exit 1
      ;;
  esac
  case "$(jq -r '.reason' <<< "$output")" in
    *"missing or incomplete"*)
      printf 'FAIL: malformed verdict %q hit the summary gate instead of the verdict gate\n' \
        "$verdict_content" >&2
      exit 1
      ;;
  esac
  [ -f "$STATE_FILE" ]
  jq -e '.phase == "addressing"' "$STATE_FILE" >/dev/null
}

# ── Malformed verdicts in the addressing phase ──────────────────────────────
# Any first line other than the exact "VERDICT: PASS" / "VERDICT: FAIL" text
# must block with the verdict prompt and keep the loop state.
write_state addressing

# The hook checks the correction summary before the verdict: without a usable
# summary, a malformed review must hit the summary gate, not the verdict one.
printf 'VERDICT: MAYBE\n' > "$REVIEW_FILE"
output=$(run_hook)
jq -e '.decision == "block"' <<< "$output" >/dev/null
case "$(jq -r '.reason' <<< "$output")" in
  *"missing or incomplete"*)
    ;;
  *)
    printf 'FAIL: missing summary did not gate before the verdict\n' >&2
    exit 1
    ;;
esac

write_summary

for verdict in 'VERDICT: MAYBE' 'verdict: pass' 'PASS' 'VERDICT: PASS '; do
  printf '%s\n' "$verdict" > "$REVIEW_FILE"
  assert_verdict_prompt "$verdict"
  [ "$(cat "$REVIEW_FILE")" = "$verdict" ]
done

: > "$REVIEW_FILE"
assert_verdict_prompt "(empty file)"
[ ! -s "$REVIEW_FILE" ]

# ── Missing review artifact, runner script present ─────────────────────────
# First stop prompts Claude to run the reviewer; the second fails open and
# cleans up without deleting loop history.
write_state addressing
rm -f "$REVIEW_FILE"
touch "$PROJECT_DIR/.claude/review-loop-run-codex.sh"

output=$(run_hook)
jq -e '.decision == "block"' <<< "$output" >/dev/null
case "$(jq -r '.reason' <<< "$output")" in
  *"has not been completed yet"*"review-loop-run-codex.sh"*)
    ;;
  *)
    printf 'FAIL: missing review did not prompt to run the reviewer\n' >&2
    exit 1
    ;;
esac
[ "$(cat "$PROJECT_DIR/.claude/review-loop-retries")" = "1" ]

output=$(run_hook)
jq -e '.decision == "approve"' <<< "$output" >/dev/null
[ ! -f "$STATE_FILE" ]
[ ! -f "$PROJECT_DIR/.claude/review-loop-retries" ]
[ -d "$REVIEW_DIR" ]

# ── Orphaned state: neither review nor runner script ───────────────────────
write_state addressing
rm -f "$REVIEW_FILE" "$PROJECT_DIR/.claude/review-loop-run-codex.sh"
output=$(run_hook)
jq -e '.decision == "approve"' <<< "$output" >/dev/null
[ ! -f "$STATE_FILE" ]
[ -d "$REVIEW_DIR" ]

# ── Reviewer produces no artifact in the task phase ────────────────────────
# The task phase must still hand off to addressing, whose missing-artifact
# gate then prompts once and fails open on the second stop.
cat > "$BIN_DIR/codex" <<'CODEX_EOF'
#!/usr/bin/env bash
exit 0
CODEX_EOF
chmod +x "$BIN_DIR/codex"

write_state task
rm -f "$REVIEW_FILE"
printf '# Review Loop Task Context\n\nmissing artifact test\n' > \
  "$REVIEW_DIR/summary-0.md"

output=$(run_hook)
jq -e '.decision == "block"' <<< "$output" >/dev/null
jq -e '.phase == "addressing"' "$STATE_FILE" >/dev/null
[ ! -e "$REVIEW_FILE" ]
[ -f "$PROJECT_DIR/.claude/review-loop-run-codex.sh" ]

output=$(run_hook)
jq -e '.decision == "block"' <<< "$output" >/dev/null
[ "$(cat "$PROJECT_DIR/.claude/review-loop-retries")" = "1" ]

output=$(run_hook)
jq -e '.decision == "approve"' <<< "$output" >/dev/null
[ ! -f "$STATE_FILE" ]
[ -d "$REVIEW_DIR" ]

printf 'malformed verdict and missing artifact tests passed\n'
