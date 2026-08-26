---
description: "Start a review loop: implement task, get an independent reviewer review, address feedback"
argument-hint: "<task description>"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

First, set up the review loop by running this setup command:

```bash
set -e

REVIEWER="$("${CLAUDE_PLUGIN_ROOT}/scripts/resolve-reviewer.sh")"
case "$REVIEWER" in
  codex)
    REVIEWER_CLI="codex"
    REVIEWER_NAME="Codex"
    REVIEWER_INSTALL="npm install -g @openai/codex"
    ;;
  gemini)
    REVIEWER_CLI="gemini"
    REVIEWER_NAME="Gemini"
    REVIEWER_INSTALL="npm install -g @google/gemini-cli"
    ;;
  cursor)
    REVIEWER_CLI="cursor-agent"
    REVIEWER_NAME="Cursor Agent"
    REVIEWER_INSTALL="curl https://cursor.com/install -fsS | bash"
    ;;
esac
REVIEW_ID="$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 3 2>/dev/null || head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
MAX_ROUNDS=3
mkdir -p .claude reviews
STATE_FILE=".claude/review-loop.local.json"
if [ -f "$STATE_FILE" ]; then
  echo "Error: A review loop is already active. Use /cancel-review first."
  exit 1
fi

if ! command -v "$REVIEWER_CLI" >/dev/null 2>&1; then
  echo "Error: ${REVIEWER_NAME} CLI (${REVIEWER_CLI}) is not installed."
  echo "Install it: ${REVIEWER_INSTALL}"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: 'jq' is required but not found."
  exit 1
fi

if [ "$REVIEWER" = "codex" ]; then
  "${CLAUDE_PLUGIN_ROOT}/scripts/ensure-codex-config.sh"
fi
LOOP_DIR="reviews/${REVIEW_ID}"
if ! mkdir "$LOOP_DIR"; then
  echo "Error: Review loop directory already exists: $LOOP_DIR"
  exit 1
fi

printf '# Review Loop Task Context\n\n%s\n' "$ARGUMENTS" > "$LOOP_DIR/summary-0.md"


rm -f .claude/review-loop.lock
STATE_TEMP="${STATE_FILE}.tmp.$$"
jq -n \
  --arg reviewer "$REVIEWER" \
  --arg task "$ARGUMENTS" \
  --argjson round 1 \
  --argjson max_rounds "$MAX_ROUNDS" \
  --arg review_id "$REVIEW_ID" \
  --arg started_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  '{active:true, phase:"task", reviewer:$reviewer, task:$task, round:$round, max_rounds:$max_rounds, review_id:$review_id, started_at:$started_at}' \
  > "$STATE_TEMP"
mv "$STATE_TEMP" "$STATE_FILE"
echo "Review Loop activated (ID: ${REVIEW_ID}, reviewer: ${REVIEWER})"
echo "Review artifacts: ${LOOP_DIR}/summary-0.md and ${LOOP_DIR}/review-1.md"
```

After setup completes successfully, proceed to implement the task described in the arguments. Work thoroughly and completely — write clean, well-structured, well-tested code.

Before your first stop, read `.claude/review-loop.local.json` to get the review ID and update `reviews/<review_id>/summary-0.md` with an implementation summary. Include changed files, key decisions, and verification results.

After the Stop hook runs the review:
1. Read `reviews/<review_id>/review-<round>.md` and address the findings
2. If the verdict is `VERDICT: FAIL`, the hook starts a fresh interactive Claude correction session. Read its changes and `summary-<round>.md`
3. Write a non-empty correction summary with these sections:
   - `## Fixes`
   - `## Skipped findings`
   - `## Quality gates`
   Record each fix, skipped finding, and verification command with its result (`PASS`, `FAIL`, or `NOT RUN`)
4. After the summary is complete, the hook advances to the next round and reruns the reviewer automatically
5. If the artifact or verdict is missing or malformed, rerun the generated reviewer script before addressing the findings
6. Stop only after the reviewer returns `VERDICT: PASS` and the correction summary is complete, or the hook reports `MAX_ROUNDS_REACHED`

The loop directory is kept after cleanup. Later rounds use the same directory with `review-<round>.md` and `summary-<round>.md`.

RULES:
- Complete the task to the best of your ability before stopping
- Do not stop prematurely or skip parts of the task
- Always write the required summary before stopping
- When blocked by the hook, read the review first; if the verdict is `FAIL`, address the findings and write the summary before stopping again. The hook reruns the reviewer after a complete summary; if the artifact or verdict is missing or malformed, rerun the generated script before addressing the findings.
