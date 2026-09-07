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
- State lives in `.claude/review-loop.local.json` as JSON with `active`, `reviewer`, `task`, `round`, `max_rounds`, `phase`, `review_id`, `started_at`, and the task-start `baseline_tree`; an optional validated `pr_url` keeps pull request scope stable across rounds. Clean up runtime state on exit, but never remove `reviews/<review_id>/` history
- Each loop gets a validated `reviews/<review_id>/` directory containing `branch-diff.md`, `task-diff.md`, `summary-0.md`, `review-<round>.md`, and `summary-<round>.md` artifacts; `task-diff.md` is the authoritative diff for work performed after loop start, and history is retained for every terminal outcome.
- Reviewer runner scripts (`.claude/review-loop-run-codex.sh`, `.claude/review-loop-run-cursor.sh`, or `.claude/review-loop-run-claude.sh`) run the selected provider and capture its output in the current round artifact; a non-zero reviewer exit preserves the artifact as a numbered `review-<round>.md.reviewer-error.<n>` file so a failed review can never be accepted as PASS; the active child PID is tracked in `.claude/review-loop-child.pid`.
- The selected review prompt is saved to the matching `.claude/review-loop-<reviewer>-prompt.txt` file for the runner script
- The verdict is the first line of each review artifact and must be exactly `VERDICT: PASS` or `VERDICT: FAIL`; an absent or malformed verdict is treated as `FAIL` and blocks exit until the review is fixed or rerun
- A missing review artifact prompts Claude to rerun the generated runner script once (counted in `.claude/review-loop-retries`); on the second stop without an artifact the hook fails open
- Fresh correction sessions and Claude reviewer sessions run with their recursion guard (`REVIEW_LOOP_CORRECTION=1` / `REVIEW_LOOP_REVIEWER_PROCESS=1`) and without `CLAUDECODE`/`CLAUDE_CODE_ENTRYPOINT`, so neither can recursively start another review
- Telemetry goes to `.claude/review-loop.log` — structured, timestamped lines; `REVIEW_LOOP_DEBUG=1` additionally preserves reviewer invocation metadata and raw provider stdout/stderr in `.claude/review-loop-debug.log`
- Phase transitions use `transition_phase()` (atomic `jq` rewrite + verify), NOT fragile text parsing
- All `jq` calls that produce block decisions MUST have a `|| printf '...'` fallback — if jq fails, the ERR trap would silently approve exit and drop the review
- Claude Code does NOT set `stop_hook_active` in hook input — do not rely on it for re-entrancy detection
- The `addressing` phase verifies the current numbered review file and correction summary before allowing exit; a complete `FAIL` round advances automatically to the next review
- Correction summaries must be non-empty and contain `## Fixes`, `## Skipped findings`, and `## Quality gates`; record each verification command with a `PASS`, `FAIL`, or `NOT RUN` result before a `PASS` verdict can approve exit
- Every review finding must be actionable: file path and line number (or directory for structural issues), severity (critical/high/medium/low), explanation, and suggested fix; incomplete findings are discarded at consolidation
- Claude must verify each finding against the codebase before applying a fix, in the original session and in fresh correction sessions alike: open the referenced file and line (or directory) and confirm the issue is still present by reproducing it when applicable or by inspecting the code; findings that cannot be verified, are already fixed, or are rejected are recorded under `Skipped findings` with the reason

## Security constraints

- Review IDs are validated against `^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$` to prevent path traversal
- Reviewer-specific flags are configurable through `REVIEW_LOOP_CODEX_FLAGS` and `REVIEW_LOOP_CURSOR_FLAGS`
- Claude reviewer flags are configurable through `REVIEW_LOOP_CLAUDE_FLAGS`; the default `--permission-mode acceptEdits` permits the review artifact write without `--bare`
- Pull request authentication uses `GITHUB_TOKEN` or `GITEA_TOKEN`; tokens MUST NOT be written to state or artifacts
- No secrets or credentials are stored in state files

## Testing

After modifying `stop-hook.sh`, test all paths: no-state, task→block, addressing-without-review→block, addressing-with-review→approve. Verify JSON output with `jq .` for each path, test with the reviewer CLI unavailable (should block with install instructions), and test with malformed state files (should fail-open). Verify `transition_phase` updates the state file and `parse_field` reads the new value, and that the addressing phase blocks when the review file or verdict is missing, malformed, or `FAIL`, approving only when a valid `PASS` verdict exists.

Each `tests/*.sh` is self-contained: it builds a sandboxed project with fake CLIs and a fake HOME, runs the hook or scripts, and asserts observable outcomes. Run the full suite the way CI does:

```bash
cd plugins/review-loop/tests
for test in *.sh; do bash "$test"; done
```

CI also runs `shellcheck -x plugins/review-loop/hooks/*.sh plugins/review-loop/scripts/*.sh plugins/review-loop/tests/*.sh`. Coverage by script:

- `first-round-pass.sh` — `PASS` on the first round approves exit, removes runtime state, keeps every artifact
- `iterative-rounds.sh` — `FAIL → PASS` across two rounds; repeated `FAIL` until the round limit, ending in `MAX_ROUNDS_REACHED` with review history kept
- `round-limit.sh` — `resolve-max-rounds.sh` precedence (env → project config → user config → default `3`), invalid value rejection, and setup state
- `malformed-verdicts.sh` — absent and malformed verdicts, missing artifacts, retry gate, orphaned state
- `reviewer-errors.sh` — reviewer non-zero exit and timeout never report PASS: each failed attempt is preserved as a numbered `review-<round>.md.reviewer-error.<n>` artifact, the canonical review path stays vacant so the retry gate takes over, and the loop fails open while keeping history
- `runner-capture.sh` — the runner script captures reviewer output into the current round artifact
- `cancellation.sh` — `/cancel-review` stops reviewer and correction-session child processes while review history remains
- `nested-worktrees.sh` — nested working directories and git worktrees keep state and artifacts in the session directory
- `concurrent-isolation.sh` — two loops in one repository (root and nested directory) keep separate state, prompts, runner scripts, logs, and review history; one loop's cleanup never touches the other's files
- `resolve-reviewer.sh` — reviewer precedence (`REVIEW_LOOP_REVIEWER` → project config → user config → default), including opt-in `claude`
- `reviewer-availability.sh` — missing CLI blocks with install instructions and leaves no generated runtime files; retry gate and cancellation instructions for all supported reviewers
- `command-construction.sh` — `run-reviewer.sh` builds the exact per-provider command (flags, prompt as argument for codex/claude vs stdin for cursor), rejects unsupported reviewers with exit 2, exports the Claude recursion guard without `CLAUDECODE`/`CLAUDE_CODE_ENTRYPOINT`, and captures or quarantines review artifacts by verdict and exit status
- `legacy-codex.sh` — Codex behavior without reviewer configuration, including legacy state files
- `correction-session.sh` — fresh interactive correction session launch without `CLAUDECODE`/`CLAUDE_CODE_ENTRYPOINT`, review/summary prompt paths, and fallback when `claude` is unavailable
- `branch-diff.sh` — current branch diff scope, upstream fallback, unborn repositories, and untracked files
- `task-diff.sh` — task-start tree snapshot excludes pre-existing staged, unstaged, and untracked worktree changes from the authoritative task diff
- `pr-scope.sh` — GitHub and Gitea pull request diff scoping with local branch fallback and warning
- `review-sections.sh` — conditional diff, architecture, framework, and UX review sections
- `spec-compliance.sh` — spec-compliance review when a specification or plan exists
- `actionable-findings.sh` — findings must carry file, line, severity, explanation, and suggested fix
- `verify-findings.sh` — Claude must verify each finding against the codebase before applying it
