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

PROJECT_CONFIG=".review-loop.toml"
USER_CONFIG="${XDG_CONFIG_HOME:-${HOME:-$PWD/.config}}/review-loop/config.toml"

read_config_reviewer() {
  local config_file="$1"
  local reviewer
  reviewer=$(sed -nE 's/^[[:space:]]*reviewer[[:space:]]*=[[:space:]]*"([^"]+)"[[:space:]]*(#.*)?$/\1/p' "$config_file" | head -n 1)
  if [ -z "$reviewer" ]; then
    echo "Error: $config_file must define reviewer = \"codex|gemini|cursor\"." >&2
    return 1
  fi
  printf '%s\n' "$reviewer"
}

resolve_reviewer() {
  if [ -n "${REVIEW_LOOP_REVIEWER:-}" ]; then
    printf '%s\n' "$REVIEW_LOOP_REVIEWER"
  elif [ -f "$PROJECT_CONFIG" ]; then
    read_config_reviewer "$PROJECT_CONFIG"
  elif [ -f "$USER_CONFIG" ]; then
    read_config_reviewer "$USER_CONFIG"
  else
    printf 'codex\n'
  fi
}

REVIEWER="$(resolve_reviewer)"
case "$REVIEWER" in
  codex|gemini|cursor) ;;
  *) echo "Error: unsupported reviewer '$REVIEWER' (use codex, gemini, or cursor)" >&2; exit 1 ;;
esac

REVIEW_ID="$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 3 2>/dev/null || head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
mkdir -p .claude reviews
if [ -f .claude/review-loop.local.md ]; then
  echo "Error: A review loop is already active. Use /cancel-review first."
  exit 1
fi

if [ "$REVIEWER" = "codex" ]; then
  command -v codex >/dev/null 2>&1 || {
    echo "Error: Codex CLI is not installed. Install it: npm install -g @openai/codex"
    exit 1
  }
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
