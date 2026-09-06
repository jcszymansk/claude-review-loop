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

Set `REVIEW_LOOP_PR` or start the command with `--pr <url>` to scope the
review to a GitHub or Gitea pull request.

```bash
#!/usr/bin/env bash
set -e

PR_URL="${REVIEW_LOOP_PR:-}"
TASK_ARGUMENTS="$ARGUMENTS"
if [[ "$ARGUMENTS" == "--pr" || "$ARGUMENTS" == --pr[[:space:]]* ]]; then
  if [[ "$ARGUMENTS" =~ ^--pr[[:space:]]+([^[:space:]]+)([[:space:]]+(.+))?$ ]]; then
    PR_URL="${BASH_REMATCH[1]}"
    TASK_ARGUMENTS="${BASH_REMATCH[3]}"
  else
    echo "Error: --pr requires a pull request URL."
    exit 1
  fi
fi
if [ -n "$PR_URL" ] && ! "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-pr-url.sh" "$PR_URL" >/dev/null; then
  echo "Error: invalid pull request URL: $PR_URL"
  exit 1
fi

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
MAX_ROUNDS="$("${CLAUDE_PLUGIN_ROOT}/scripts/resolve-max-rounds.sh")"
mkdir -p .claude reviews
STATE_FILE=".claude/review-loop.local.json"
if [ -f "$STATE_FILE" ]; then
  echo "Error: A review loop is already active. Use /cancel-review first."
  exit 1
fi
BASELINE_TREE="$("${CLAUDE_PLUGIN_ROOT}/scripts/capture-worktree-tree.sh")"

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

printf '# Review Loop Task Context\n\n%s\n' "$TASK_ARGUMENTS" > "$LOOP_DIR/summary-0.md"


rm -f .claude/review-loop.lock .claude/review-loop-child.pid .claude/review-loop-child.pid.tmp.*
STATE_TEMP="${STATE_FILE}.tmp.$$"
jq -n \
  --arg reviewer "$REVIEWER" \
  --arg task "$TASK_ARGUMENTS" \
  --arg pr_url "$PR_URL" \
  --arg baseline_tree "$BASELINE_TREE" \
  --argjson round 1 \
  --argjson max_rounds "$MAX_ROUNDS" \
  --arg review_id "$REVIEW_ID" \
  --arg started_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  '{active:true, phase:"task", reviewer:$reviewer, task:$task, round:$round, max_rounds:$max_rounds, review_id:$review_id, started_at:$started_at, baseline_tree:$baseline_tree} |
   if $pr_url == "" then . else . + {pr_url:$pr_url} end' \
  > "$STATE_TEMP"
mv "$STATE_TEMP" "$STATE_FILE"
echo "Review Loop activated (ID: ${REVIEW_ID}, reviewer: ${REVIEWER})"
echo "Review artifacts: ${LOOP_DIR}/summary-0.md and ${LOOP_DIR}/review-1.md"
```

After setup completes successfully, proceed to implement the task described in the arguments. Work thoroughly and completely — write clean, well-structured, well-tested code.

Before your first stop, read `.claude/review-loop.local.json` to get the review ID and update `reviews/<review_id>/summary-0.md` with an implementation summary. Include changed files, key decisions, and verification results.

After the Stop hook runs the review:
1. Read `reviews/<review_id>/review-<round>.md` and address the findings
2. Verify each finding against the codebase before applying any change: open the referenced file and line (or directory), and confirm the issue is still present by reproducing it when applicable or by inspecting the code. Findings you could not verify, that are already fixed, or that you reject go under `## Skipped findings` with the reason
3. If the verdict is `VERDICT: FAIL`, the hook starts a fresh interactive Claude correction session. Read its changes and `summary-<round>.md`
4. Write a non-empty correction summary with these sections:
   - `## Fixes`
   - `## Skipped findings`
   - `## Quality gates`
   Record each fix, skipped finding, and verification command with its result (`PASS`, `FAIL`, or `NOT RUN`)
5. After the summary is complete, the hook advances to the next round and reruns the reviewer automatically
6. If the artifact or verdict is missing or malformed, rerun the generated reviewer script before addressing the findings
7. Stop only after the reviewer returns `VERDICT: PASS` and the correction summary is complete, or the hook reports `MAX_ROUNDS_REACHED`

The loop directory is kept after cleanup. Later rounds use the same directory with `review-<round>.md` and `summary-<round>.md`.

RULES:
- Complete the task to the best of your ability before stopping
- Do not stop prematurely or skip parts of the task
- Always write the required summary before stopping
- When blocked by the hook, read the review first; if the verdict is `FAIL`, address the findings and write the summary before stopping again. The hook reruns the reviewer after a complete summary; if the artifact or verdict is missing or malformed, rerun the generated script before addressing the findings.
