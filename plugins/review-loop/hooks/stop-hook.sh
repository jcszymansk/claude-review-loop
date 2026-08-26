#!/usr/bin/env bash
# Review Loop — Stop Hook
#
#   Phase 1 (task):       Claude finishes work → hook runs the configured reviewer → blocks exit
#   Phase 2 (addressing): Claude addresses feedback → hook verifies review exists → allows exit
#
# On any error, default to allowing exit (never trap the user in a broken loop).
#
# Reviewer selection:
#   REVIEW_LOOP_REVIEWER, .review-loop.toml, and
#   ${XDG_CONFIG_HOME:-$HOME/.config}/review-loop/config.toml (default: codex)
# REVIEW_LOOP_CODEX_FLAGS    Override Codex flags (default: --dangerously-bypass-approvals-and-sandbox)
# REVIEW_LOOP_GEMINI_FLAGS   Override Gemini flags (default: --output-format text)
# REVIEW_LOOP_CURSOR_FLAGS   Override Cursor Agent flags (default: --output-format text)

LOG_FILE=".claude/review-loop.log"
log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}


cleanup_generated_files() {
  rm -f \
    .claude/review-loop-run-codex.sh \
    .claude/review-loop-run-gemini.sh \
    .claude/review-loop-run-cursor.sh \
    .claude/review-loop-codex-prompt.txt \
    .claude/review-loop-gemini-prompt.txt \
    .claude/review-loop-cursor-prompt.txt \
    .claude/review-loop-retries
}

trap 'log "ERROR: hook exited via ERR trap (line $LINENO)"; cleanup_generated_files; printf "{\"decision\":\"approve\"}\n"; exit 0' ERR

# Consume stdin (hook input JSON) — must read to avoid broken pipe
HOOK_INPUT=$(cat)

STATE_FILE=".claude/review-loop.local.json"
cleanup_runtime_files() {
  # Keep reviews/${REVIEW_ID:-unknown}/ intact; it is the permanent loop history.
  rm -f "$STATE_FILE" .claude/review-loop.lock
  cleanup_generated_files
}
REVIEWER_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
REVIEWER_RESOLVER="$REVIEWER_SCRIPTS_DIR/resolve-reviewer.sh"

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



if ! ACTIVE=$(parse_field "active") ||
  ! PHASE=$(parse_field "phase") ||
  ! REVIEWER=$(parse_field "reviewer") ||
  ! TASK=$(parse_field "task") ||
  ! ROUND=$(parse_field "round") ||
  ! MAX_ROUNDS=$(parse_field "max_rounds") ||
  ! REVIEW_ID=$(parse_field "review_id"); then
  log "ERROR: failed to read JSON state file"
  cleanup_runtime_files
  printf '{"decision":"approve"}\n'
  exit 0
fi

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
  gemini)
    REVIEWER_CLI="gemini"
    REVIEWER_NAME="Gemini"
    REVIEWER_INSTALL="npm install -g @google/gemini-cli"
    PROMPT_FILE=".claude/review-loop-gemini-prompt.txt"
    RUNNER_SCRIPT=".claude/review-loop-run-gemini.sh"
    ;;
  cursor)
    REVIEWER_CLI="cursor-agent"
    REVIEWER_NAME="Cursor Agent"
    REVIEWER_INSTALL="curl https://cursor.com/install -fsS | bash"
    PROMPT_FILE=".claude/review-loop-cursor-prompt.txt"
    RUNNER_SCRIPT=".claude/review-loop-run-cursor.sh"
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

# ── Build the review prompt ────────────────────────────────────────────────
build_review_prompt() {
  local REVIEW_FILE="$1"

  local IS_NEXTJS=false
  local HAS_UI=false
  detect_nextjs && IS_NEXTJS=true
  detect_browser_ui && HAS_UI=true

  log "Project detection: nextjs=$IS_NEXTJS, browser_ui=$HAS_UI"

  # ── Preamble ──
  cat << PREAMBLE_EOF
You are orchestrating a thorough, independent code review of recent changes in this repository.

Use multi-agent to run the following review agents IN PARALLEL. Each agent should return its findings as structured text (not write to files). After ALL agents complete, consolidate their findings into a single deduplicated review file.

IMPORTANT: Spawn one agent per review path below. Wait for all agents to finish. Then deduplicate overlapping findings and write the consolidated review to: ${REVIEW_FILE}
The first line of the consolidated review file MUST be exactly one of these two lines:
VERDICT: PASS
VERDICT: FAIL


PREAMBLE_EOF


  # ── Agent 1: Diff Review ──
  cat << 'DIFF_EOF'
---
AGENT 1: Diff Review (focus on uncommitted and recently committed changes ONLY)

Run `git diff` and `git diff --cached` to see all uncommitted changes. Also run `git log --oneline -5` and `git diff HEAD~5` for recently committed work. Focus your review EXCLUSIVELY on this changed code.

Review criteria for changed code:

Code Quality:
- Is the changed code well-organized, modular, and readable?
- Does it follow DRY principles — no copy-pasted blocks that should be abstracted?
- Are names (variables, functions, files) clear and consistent with the codebase?
- Are abstractions at the right level — not over-engineered, not under-abstracted?
- Is there unnecessary complexity that could be simplified?

Test Coverage:
- Does every new function/endpoint/component have corresponding tests?
- Are edge cases covered: empty inputs, nulls, boundary values, error paths?
- Are tests isolated, deterministic, and fast?
- Do tests verify behavior (not implementation details)?
- For bug fixes: is there a regression test that would have caught the original bug?

Security:
- Input validation: are all user inputs validated and sanitized before use?
- Authentication/authorization: are auth checks present on all protected routes/actions?
- Injection: any risk of SQL injection, XSS, command injection, path traversal?
- Secrets: are any credentials, API keys, or tokens hardcoded or logged?
- OWASP Top 10: check for broken access control, cryptographic failures, insecure design, security misconfiguration, vulnerable dependencies, SSRF
- Are error messages safe (no stack traces or internal details leaked to users)?

For each issue: return file path, line number, severity (critical/high/medium/low), category, description, and suggested fix.

DIFF_EOF

  # ── Agent 2: Holistic Review ──
  cat << 'HOLISTIC_EOF'
---
AGENT 2: Holistic Review (evaluate overall project structure and agent readiness)

Read the full project directory structure, key config files, README, and any AGENTS.md / CLAUDE.md files. This is NOT about individual line changes — it's about whether the project is well-structured for maintainability and agent-driven development.

Review criteria for the whole project:

Code Organization & Modularity:
- Is the project structure logical and navigable? Can a new developer (or agent) find things?
- Are concerns properly separated (data access, business logic, presentation, config)?
- Are there god files/functions that do too much and should be split?
- Is shared code properly extracted into reusable modules?
- Are import paths clean (absolute imports, no deep relative paths)?

Documentation & Agent Harness:
- Does every major directory have an AGENTS.md with operating guidelines for agents?
- Is there a CLAUDE.md symlinked to each AGENTS.md for Claude Code compatibility?
- Do AGENTS.md files document: conventions, file purposes, testing patterns, common pitfalls?
- Is there telemetry/observability instrumentation (logging, metrics, tracing)?
- Is there a type system in use (TypeScript, Python type hints, etc.) with proper coverage?
- Are there proper constraints and guardrails so agents working on the code are set up for success?
- Are environment variables documented and validated at startup?
- Are there clear boundaries between server-only and client-safe code?

Architecture:
- Is the dependency graph clean (no circular dependencies)?
- Are external integrations properly abstracted behind interfaces?
- Is configuration centralized rather than scattered?
- Is error handling consistent across the codebase?

For each issue: return file path (or directory), severity (critical/high/medium/low), category, description, and suggested fix.

HOLISTIC_EOF

  # ── Agent 3: Next.js Best Practices (conditional) ──
  if [ "$IS_NEXTJS" = "true" ]; then
    cat << 'NEXTJS_EOF'
---
AGENT 3: Next.js & React Best Practices Review

This is a Next.js project. Review the codebase against these specific patterns:

App Router & Server Components:
- Are Server Components used by default? Is 'use client' only added when interactivity is needed?
- Is data fetched in Server Components, not Client Components?
- Are Suspense boundaries used for streaming slow data sources?
- Are file conventions correct: layout.tsx, page.tsx, loading.tsx, error.tsx, not-found.tsx?
- Are searchParams and params handled as Promises (await searchParams / await params)?
- Is generateStaticParams() used to pre-render known dynamic routes?
- Is generateMetadata() used for SEO-critical pages?
- Is notFound() called for missing resources instead of returning null?

Data Fetching & Caching:
- Are parallel data fetches used (Promise.all) instead of sequential waterfalls?
- Is cache strategy appropriate: no-store for fresh data, force-cache for static, revalidate for ISR?
- Are cache tags used for fine-grained invalidation after mutations?
- Is React.cache() used to deduplicate queries within a single request?

Server Actions & Mutations:
- Are Server Actions validated and auth-checked as if they were public API endpoints?
- Is revalidateTag/revalidatePath called after mutations to invalidate cache?
- Is after() used for non-blocking post-response work (logging, analytics)?

Performance & Bundle Size:
- No barrel file imports — import directly from source paths?
- Is next/dynamic with { ssr: false } used for heavy client-only components?
- Are non-critical libraries (analytics, error tracking) deferred until after hydration?
- Are heavy bundles preloaded on user intent (hover/focus)?
- Is data minimized across the RSC boundary (only pass fields client needs)?

React Performance:
- Is derived state calculated during render, not in effects?
- Are expensive computations memoized appropriately?
- Is useTransition used for non-urgent updates?
- No unnecessary useEffect for things that belong in event handlers?
- Are stable callback references used (functional setState, refs) to avoid re-render churn?
- Is content-visibility: auto used for long lists?
- Are inline scripts used to set client data before hydration (prevent FOUC)?

For each issue: return file path, line number, severity (critical/high/medium/low), category, description, and suggested fix.

NEXTJS_EOF
  fi

  # ── Agent 4: UX & Browser Testing (conditional) ──
  if [ "$HAS_UI" = "true" ]; then
    cat << 'UX_EOF'
---
AGENT (UX): Browser-Based UX Review (SKIP if you cannot access a running dev server)

If the project has a running dev server, use agent-browser to test the UI.
Install agent-browser if needed: npm install -g agent-browser (or: brew install agent-browser)

Testing checklist:
- Navigate to all major routes/pages
- Test key user workflows end-to-end (signup, login, CRUD operations, etc.)
- Take screenshots at desktop (1280x720) and mobile (375x812) viewports
- Check for: broken layouts, missing error states, loading states, empty states
- Verify accessibility: keyboard navigation, focus indicators, color contrast
- Check responsive design at multiple breakpoints
- Verify forms have proper validation feedback
- Check that error messages are user-friendly

If the dev server is not running or you cannot access it, skip this agent and note that UX testing was not performed.

For each issue: return screenshot description, severity, category, description, and suggested fix.

UX_EOF
  fi

  # ── Consolidation instructions ──
  cat << CONSOLIDATION_EOF
---
CONSOLIDATION INSTRUCTIONS (after all agents complete):

1. Collect all findings from all agents
2. Deduplicate: if multiple agents flagged the same issue, keep the most detailed version
3. Organize all findings by severity (critical first, then high, medium, low)
4. For each finding, include:
   - File path and line number (or directory for structural issues)
   - Severity: critical / high / medium / low
   - Category: which review path found it (Diff, Holistic, Next.js, UX)
   - Description: clear explanation
   - Suggested fix: concrete, actionable recommendation
5. End with a summary: total issues, breakdown by severity, agents that ran, overall assessment
6. Write the COMPLETE consolidated review to: ${REVIEW_FILE}

IMPORTANT: You MUST create the file ${REVIEW_FILE} with the full review.
CONSOLIDATION_EOF
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


    REVIEW_PROMPT=$(build_review_prompt "$REVIEW_FILE")
    printf '%s' "$REVIEW_PROMPT" > "$PROMPT_FILE"

    cat > "$RUNNER_SCRIPT" << RUNNER_EOF
#!/usr/bin/env bash
LOG_FILE=".claude/review-loop.log"
log() { echo "[\$(date -u +"%Y-%m-%dT%H:%M:%SZ")] \$*" >> "\$LOG_FILE"; }

REVIEWER='${REVIEWER}'
PROMPT_FILE='${PROMPT_FILE}'
REVIEW_FILE='${REVIEW_FILE}'
DISPATCHER_SCRIPT='${REVIEWER_DISPATCHER}'
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

"\$DISPATCHER_SCRIPT" "\$REVIEWER" "\$PROMPT_FILE" "\$REVIEW_FILE"
REVIEWER_EXIT=\$?

ELAPSED=\$(( \$(date +%s) - START_TIME ))
log "\$REVIEWER finished (exit=\$REVIEWER_EXIT, elapsed=\${ELAPSED}s)"
exit \$REVIEWER_EXIT
RUNNER_EOF
    chmod +x "$RUNNER_SCRIPT"

    # Run the current round before asking Claude to address its findings.
    run_review() {
      if [ -e /dev/tty ] && { : >/dev/tty; } 2>/dev/null; then
        "$RUNNER_SCRIPT" </dev/null >/dev/tty 2>&1
      else
        "$RUNNER_SCRIPT" </dev/null >>"$LOG_FILE" 2>&1
      fi
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

    log "Prepared ${REVIEWER} review for Claude to address (review_id=$REVIEW_ID)"
    if [ "$REVIEWER_EXIT" -eq 0 ]; then
      REVIEW_STATUS="completed"
    else
      REVIEW_STATUS="exited with status ${REVIEWER_EXIT}; rerun it if the review artifact is missing or malformed"
    fi
    REASON="Phase 1 complete. The ${REVIEWER} review for round ${ROUND} ${REVIEW_STATUS}.

Read ${REVIEW_FILE} and address the findings:
1. Read the review carefully
2. For each item, independently decide if you agree
3. For items you AGREE with: implement the fix
4. For items you DISAGREE with: briefly note why you are skipping them
5. Focus on critical and high severity items first
6. Write a summary of the fixes, skipped findings, and verification results to ${SUMMARY_FILE}
7. When done addressing all relevant items, you may stop

If ${REVIEW_FILE} is missing or malformed, rerun the reviewer with a 600000ms timeout:
\`\`\`
bash ${RUNNER_SCRIPT}
\`\`\`

Use your own judgment. Do not blindly accept every suggestion."

    SYS_MSG="Review Loop [${REVIEW_ID}] — Phase 2/2: Address ${REVIEWER} review feedback"

    jq -n --arg r "$REASON" --arg s "$SYS_MSG" \
      '{decision:"block", reason:$r, systemMessage:$s}' 2>/dev/null \
      || printf '{"decision":"block","reason":"Phase 1 complete. Read the review and address the findings.","systemMessage":"%s"}\n' "$SYS_MSG"
    ;;

  addressing)
    # ── Phase 2: verify review verdict before allowing exit ───────────────
    if [ -f "$REVIEW_FILE" ]; then
      if VERDICT=$(parse_verdict "$REVIEW_FILE"); then
        log "Review loop complete (review_id=$REVIEW_ID, reviewer=$REVIEWER, verdict=$VERDICT)"
        cleanup_runtime_files
        printf '{"decision":"approve"}\n'
      else
        log "Review verdict: FAIL (missing or malformed, review_id=$REVIEW_ID)"
        REASON="The review verdict is FAIL because it is absent or malformed. Treat it as FAIL, correct the review output, then run the reviewer again:

\`\`\`
bash ${RUNNER_SCRIPT}
\`\`\`"
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
        REASON="The ${REVIEWER} review has not been completed yet. Please run the review script (use a 600000ms timeout since reviews can take several minutes):

\`\`\`
bash ${RUNNER_SCRIPT}
\`\`\`

Then read ${REVIEW_FILE} and address the findings."
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
