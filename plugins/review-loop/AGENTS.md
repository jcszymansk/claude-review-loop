# review-loop Plugin — Agent Guidelines

## What this is

A Claude Code plugin that creates a bounded review loop:
1. Claude implements a task
2. The Stop hook runs the configured reviewer
3. On `FAIL`, the Stop hook starts a fresh interactive Claude correction session
4. After a complete correction summary, the hook reruns the reviewer for the next round until `PASS` or the round limit

## Conventions

- Shell scripts must work on both macOS and Linux (handle `sed -i` differences)
- The stop hook MUST always produce valid JSON to stdout — never let non-JSON text leak
- Fail-open: on any error, approve exit rather than trapping the user
- State lives in `.claude/review-loop.local.json` as JSON with `active`, `reviewer`, `task`, `round`, `max_rounds`, `phase`, `review_id`, and `started_at`; an optional validated `pr_url` keeps pull request scope stable across rounds. Clean up runtime state on exit, but never remove `reviews/<review_id>/` history
- Each loop gets a validated `reviews/<review_id>/` directory containing `branch-diff.md`, `summary-0.md`, `review-<round>.md`, and `summary-<round>.md` artifacts; retain it for every terminal outcome.
- Reviewer runner scripts (`.claude/review-loop-run-codex.sh`, `.claude/review-loop-run-gemini.sh`, or `.claude/review-loop-run-cursor.sh`) run the selected provider and capture its output in the current round artifact; the active child PID is tracked in `.claude/review-loop-child.pid`.
- The selected review prompt is saved to the matching `.claude/review-loop-<reviewer>-prompt.txt` file for the runner script
- `REVIEW_LOOP_PR` or `--pr <url>` selects a GitHub or Gitea pull request; the hook fetches its diff with `curl` and falls back to the local branch diff with a warning when the fetch fails
- Telemetry goes to `.claude/review-loop.log` — structured, timestamped lines
- Phase transitions use `transition_phase()` (atomic `jq` rewrite + verify), NOT fragile text parsing
- All `jq` calls that produce block decisions MUST have a `|| printf '...'` fallback — if jq fails, the ERR trap would silently approve exit and drop the review
- Claude Code does NOT set `stop_hook_active` in hook input — do not rely on it for re-entrancy detection
- The `addressing` phase verifies the current numbered review file and correction summary before allowing exit; a complete `FAIL` round advances automatically to the next review
- Correction summaries must be non-empty and contain `## Fixes`, `## Skipped findings`, and `## Quality gates`; record each verification command with a `PASS`, `FAIL`, or `NOT RUN` result before a `PASS` verdict can approve exit
- Every review finding must be actionable: file path and line number (or directory for structural issues), severity (critical/high/medium/low), explanation, and suggested fix; incomplete findings are discarded at consolidation
- Correction sessions must verify each finding against the codebase (referenced file and line, reproduction) before applying a fix; findings that do not reproduce, are already fixed, or are rejected are recorded under `Skipped findings` with the reason

## Security constraints

- Review IDs are validated against `^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$` to prevent path traversal
- Reviewer-specific flags are configurable through `REVIEW_LOOP_CODEX_FLAGS`, `REVIEW_LOOP_GEMINI_FLAGS`, and `REVIEW_LOOP_CURSOR_FLAGS`
- Pull request authentication uses `GITHUB_TOKEN` or `GITEA_TOKEN`; tokens MUST NOT be written to state or artifacts
- No secrets or credentials are stored in state files

## Testing

- After modifying stop-hook.sh, test all paths: no-state, task→block, addressing-without-review→block, addressing-with-review→approve
- Verify JSON output with `jq .` for each path
- Test with Codex unavailable (should block with install instructions)
- Test with malformed state files (should fail-open)
- Test phase transition: verify `transition_phase` updates state file and `parse_field` reads the new value
- Test addressing phase blocks when the review file or verdict is missing, malformed, or `FAIL`, and approves only when a valid `PASS` verdict exists.
- Run `tests/cancellation.sh` to verify reviewer and correction-session processes stop while review history remains.
