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
mkdir -p .claude reviews
if [ -f .claude/review-loop.local.md ]; then
  echo "Error: A review loop is already active. Use /cancel-review first."
  exit 1
fi

if ! command -v "$REVIEWER_CLI" >/dev/null 2>&1; then
  echo "Error: ${REVIEWER_NAME} CLI (${REVIEWER_CLI}) is not installed."
  echo "Install it: ${REVIEWER_INSTALL}"
  exit 1
fi

if [ "$REVIEWER" = "codex" ]; then
  CODEX_CONFIG="${HOME}/.codex/config.toml"
  if [ ! -f "$CODEX_CONFIG" ]; then
    mkdir -p "${HOME}/.codex"
    printf '[features]\nmulti_agent = true\n' > "$CODEX_CONFIG"
    echo "Created ~/.codex/config.toml with multi_agent enabled"
  elif ! grep -qE '^\s*multi_agent\s*=\s*true' "$CODEX_CONFIG"; then
    if grep -qE '^\[features\]' "$CODEX_CONFIG"; then
      if [ "$(uname)" = "Darwin" ]; then
        sed -i '' '/^\[features\]/a\'$'\n''multi_agent = true' "$CODEX_CONFIG"
      else
        sed -i '/^\[features\]/a multi_agent = true' "$CODEX_CONFIG"
      fi
    else
      printf '\n[features]\nmulti_agent = true\n' >> "$CODEX_CONFIG"
    fi
    echo "Enabled multi_agent in ~/.codex/config.toml"
  fi
fi

rm -f .claude/review-loop.lock
cat > .claude/review-loop.local.md << STATE_EOF
---
active: true
phase: task
reviewer: ${REVIEWER}
review_id: ${REVIEW_ID}
started_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
---

$ARGUMENTS
STATE_EOF
echo "Review Loop activated (ID: ${REVIEW_ID}, reviewer: ${REVIEWER})"
```

After setup completes successfully, proceed to implement the task described in the arguments. Work thoroughly and completely — write clean, well-structured, well-tested code.

When you believe the task is fully done, stop. The review loop stop hook will automatically:
1. Prepare a reviewer runner script and prompt file
2. Block Claude's exit with instructions to run the review

You will then run the generated reviewer script to execute the review (output streams to the user for visibility). After the reviewer finishes, read the review file and address the findings.

RULES:
- Complete the task to the best of your ability before stopping
- Do not stop prematurely or skip parts of the task
- When blocked by the hook, run the generated reviewer script and address the review
