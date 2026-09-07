#!/usr/bin/env bash
# Review Loop — Stop Hook
#
#   Each round: task → reviewer → addressing → next round or terminal outcome
#   A failed review advances automatically once its correction summary is complete
#
# On any error, default to allowing exit (never trap the user in a broken loop).
#
# Reviewer selection:
#   REVIEW_LOOP_REVIEWER, .review-loop.toml, and
#   ${XDG_CONFIG_HOME:-$HOME/.config}/review-loop/config.toml (default: codex)
# REVIEW_LOOP_CODEX_FLAGS    Override Codex flags (default: --dangerously-bypass-approvals-and-sandbox)
# REVIEW_LOOP_CURSOR_FLAGS   Override Cursor Agent flags (default: --output-format text)
# REVIEW_LOOP_CLAUDE_FLAGS   Override Claude flags (default: --permission-mode acceptEdits)

LOG_FILE=".claude/review-loop.log"
log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}


cleanup_generated_files() {
  rm -f \
    .claude/review-loop-run-codex.sh \
    .claude/review-loop-run-cursor.sh \
    .claude/review-loop-run-claude.sh \
    .claude/review-loop-codex-prompt.txt \
    .claude/review-loop-cursor-prompt.txt \
    .claude/review-loop-claude-prompt.txt \
    .claude/review-loop-retries \
    .claude/review-loop-child.pid \
    .claude/review-loop-child.pid.tmp.*
}

trap 'log "ERROR: hook exited via ERR trap (line $LINENO)"; cleanup_generated_files; printf "{\"decision\":\"approve\"}\n"; exit 0' ERR

# Consume stdin (hook input JSON) — must read to avoid broken pipe
HOOK_INPUT=$(cat)
if [ "${REVIEW_LOOP_CORRECTION:-}" = "1" ] ||
  [ "${REVIEW_LOOP_REVIEWER_PROCESS:-}" = "1" ]; then
  log "Allowing nested Claude session to exit without re-entering the review loop"
  printf '{"decision":"approve"}\n'
  exit 0
fi


CHILD_PID_FILE=".claude/review-loop-child.pid"
STATE_FILE=".claude/review-loop.local.json"
cleanup_runtime_files() {
  # Keep reviews/${REVIEW_ID:-unknown}/ intact; it is the permanent loop history.
  rm -f "$STATE_FILE" .claude/review-loop.lock
  cleanup_generated_files
}
write_child_pid() {
  local pid="$1"
  local temp_file="${CHILD_PID_FILE}.tmp.$$"
  if printf '%s\n' "$pid" > "$temp_file"; then
    mv "$temp_file" "$CHILD_PID_FILE"
  else
    rm -f "$temp_file"
  fi
}
clear_child_pid() {
  local pid="$1"
  if [ -f "$CHILD_PID_FILE" ] && [ "$(cat "$CHILD_PID_FILE" 2>/dev/null || true)" = "$pid" ]; then
    rm -f "$CHILD_PID_FILE"
  fi
}
REVIEWER_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
PR_URL_RESOLVER="$REVIEWER_SCRIPTS_DIR/resolve-pr-url.sh"
BASELINE_SCRIPT="$REVIEWER_SCRIPTS_DIR/capture-worktree-tree.sh"
PROMPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../prompts" && pwd)"
STOP_HOOK_SCRIPT="${BASH_SOURCE[0]}"
case "$STOP_HOOK_SCRIPT" in
  /*) ;;
  *) STOP_HOOK_SCRIPT="$PWD/$STOP_HOOK_SCRIPT" ;;
esac

# No active loop → allow exit
if [ ! -f "$STATE_FILE" ]; then
  printf '{"decision":"approve"}\n'
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  log "ERROR: jq is required to read state"
  cleanup_runtime_files
  printf '{"decision":"approve"}\n'
  exit 0
fi

if ! jq -e '
  type == "object"
  and (.active | type == "boolean")
  and (.phase | type == "string")
  and ((has("reviewer") | not) or (.reviewer | type == "string"))
  and (.task | type == "string")
  and (.round | type == "number" and . >= 0)
  and (.max_rounds | type == "number" and . >= 1)
  and (.review_id | type == "string")
  and ((has("pr_url") | not) or (.pr_url | type == "string"))
  and ((has("baseline_tree") | not) or (.baseline_tree | type == "string"))
' "$STATE_FILE" >/dev/null 2>&1; then
  log "ERROR: malformed JSON state file"
  cleanup_runtime_files
  printf '{"decision":"approve"}\n'
  exit 0
fi

# Parse a field from the JSON state
parse_field() {
  jq -r --arg field "$1" '.[$field]' "$STATE_FILE"
}
# Parse a review verdict, treating missing or malformed verdicts as FAIL
parse_verdict() {
  local review_file="$1"
  local first_line

  first_line=$(head -n 1 "$review_file" 2>/dev/null || true)
  case "$first_line" in
    "VERDICT: PASS")
      printf 'PASS\n'
      return 0
      ;;
    "VERDICT: FAIL")
      printf 'FAIL\n'
      return 0
      ;;
    *)
      printf 'FAIL\n'
      return 1
      ;;
  esac
}
review_artifact_is_usable() {
  local review_file="$1"

  [ -f "$review_file" ] && [ -s "$review_file" ] && [ -r "$review_file" ]
}
summary_section_has_content() {
  local summary_file="$1"
  local section="$2"

  awk -v section="$section" '
    BEGIN {
      heading = "^##[[:space:]]+" tolower(section) "[[:space:]]*$"
    }
    {
      line = tolower($0)
      if (line ~ heading) {
        found = 1
        next
      }
      if (found && line ~ /^##[[:space:]]+/) {
        finished = 1
      }
      if (found && !finished && $0 !~ /^[[:space:]]*$/ &&
          (section != "quality gates" ||
           line ~ /(^|[^[:alnum:]])(pass|fail|not run)([^[:alnum:]]|$)/)) {
        content = 1
      }
    }
    END {
      exit !(found && content)
    }
  ' "$summary_file"
}
correction_summary_is_usable() {
  local summary_file="$1"

  [ -f "$summary_file" ] && [ -s "$summary_file" ] && [ -r "$summary_file" ] &&
    summary_section_has_content "$summary_file" "fixes" &&
    summary_section_has_content "$summary_file" "skipped findings" &&
    summary_section_has_content "$summary_file" "quality gates"
}









if ! ACTIVE=$(parse_field "active") ||
  ! PHASE=$(parse_field "phase") ||
  ! REVIEWER=$(parse_field "reviewer") ||
  ! TASK=$(parse_field "task") ||
  ! ROUND=$(parse_field "round") ||
  ! MAX_ROUNDS=$(parse_field "max_rounds") ||
  ! REVIEW_ID=$(parse_field "review_id") ||
  ! PR_URL=$(parse_field "pr_url") ||
  ! BASELINE_TREE=$(parse_field "baseline_tree"); then
  log "ERROR: failed to read JSON state file"
  cleanup_runtime_files
  printf '{"decision":"approve"}\n'
  exit 0
fi
if [ "$PR_URL" = "null" ]; then
  PR_URL=""
fi
if [ "$BASELINE_TREE" = "null" ]; then
  BASELINE_TREE=""
fi
TASK_DIFF_FILE=""
REVIEW_SCOPE="local branch diff"

if [ -z "$REVIEWER" ] || [ "$REVIEWER" = "null" ]; then
  # State files without reviewer selection always use Codex.
  REVIEWER=codex
fi

# Not active → clean up and exit
if [ "$ACTIVE" != "true" ]; then
  cleanup_runtime_files
  printf '{"decision":"approve"}\n'
  exit 0
fi

# Validate review_id format to prevent path traversal
if ! echo "$REVIEW_ID" | grep -qE '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$'; then
  log "ERROR: invalid review_id format: $REVIEW_ID"
  cleanup_runtime_files
  printf '{"decision":"approve"}\n'
  exit 0

fi
REVIEW_DIR="reviews/${REVIEW_ID}"
REVIEW_FILE="${REVIEW_DIR}/review-${ROUND}.md"
SUMMARY_FILE="${REVIEW_DIR}/summary-${ROUND}.md"

case "$REVIEWER" in
  codex)
    REVIEWER_CLI="codex"
    REVIEWER_NAME="Codex"
    REVIEWER_INSTALL="npm install -g @openai/codex"
    PROMPT_FILE=".claude/review-loop-codex-prompt.txt"
    RUNNER_SCRIPT=".claude/review-loop-run-codex.sh"
    ;;
  cursor)
    REVIEWER_CLI="cursor-agent"
    REVIEWER_NAME="Cursor Agent"
    REVIEWER_INSTALL="curl https://cursor.com/install -fsS | bash"
    PROMPT_FILE=".claude/review-loop-cursor-prompt.txt"
    RUNNER_SCRIPT=".claude/review-loop-run-cursor.sh"
    ;;
  claude)
    REVIEWER_CLI="claude"
    REVIEWER_NAME="Claude Code"
    REVIEWER_INSTALL="https://code.claude.com/docs/en/setup"
    PROMPT_FILE=".claude/review-loop-claude-prompt.txt"
    RUNNER_SCRIPT=".claude/review-loop-run-claude.sh"
    ;;
  *)
    log "ERROR: unsupported reviewer: $REVIEWER"
    cleanup_runtime_files
    printf '{"decision":"approve"}\n'
    exit 0
    ;;
esac

REVIEWER_DISPATCHER="$REVIEWER_SCRIPTS_DIR/run-reviewer.sh"

# ── Project type detection ────────────────────────────────────────────────
detect_nextjs() {
  [ -f "next.config.js" ] || [ -f "next.config.mjs" ] || [ -f "next.config.ts" ] || \
    ([ -f "package.json" ] && grep -q '"next"' package.json 2>/dev/null)
}

detect_browser_ui() {
  # Has HTML/JSX/TSX files in app/ or pages/ or src/ directories, or has a public/ dir
  [ -d "app" ] || [ -d "pages" ] || [ -d "src/app" ] || [ -d "src/pages" ] || \
    [ -d "public" ] || [ -f "index.html" ]
}
SPEC_FILES=""
detect_spec_or_plan() {
  local candidate

  for candidate in \
    SPEC.md spec.md SPECIFICATION.md specification.md \
    PLAN.md plan.md \
    docs/SPEC.md docs/spec.md docs/SPECIFICATION.md docs/specification.md \
    docs/PLAN.md docs/plan.md; do
    if [ -f "$candidate" ] && [ -r "$candidate" ]; then
      if [ -n "$SPEC_FILES" ]; then
        SPEC_FILES="${SPEC_FILES}"$'\n'
      fi
      SPEC_FILES="${SPEC_FILES}${candidate}"
    fi
  done

  [ -n "$SPEC_FILES" ]
}


# ── Branch diff ─────────────────────────────────────────────────────────────
compute_task_diff() {
  local output_file="$1"
  local current_tree

  [ -n "$BASELINE_TREE" ] || return 1
  git cat-file -e "${BASELINE_TREE}^{tree}" >/dev/null 2>&1 || return 1
  current_tree=$("$BASELINE_SCRIPT") || return 1
  [ -n "$current_tree" ] || return 1

  {
    printf '# Task diff\n\n'
    printf 'Base: %s (captured when the review loop started)\n\n' "$BASELINE_TREE"
    git diff --no-ext-diff "$BASELINE_TREE" "$current_tree" -- \
      . \
      ':(exclude)reviews/**' \
      ':(exclude).claude/review-loop*'
  } > "$output_file"
}

compute_branch_diff() {
  local output_file="$1"
  local current_branch
  local base_ref
  local merge_base
  local candidate
  local candidate_ref
  local upstream_branch
  local untracked_file

  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    printf '# Branch diff\n\nNot a Git repository.\n' > "$output_file"
    return $?
  fi
  if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
    # shellcheck disable=SC2094 # output_file is written by this block, never read
    {
      printf '# Branch diff\n\nRepository has no commits yet.\n\n'
      git diff --cached 2>/dev/null || true
      while IFS= read -r -d '' untracked_file; do
        [ "$untracked_file" = "$output_file" ] && continue
        printf '\n--- Untracked file: %s ---\n\n' "$untracked_file"
        git diff --no-index -- /dev/null "$untracked_file" 2>/dev/null || true
      done < <(git ls-files --others --exclude-standard -z 2>/dev/null || true)
    } > "$output_file"
    return $?
  fi

  current_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'detached HEAD')
  base_ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$base_ref" ] &&
    { [ "$base_ref" = "$current_branch" ] ||
      ! git rev-parse --verify "$base_ref^{commit}" >/dev/null 2>&1; }; then
    base_ref=""
  fi

  if [ -z "$base_ref" ]; then
    base_ref=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
    if [ -n "$base_ref" ] &&
      { [ "$base_ref" = "$current_branch" ] ||
        ! git rev-parse --verify "$base_ref^{commit}" >/dev/null 2>&1; }; then
      base_ref=""
    fi
    if [ -n "$base_ref" ]; then
      upstream_branch="${base_ref#*/}"
      if [ "$upstream_branch" = "$current_branch" ] &&
        [ "$current_branch" != "main" ] &&
        [ "$current_branch" != "master" ]; then
        base_ref=""
      fi
    fi
  fi

  if [ -z "$base_ref" ]; then
    for candidate in main master; do
      for candidate_ref in "$candidate" "origin/$candidate"; do
        if [ "$candidate_ref" != "$current_branch" ] &&
          git rev-parse --verify "$candidate_ref^{commit}" >/dev/null 2>&1; then
          base_ref="$candidate_ref"
          break 2
        fi
      done
    done
  fi

  # shellcheck disable=SC2094 # output_file is written by this block, never read
  {
    printf '# Branch diff\n\n'
    printf 'Branch: %s\n' "$current_branch"
    if [ -n "$base_ref" ] &&
      merge_base=$(git merge-base HEAD "$base_ref" 2>/dev/null); then
      printf 'Base: %s (merge-base with %s)\n\n' "$merge_base" "$base_ref"
      git diff "$merge_base" 2>/dev/null || true
    elif [ -n "$base_ref" ]; then
      printf 'Base: %s (merge-base unavailable)\n\n' "$base_ref"
      git diff "$base_ref" 2>/dev/null || true
    else
      printf 'Base: unavailable; showing worktree changes and recent commits.\n\n'
      git diff HEAD 2>/dev/null || true
      printf '\n--- Recent commits ---\n\n'
      git log --oneline -10 2>/dev/null || true
    fi

    while IFS= read -r -d '' untracked_file; do
      [ "$untracked_file" = "$output_file" ] && continue
      printf '\n--- Untracked file: %s ---\n\n' "$untracked_file"
      git diff --no-index -- /dev/null "$untracked_file" 2>/dev/null || true
    done < <(git ls-files --others --exclude-standard -z 2>/dev/null || true)
  } > "$output_file"
}
compute_pr_diff() {
  local output_file="$1"
  local pr_details
  local provider
  local scheme
  local host
  local owner
  local repository
  local number
  local diff_url
  local auth_header=""
  local temp_file="${output_file}.tmp.$$"

  if ! pr_details=$("$PR_URL_RESOLVER" "$PR_URL" 2>>"$LOG_FILE"); then
    return 1
  fi
  IFS=$'\t' read -r provider scheme host owner repository number <<< "$pr_details"

  case "$provider" in
    github)
      diff_url="${scheme}://${host}/${owner}/${repository}/pull/${number}.diff"
      if [ -n "${GITHUB_TOKEN:-}" ]; then
        auth_header="Authorization: Bearer ${GITHUB_TOKEN}"
      fi
      ;;
    gitea)
      diff_url="${scheme}://${host}/api/v1/repos/${owner}/${repository}/pulls/${number}.diff"
      if [ -n "${GITEA_TOKEN:-}" ]; then
        auth_header="Authorization: token ${GITEA_TOKEN}"
      fi
      ;;
    *)
      return 1
      ;;
  esac

  if ! command -v curl >/dev/null 2>&1; then
    log "ERROR: curl is required for pull request scope (url=$PR_URL)"
    return 1
  fi

  if [ -n "$auth_header" ]; then
    if ! curl --fail --silent --show-error --location --connect-timeout 10 \
      --max-time 60 -H "$auth_header" "$diff_url" > "$temp_file" 2>>"$LOG_FILE"; then
      rm -f "$temp_file"
      return 1
    fi
  elif ! curl --fail --silent --show-error --location --connect-timeout 10 \
    --max-time 60 "$diff_url" > "$temp_file" 2>>"$LOG_FILE"; then
    rm -f "$temp_file"
    return 1
  fi

  if ! {
    printf '# Branch diff\n\n'
    printf 'Pull request: %s\n' "$PR_URL"
    printf 'Source: %s\n\n' "$diff_url"
    cat "$temp_file"
  } > "$output_file"; then
    rm -f "$temp_file"
    return 1
  fi
  rm -f "$temp_file"
}

compute_review_diff() {
  local output_file="$1"
  local fallback_file="${output_file}.fallback.$$"
  if [ -z "$PR_URL" ]; then
    REVIEW_SCOPE="local branch diff"
    compute_branch_diff "$output_file"
    return $?
  fi

  if compute_pr_diff "$output_file"; then
    REVIEW_SCOPE="pull request diff"
    log "Fetched pull request diff (review_id=$REVIEW_ID, url=$PR_URL)"
    return 0
  fi
  REVIEW_SCOPE="local branch diff (pull request fetch failed; see warning in artifact)"
  log "WARN: failed to fetch pull request diff; falling back to branch diff (review_id=$REVIEW_ID, url=$PR_URL)"
  if ! compute_branch_diff "$fallback_file"; then
    rm -f "$fallback_file"
    return 1
  fi
  if ! {
    cat "$fallback_file"
    printf '\n--- Pull request scope fallback ---\n'
    printf 'Pull request: %s\n' "$PR_URL"
    printf 'WARNING: Failed to fetch the pull request diff. Reviewing the current branch diff instead.\n'
  } > "$output_file"; then
    rm -f "$fallback_file"
    return 1
  fi
  rm -f "$fallback_file"
}


# ── Prompt templates ───────────────────────────────────────────────────────
replace_prompt_placeholder() {
  local placeholder="$1"
  local replacement="$2"

  template="${template//"$placeholder"/"$replacement"}"
}
PRIOR_ROUND_HISTORY=""
build_prior_round_history() {
  local history=""
  local history_round
  local history_file
  local history_name
  local history_content

  if [ -r "$REVIEW_DIR/summary-0.md" ] &&
    history_content=$(cat "$REVIEW_DIR/summary-0.md"); then
    history="### Initial implementation summary (summary-0.md)

${history_content}"
  fi

  for ((history_round = 1; history_round < ROUND; history_round++)); do
    for history_file in \
      "$REVIEW_DIR/review-${history_round}.md" \
      "$REVIEW_DIR/summary-${history_round}.md"; do
      if [ -r "$history_file" ] &&
        history_content=$(cat "$history_file"); then
        history_name="${history_file##*/}"
        if [ -n "$history" ]; then
          history="${history}

"
        fi
        history="${history}### Round ${history_round} ${history_name}

${history_content}"
      fi
    done
  done

  if [ -n "$history" ]; then
    printf '%s\n' "$history"
  else
    printf 'No previous review history is available.\n'
  fi
}

render_prompt_template() {
  local template_file="$1"
  local template

  if [ ! -r "$template_file" ]; then
    log "ERROR: prompt template missing or unreadable: $template_file"
    return 1
  fi
  if ! template=$(cat "$template_file"); then
    log "ERROR: failed to read prompt template: $template_file"
    return 1
  fi

  replace_prompt_placeholder "__REVIEWER__" "$REVIEWER"
  replace_prompt_placeholder "__ROUND__" "$ROUND"
  replace_prompt_placeholder "__REVIEW_STATUS__" "$REVIEW_STATUS"
  replace_prompt_placeholder "__CORRECTION_STATUS__" "$CORRECTION_STATUS"
  replace_prompt_placeholder "__RUNNER_SCRIPT__" "$RUNNER_SCRIPT"
  replace_prompt_placeholder "__REVIEW_FILE__" "$REVIEW_FILE"
  replace_prompt_placeholder "__REVIEW_ID__" "$REVIEW_ID"
  replace_prompt_placeholder "__REVIEW_DIR__" "$REVIEW_DIR"
  replace_prompt_placeholder "__SUMMARY_FILE__" "$SUMMARY_FILE"
  replace_prompt_placeholder "__TASK__" "$TASK"
  replace_prompt_placeholder "__TASK_DIFF_FILE__" "$TASK_DIFF_FILE"
  replace_prompt_placeholder "__PR_URL__" "$PR_URL"
  replace_prompt_placeholder "__REVIEW_SCOPE__" "$REVIEW_SCOPE"
  replace_prompt_placeholder "__PRIOR_ROUND_HISTORY__" "$PRIOR_ROUND_HISTORY"
  replace_prompt_placeholder "__SPEC_FILES__" "$SPEC_FILES"
  printf '%s\n' "$template"
}

build_review_prompt() {
  local IS_NEXTJS=false
  local HAS_UI=false
  local HAS_SPEC=false
  detect_nextjs && IS_NEXTJS=true
  detect_browser_ui && HAS_UI=true
  detect_spec_or_plan && HAS_SPEC=true

  log "Project detection: nextjs=$IS_NEXTJS, browser_ui=$HAS_UI, spec_or_plan=$HAS_SPEC"

  if ! PRIOR_ROUND_HISTORY=$(build_prior_round_history); then
    return 1
  fi
  render_prompt_template "$PROMPTS_DIR/review-base.md" || return 1
  if [ "$HAS_SPEC" = "true" ]; then
    render_prompt_template "$PROMPTS_DIR/review-spec.md" || return 1
  fi
  if [ "$IS_NEXTJS" = "true" ]; then
    render_prompt_template "$PROMPTS_DIR/review-nextjs.md" || return 1
  fi
  if [ "$HAS_UI" = "true" ]; then
    render_prompt_template "$PROMPTS_DIR/review-ux.md" || return 1
  fi
  render_prompt_template "$PROMPTS_DIR/review-consolidation.md" || return 1
}


# ── Rewrite JSON state to update phase (atomic) ───────────────────────────
transition_phase() {
  local new_phase="$1"
  local TEMP_FILE="${STATE_FILE}.tmp.$$"

  if ! jq --arg phase "$new_phase" '.phase = $phase' "$STATE_FILE" > "$TEMP_FILE"; then
    rm -f "$TEMP_FILE"
    return 1
  fi
  if ! mv "$TEMP_FILE" "$STATE_FILE"; then
    rm -f "$TEMP_FILE"
    return 1
  fi

  # Verify the transition succeeded
  local CHECK
  CHECK=$(parse_field "phase")
  if [ "$CHECK" != "$new_phase" ]; then
    log "ERROR: phase transition failed (expected=$new_phase, got=$CHECK)"
    return 1
  fi
  log "Phase transitioned to: $new_phase"
  return 0
}
transition_to_next_round() {
  local next_round="$1"
  local TEMP_FILE="${STATE_FILE}.tmp.$$"

  if ! jq --arg phase "task" --argjson round "$next_round" \
    '.phase = $phase | .round = $round' "$STATE_FILE" > "$TEMP_FILE"; then
    rm -f "$TEMP_FILE"
    return 1
  fi
  if ! mv "$TEMP_FILE" "$STATE_FILE"; then
    rm -f "$TEMP_FILE"
    return 1
  fi

  local CHECK_PHASE
  local CHECK_ROUND
  CHECK_PHASE=$(parse_field "phase")
  CHECK_ROUND=$(parse_field "round")
  if [ "$CHECK_PHASE" != "task" ] || [ "$CHECK_ROUND" != "$next_round" ]; then
    log "ERROR: round transition failed (expected=task/$next_round, got=$CHECK_PHASE/$CHECK_ROUND)"
    return 1
  fi
  rm -f .claude/review-loop-retries
  log "Advanced to review round: $next_round"
  return 0
}
# ── Start a fresh interactive correction session ───────────────────────────
start_correction_session() {
  local correction_prompt
  local correction_status
  local correction_pid
  local tty_name
  local tty_device

  if ! correction_prompt=$(render_prompt_template "$PROMPTS_DIR/correction-session.md"); then
    log "ERROR: failed to render correction prompt"
    return 1
  fi

  tty_name=$(ps -o tty= -p "$$" 2>/dev/null)
  tty_name="${tty_name//[[:space:]]/}"
  tty_device=""
  case "$tty_name" in
    console|pts/*|tty[sy]*)
      tty_device="/dev/$tty_name"
      ;;
  esac

  log "Starting fresh interactive Claude correction session (review_id=$REVIEW_ID, round=$ROUND)"
  if [ -n "$tty_device" ] && [ -r "$tty_device" ] && [ -w "$tty_device" ]; then
    # shellcheck disable=SC2094 # same tty intentionally provides stdin and stdout
    env -u CLAUDECODE REVIEW_LOOP_CORRECTION=1 claude --dangerously-skip-permissions "$correction_prompt" <"$tty_device" >"$tty_device" 2>&1 &
    correction_pid=$!
    write_child_pid "$correction_pid"
    if wait "$correction_pid"; then
      correction_status=0
    else
      correction_status=$?
    fi
    clear_child_pid "$correction_pid"
  else


    log "ERROR: fresh interactive Claude correction session unavailable: Stop hook has no terminal"
    correction_status=1
  fi
  if [ "$correction_status" -eq 0 ]; then
    log "Fresh interactive Claude correction session finished (review_id=$REVIEW_ID, round=$ROUND)"
  else
    log "ERROR: fresh interactive Claude correction session failed (review_id=$REVIEW_ID, round=$ROUND, exit=$correction_status)"
  fi
  return "$correction_status"
}

case "$PHASE" in
  task)
    # ── Phase 1 → 2: Run the configured reviewer ──────────────────────────
    # The hook writes the prompt and runner, then executes the reviewer before
    # blocking so Claude can address its findings.
    if ! mkdir -p "$REVIEW_DIR"; then
      log "ERROR: failed to create review directory: $REVIEW_DIR"
      cleanup_runtime_files
      printf '{"decision":"approve"}\n'
      exit 0
    fi
    BRANCH_DIFF_FILE="${REVIEW_DIR}/branch-diff.md"
    TASK_DIFF_FILE="${REVIEW_DIR}/task-diff.md"
    rm -f "$TASK_DIFF_FILE"
    if [ -n "$BASELINE_TREE" ] && ! compute_task_diff "$TASK_DIFF_FILE"; then
      log "WARN: failed to write task diff; reviewer will use the active scope artifact"
      rm -f "$TASK_DIFF_FILE"
    fi
    if ! compute_review_diff "$BRANCH_DIFF_FILE"; then
      log "ERROR: failed to write branch diff: $BRANCH_DIFF_FILE"
      cleanup_runtime_files
      printf '{"decision":"approve"}\n'
      exit 0
    fi



    if ! command -v "$REVIEWER_CLI" &> /dev/null; then
      log "ERROR: $REVIEWER_CLI not found on PATH"
      cleanup_runtime_files
      REASON="ERROR: ${REVIEWER_NAME} CLI (${REVIEWER_CLI}) is not installed. The review loop requires ${REVIEWER_NAME} for independent code review.

Install it: ${REVIEWER_INSTALL}

Then run /review-loop again."
      jq -n --arg r "$REASON" '{decision:"block", reason:$r}' 2>/dev/null \
        || printf '{"decision":"block","reason":"%s CLI (%s) is not installed. Install it: %s"}\n' \
          "$REVIEWER_NAME" "$REVIEWER_CLI" "$REVIEWER_INSTALL"
      exit 0
    fi

    if [ "$REVIEWER" = "codex" ]; then
      # Preserve Codex's existing multi-agent setup.
      CODEX_CONFIG="${HOME}/.codex/config.toml"
      if [ ! -f "$CODEX_CONFIG" ] || ! grep -qE '^\s*multi_agent\s*=\s*true' "$CODEX_CONFIG"; then
        log "ERROR: multi_agent not enabled in $CODEX_CONFIG"
        cleanup_runtime_files
        REASON="ERROR: Codex multi-agent is not enabled in ~/.codex/config.toml. This should have been configured by /review-loop but may have been changed.

Add to ~/.codex/config.toml:
  [features]
  multi_agent = true

Then run /review-loop again."
        jq -n --arg r "$REASON" '{decision:"block", reason:$r}' 2>/dev/null \
          || printf '{"decision":"block","reason":"Codex multi-agent is not enabled in ~/.codex/config.toml"}\n'
        exit 0
      fi
    fi


    if ! REVIEW_PROMPT=$(build_review_prompt); then
      log "ERROR: failed to render review prompt"
      cleanup_runtime_files
      printf '{"decision":"approve"}\n'
      exit 0
    fi
    printf '%s' "$REVIEW_PROMPT" > "$PROMPT_FILE"

    cat > "$RUNNER_SCRIPT" << RUNNER_EOF
#!/usr/bin/env bash
LOG_FILE=".claude/review-loop.log"
log() { echo "[\$(date -u +"%Y-%m-%dT%H:%M:%SZ")] \$*" >> "\$LOG_FILE"; }

REVIEWER='${REVIEWER}'
PROMPT_FILE='${PROMPT_FILE}'
REVIEW_FILE='${REVIEW_FILE}'
DISPATCHER_SCRIPT='${REVIEWER_DISPATCHER}'
PID_FILE=".claude/review-loop-child.pid"
TRACKED_PID="\$\$"
write_pid() {
  local pid="\$1"
  local temp_file="\$PID_FILE.tmp.\$\$"
  if printf '%s\n' "\$pid" > "\$temp_file"; then
    mv "\$temp_file" "\$PID_FILE"
  else
    rm -f "\$temp_file"
  fi
}
clear_pid() {
  if [ -f "\$PID_FILE" ] && [ "\$(cat "\$PID_FILE" 2>/dev/null || true)" = "\$TRACKED_PID" ]; then
    rm -f "\$PID_FILE"
  fi
}
trap clear_pid EXIT
write_pid "\$TRACKED_PID"
if [ ! -f "\$PROMPT_FILE" ]; then
  echo "ERROR: prompt file missing: \$PROMPT_FILE" >&2
  exit 1
fi
if [ ! -x "\$DISPATCHER_SCRIPT" ]; then
  echo "ERROR: reviewer dispatcher missing: \$DISPATCHER_SCRIPT" >&2
  exit 1
fi

log "Starting \$REVIEWER review"
START_TIME=\$(date +%s)

"\$DISPATCHER_SCRIPT" "\$REVIEWER" "\$PROMPT_FILE" "\$REVIEW_FILE" &
REVIEWER_PID=\$!
TRACKED_PID="\$REVIEWER_PID"
write_pid "\$TRACKED_PID"
if wait "\$REVIEWER_PID"; then
  REVIEWER_EXIT=0
else
  REVIEWER_EXIT=\$?
fi

ELAPSED=\$(( \$(date +%s) - START_TIME ))
log "\$REVIEWER finished (exit=\$REVIEWER_EXIT, elapsed=\${ELAPSED}s)"
exit \$REVIEWER_EXIT
RUNNER_EOF
    chmod +x "$RUNNER_SCRIPT"
    # Keep reviewer output out of stdout; the hook must emit one JSON decision.
    run_review() {
      "$RUNNER_SCRIPT" </dev/null >>"$LOG_FILE" 2>&1 &
      local runner_pid=$!
      local runner_status
      write_child_pid "$runner_pid"
      if wait "$runner_pid"; then
        runner_status=0
      else
        runner_status=$?
      fi
      clear_child_pid "$runner_pid"
      return "$runner_status"
    }


    REVIEW_START_TIME=$(date +%s)
    if run_review; then
      REVIEWER_EXIT=0
    else
      REVIEWER_EXIT=$?
    fi
    REVIEW_ELAPSED=$(( $(date +%s) - REVIEW_START_TIME ))
    log "${REVIEWER} review finished (exit=$REVIEWER_EXIT, elapsed=${REVIEW_ELAPSED}s, review_id=$REVIEW_ID, round=$ROUND)"
    if [ "$REVIEWER_EXIT" -ne 0 ]; then
      log "ERROR: ${REVIEWER} review failed for round $ROUND"
    fi

    # Transition to addressing phase — fail-open if this breaks, otherwise
    # a failed transition leaves phase=task and the next stop re-runs everything.
    if ! transition_phase "addressing"; then
      log "ERROR: phase transition failed, cleaning up"
      cleanup_runtime_files
      printf '{"decision":"approve"}\n'
      exit 0
    fi

    CORRECTION_STATUS=""
    log "Prepared ${REVIEWER} review for Claude to address (review_id=$REVIEW_ID)"
    if review_artifact_is_usable "$REVIEW_FILE"; then
      log "Review artifact ready (review_id=$REVIEW_ID, round=$ROUND, file=$REVIEW_FILE)"
      if [ "$REVIEWER_EXIT" -eq 0 ]; then
        REVIEW_STATUS="completed"
      else
        REVIEW_STATUS="exited with status ${REVIEWER_EXIT}; rerun it if the review artifact is malformed"
      fi

      if VERDICT=$(parse_verdict "$REVIEW_FILE") && [ "$VERDICT" = "FAIL" ]; then
        CORRECTION_STATUS="not started because the Claude CLI is unavailable"
        if command -v claude >/dev/null 2>&1; then
          if start_correction_session; then
            CORRECTION_STATUS="completed"
          else
            CORRECTION_STATUS="failed"
          fi
        else
          log "ERROR: claude not found on PATH; keeping FAIL in the current session"
        fi
      fi
    else
      log "ERROR: ${REVIEWER} did not produce a usable review artifact (review_id=$REVIEW_ID, round=$ROUND, file=$REVIEW_FILE)"
      REVIEW_STATUS="did not produce a usable artifact; rerun it with the generated script"
    fi

    if [ -n "$CORRECTION_STATUS" ]; then
      if ! REASON=$(render_prompt_template "$PROMPTS_DIR/addressing-correction.md"); then
        log "ERROR: failed to render correction handoff prompt"
        cleanup_runtime_files
        printf '{"decision":"approve"}\n'
        exit 0
      fi
    else
      if ! REASON=$(render_prompt_template "$PROMPTS_DIR/addressing-review.md"); then
        log "ERROR: failed to render review handoff prompt"
        cleanup_runtime_files
        printf '{"decision":"approve"}\n'
        exit 0
      fi
    fi
    SYS_MSG="Review Loop [${REVIEW_ID}] — Phase 2/2: Address ${REVIEWER} review feedback or continue to the next round"

    jq -n --arg r "$REASON" --arg s "$SYS_MSG" \
      '{decision:"block", reason:$r, systemMessage:$s}' 2>/dev/null \
      || printf '{"decision":"block","reason":"Phase 1 complete. Read the review and address the findings.","systemMessage":"%s"}\n' "$SYS_MSG"
    ;;

  addressing)
    # ── Phase 2: verify review verdict before allowing exit ───────────────
    if [ -f "$REVIEW_FILE" ] && ! correction_summary_is_usable "$SUMMARY_FILE"; then
      log "Correction summary missing or incomplete (review_id=$REVIEW_ID, round=$ROUND, file=$SUMMARY_FILE)"
      if ! REASON=$(render_prompt_template "$PROMPTS_DIR/addressing-summary.md"); then
        log "ERROR: failed to render correction summary prompt"
        cleanup_runtime_files
        printf '{"decision":"approve"}\n'
        exit 0
      fi
      SYS_MSG="Review Loop [${REVIEW_ID}] — Correction summary required"
      jq -n --arg r "$REASON" --arg s "$SYS_MSG" \
        '{decision:"block", reason:$r, systemMessage:$s}' 2>/dev/null \
        || printf '{"decision":"block","reason":"Write the complete correction summary before stopping.","systemMessage":"%s"}\n' "$SYS_MSG"
    elif [ -f "$REVIEW_FILE" ]; then
      if VERDICT=$(parse_verdict "$REVIEW_FILE"); then
        if [ "$VERDICT" = "PASS" ]; then
          log "Review loop complete (review_id=$REVIEW_ID, reviewer=$REVIEWER, verdict=$VERDICT)"
          cleanup_runtime_files
          printf '{"decision":"approve"}\n'
        else
          log "Review verdict: FAIL (review_id=$REVIEW_ID, round=$ROUND)"
          if [ "$ROUND" -ge "$MAX_ROUNDS" ]; then
            log "Review loop reached maximum rounds (review_id=$REVIEW_ID, round=$ROUND, max_rounds=$MAX_ROUNDS)"
            cleanup_runtime_files
            REASON="MAX_ROUNDS_REACHED: the review still returned FAIL after ${MAX_ROUNDS} round(s). The changes were not accepted."
            SYS_MSG="Review Loop [${REVIEW_ID}] — Maximum rounds reached"
            jq -n --arg r "$REASON" --arg s "$SYS_MSG" \
              '{decision:"block", reason:$r, systemMessage:$s}' 2>/dev/null \
              || printf '{"decision":"block","reason":"MAX_ROUNDS_REACHED: the review did not pass. The changes were not accepted.","systemMessage":"Review Loop maximum rounds reached"}\n'
          else
            NEXT_ROUND=$((ROUND + 1))
            if ! transition_to_next_round "$NEXT_ROUND"; then
              log "ERROR: failed to advance review loop to round $NEXT_ROUND"
              cleanup_runtime_files
              printf '{"decision":"approve"}\n'
              exit 0
            fi
            log "Review round $ROUND failed; re-running reviewer for round $NEXT_ROUND"
            exec "$STOP_HOOK_SCRIPT" <<< "$HOOK_INPUT"
          fi
        fi
      else
        log "Review verdict: FAIL (missing or malformed, review_id=$REVIEW_ID)"
        if ! REASON=$(render_prompt_template "$PROMPTS_DIR/addressing-verdict.md"); then
          log "ERROR: failed to render verdict prompt"
          cleanup_runtime_files
          printf '{"decision":"approve"}\n'
          exit 0
        fi
        SYS_MSG="Review Loop [${REVIEW_ID}] — Verdict: FAIL"
        jq -n --arg r "$REASON" --arg s "$SYS_MSG" \
          '{decision:"block", reason:$r, systemMessage:$s}' 2>/dev/null \
          || printf '{"decision":"block","reason":"The review verdict is FAIL because it is absent or malformed.","systemMessage":"Review Loop verdict: FAIL"}\n'
      fi
    elif [ -f "$RUNNER_SCRIPT" ]; then
      # Runner script exists but review doesn't — check retry limit
      RETRY_FILE=".claude/review-loop-retries"
      RETRY_COUNT=0
      if [ -f "$RETRY_FILE" ]; then
        RETRY_COUNT=$(cat "$RETRY_FILE" 2>/dev/null || echo 0)
      fi
      RETRY_COUNT=$(( RETRY_COUNT + 1 ))

      if [ "$RETRY_COUNT" -ge 2 ]; then
        # Already told Claude to run the script once — reviewer failed, don't retry
        log "ERROR: $REVIEWER failed to produce review, failing open (review_id=$REVIEW_ID)"
        cleanup_runtime_files
        printf '{"decision":"approve"}\n'
      else
        echo "$RETRY_COUNT" > "$RETRY_FILE"
        log "Review file not found ($REVIEW_FILE), prompting Claude to run $REVIEWER"
        if ! REASON=$(render_prompt_template "$PROMPTS_DIR/addressing-missing-review.md"); then
          log "ERROR: failed to render missing review prompt"
          cleanup_runtime_files
          printf '{"decision":"approve"}\n'
          exit 0
        fi
        SYS_MSG="Review Loop [${REVIEW_ID}] — ${REVIEWER} review not yet complete"
        jq -n --arg r "$REASON" --arg s "$SYS_MSG" \
          '{decision:"block", reason:$r, systemMessage:$s}' 2>/dev/null \
          || printf '{"decision":"block","reason":"%s review not yet complete. Run: bash %s","systemMessage":"%s"}\n' "$REVIEWER" "$RUNNER_SCRIPT" "$SYS_MSG"
      fi
    else
      # Neither review nor runner script — orphaned state, fail-open
      log "ERROR: review file and runner script both missing, cleaning up (review_id=$REVIEW_ID)"
      cleanup_runtime_files
      printf '{"decision":"approve"}\n'
    fi
    ;;

  *)
    # Unknown phase — clean up and allow exit
    log "WARN: unknown phase '$PHASE', cleaning up"
    cleanup_runtime_files
    printf '{"decision":"approve"}\n'
    ;;
esac
