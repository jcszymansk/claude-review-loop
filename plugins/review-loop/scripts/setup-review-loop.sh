#!/usr/bin/env bash
set -euo pipefail

# Review Loop — Setup Script
# Creates state file and prepares the review loop lifecycle.

ARGS=()
PR_URL="${REVIEW_LOOP_PR:-}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --pr)
      if [[ $# -lt 2 ]]; then
        echo "Error: --pr requires a pull request URL."
        exit 1
      fi
      PR_URL="$2"
      shift 2
      ;;
    --help|-h)
      cat << 'HELP'
Usage: /review-loop [--pr <url>] <task description>

Starts a review loop:
  1. Claude implements your task
  2. A configured reviewer performs an independent code review
  3. Claude addresses the feedback

Environment variables:
  REVIEW_LOOP_REVIEWER  Reviewer to run: codex, gemini, or cursor
  REVIEW_LOOP_MAX_ROUNDS  Maximum review rounds, from 1 to 10 (default: 3)
  REVIEW_LOOP_PR  Optional GitHub or Gitea pull request URL to review
  REVIEW_LOOP_CODEX_FLAGS  Override Codex flags (default: --dangerously-bypass-approvals-and-sandbox)
  REVIEW_LOOP_GEMINI_FLAGS  Override Gemini flags (default: --output-format text)
  REVIEW_LOOP_CURSOR_FLAGS  Override Cursor Agent flags (default: --output-format text)

Configuration files:
  .review-loop.toml  Project reviewer configuration
  ~/.config/review-loop/config.toml  User reviewer configuration

The reviewer is resolved in this order: REVIEW_LOOP_REVIEWER, project
configuration, user configuration, then codex. The round limit is resolved
from REVIEW_LOOP_MAX_ROUNDS, project configuration, user configuration, then
the default of 3.
  --pr <url> scopes the review to a GitHub or Gitea pull request

Configuration format:
  reviewer = "cursor"
  max_rounds = 5


Example:
  /review-loop Add user authentication with JWT tokens and proper test coverage
HELP
      exit 0
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

PROMPT="${ARGS[*]:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "$PR_URL" ] && ! "$SCRIPT_DIR/resolve-pr-url.sh" "$PR_URL" >/dev/null; then
  echo "Error: invalid pull request URL: $PR_URL"
  exit 1
fi
REVIEWER="$("$SCRIPT_DIR/resolve-reviewer.sh")"


if [ -z "$PROMPT" ]; then
  echo "Error: No task description provided."
  echo "Usage: /review-loop <task description>"
  exit 1
fi
MAX_ROUNDS="$("$SCRIPT_DIR/resolve-max-rounds.sh")"

case "$REVIEWER" in
  codex)
    REVIEWER_CLI="codex"
    REVIEWER_INSTALL="Install Codex CLI: npm install -g @openai/codex"
    ;;
  gemini)
    REVIEWER_CLI="gemini"
    REVIEWER_INSTALL="Install Gemini CLI: npm install -g @google/gemini-cli"
    ;;
  cursor)
    REVIEWER_CLI="cursor-agent"
    REVIEWER_INSTALL="Install Cursor Agent CLI: curl https://cursor.com/install -fsS | bash"
    ;;
esac
if ! command -v "$REVIEWER_CLI" &> /dev/null; then
  echo "Warning: '$REVIEWER_CLI' CLI not found. $REVIEWER_INSTALL"
fi
if [ "$REVIEWER" = "codex" ]; then
  "$SCRIPT_DIR/ensure-codex-config.sh"
fi



if ! command -v jq &> /dev/null; then
  echo "Error: 'jq' is required but not found."
  echo "  macOS:  brew install jq"
  echo "  Linux:  apt install jq  /  yum install jq"
  echo "  Docs:   https://jqlang.github.io/jq/download/"
  exit 1
fi

# Check for existing loop
STATE_FILE=".claude/review-loop.local.json"
if [ -f "$STATE_FILE" ]; then
  echo "Error: A review loop is already active. Use /cancel-review to abort it first."
  exit 1
fi
BASELINE_TREE="$("$SCRIPT_DIR/capture-worktree-tree.sh")"


# Generate unique ID: timestamp + random hex
# Prefer openssl, fallback to /dev/urandom
if command -v openssl &> /dev/null; then
  RAND_HEX=$(openssl rand -hex 3)
else
  RAND_HEX=$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')
fi
REVIEW_ID="$(date +%Y%m%d-%H%M%S)-${RAND_HEX}"
LOOP_DIR="reviews/${REVIEW_ID}"
mkdir -p reviews
if ! mkdir "$LOOP_DIR"; then
  echo "Error: Review loop directory already exists: $LOOP_DIR"
  exit 1
fi

printf '# Review Loop Task Context\n\n%s\n' "$PROMPT" > "$LOOP_DIR/summary-0.md"


# Clean up stale lock from previous runs
rm -f .claude/review-loop.lock .claude/review-loop-child.pid .claude/review-loop-child.pid.tmp.*

# Create state file
mkdir -p .claude
STATE_TEMP="${STATE_FILE}.tmp.$$"
jq -n \
  --arg reviewer "$REVIEWER" \
  --arg task "$PROMPT" \
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



echo ""
echo "Review Loop activated"
echo "  ID:      ${REVIEW_ID}"
echo "  Phase:   1/2 — Task implementation"
echo "  Summary: ${LOOP_DIR}/summary-0.md"
echo "  Review:  ${LOOP_DIR}/review-1.md"
echo ""
echo "  Lifecycle:"
echo "    1. You implement the task"
echo "    2. Stop hook prepares the ${REVIEWER} review"
echo "    3. You address the feedback"
echo ""
echo "  Use /cancel-review to abort."
echo ""
