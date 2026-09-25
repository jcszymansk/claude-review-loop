# review-loop Plugin — Agent Guidelines

## What this is

A Claude Code plugin that creates a bounded review loop:
1. Claude implements a task
2. The Stop hook runs the configured reviewer
3. On `FAIL`, the Stop hook returns the findings to the same Claude session
4. After a complete correction summary, the hook reruns the reviewer for the next round until `PASS` or the round limit

## Conventions

- Shell scripts must work on both macOS and Linux (handle `sed -i` differences)
- The stop hook MUST always produce valid JSON to stdout — never let non-JSON text leak
- Fail-open: on any error, approve exit rather than trapping the user, but never silently. Every approve that ends an active loop without a `PASS` goes through `fail_open "<cause>"`, whose `systemMessage` names the cause and `.claude/review-loop.log`; the ERR trap prints a static JSON message so it cannot fail. Only the no-state approve, the `PASS` approve and the reviewer process's own approve stay silent. Blocks that end the loop (missing CLI, Codex multi-agent disabled) also carry a `systemMessage`
- State lives in `.claude/review-loop.local.json` as JSON with `active`, `reviewer`, `task`, `round`, `max_rounds`, `review_timeout`, `phase`, `review_id`, `started_at`, and the task-start `baseline_tree`; an optional validated `pr_url` keeps pull request scope stable across rounds. Legacy state without `review_timeout` is resolved with `resolve-review-timeout.sh` at hook time, falling back to the 1800s default, and the log says which. Clean up runtime state on exit, but never remove `reviews/<review_id>/` history
- Each loop gets a validated `reviews/<review_id>/` directory containing `branch-diff.md`, `task-diff.md`, `summary-0.md`, `review-<round>.md`, and `summary-<round>.md` artifacts; `task-diff.md` is the authoritative diff for work performed after loop start, and history is retained for every terminal outcome.
- Reviewer runner scripts (`.claude/review-loop-run-codex.sh`, `.claude/review-loop-run-cursor.sh`, or `.claude/review-loop-run-claude.sh`) run the selected provider and capture its output in the current round artifact; a non-zero reviewer exit preserves the artifact as a numbered `review-<round>.md.reviewer-error.<n>` file so a failed review can never be accepted as PASS (`scripts/quarantine-review-artifact.sh` owns the numbering); the runner records its own PID and then the dispatcher PID, one per line, in `.claude/review-loop-child.pid`.
- Reviewer time limit: `review_timeout` (seconds) is resolved at setup by `resolve-review-timeout.sh` (`REVIEW_LOOP_REVIEW_TIMEOUT` → project config → user config → default `1800`) and must be a positive integer no larger than the `hooks.json` Stop hook timeout minus 60; an unreadable config file or `hooks.json` fails setup. The `hooks.json` timeout (14400s) is only a backstop: Claude Code discards a cancelled hook's output, so the hook must finish first. `read-hook-timeout.sh` is the only reader of that number and selects the `stop-hook.sh` entry by command.
- The hook records its start time before doing anything else and passes it to the re-exec'd hook in `REVIEW_LOOP_HOOK_STARTED_AT`, so one Stop event keeps one clock. Before starting the reviewer it computes `effective = min(review_timeout, hook timeout - elapsed - 60)`, logs configured and effective values, and logs a warning when the cap lowers the limit. When `effective <= 0` the reviewer is not started and the round is reported as a timeout. The runner script carries the configured limit, because Claude may rerun it outside the hook; the hook passes the lower effective limit to its own run in `REVIEW_LOOP_EFFECTIVE_REVIEW_TIMEOUT`.
- The generated runner starts the dispatcher in its own process group (`set -m`) and a watchdog subshell (`sleep` + `wait`; a TERM before expiry stops it quietly and kills the sleep). On expiry the watchdog ignores further TERM, runs `scripts/stop-process-tree.sh` (TERM to the tree and the group, KILL to survivors after 5s, re-collecting processes forked meanwhile), and exits 124 only if it stopped a running reviewer. The runner then writes `.claude/review-loop-timed-out`, quarantines any partial `review-<round>.md` and leftover stdout capture, logs `ERROR: <reviewer> review timed out after <n>s (limit <n>s)`, and exits 124. A reviewer that finishes first stops the watchdog; a TERM or HUP to the runner stops both. The dispatcher keeps a non-empty stdout capture of an interrupted run as a reviewer-error file
- Exit 124 alone never means a timeout: a reviewer can exit 124 by itself. Only the flag file does. The hook deletes the flag after reading it and reports the timeout through the normal handoff (`REVIEW_STATUS`, retry gate) with a `systemMessage` naming the limit and `REVIEW_LOOP_REVIEW_TIMEOUT` / `review_timeout`; a flag left by a timed-out manual rerun is reported by the retry gate, including in the `systemMessage` of the final fail-open approve
- Runtime files are listed twice, in `cleanup_generated_files` (hook) and `runtime_files` (`cancel-review-loop.sh`); add new ones to both
- The selected review prompt is saved to the matching `.claude/review-loop-<reviewer>-prompt.txt` file for the runner script
- The verdict is the first line of each review artifact and must be exactly `VERDICT: PASS` or `VERDICT: FAIL`; an absent or malformed verdict is treated as `FAIL` and blocks exit until the review is fixed or rerun
- A missing review artifact prompts Claude to rerun the generated runner script once (counted in `.claude/review-loop-retries`); on the second stop without an artifact the hook fails open. The prompts ask Claude to run it with the Bash tool's `run_in_background` option and wait for the completion notification, never with a tool timeout. If the first PID in `.claude/review-loop-child.pid` is still a running review runner (checked by command line, so a stale or reused PID is ignored), the addressing phase waits for it within the hook budget before evaluating, and blocks with a "still running" message without touching the retry count when the budget runs out
- Claude reviewer processes use `REVIEW_LOOP_REVIEWER_PROCESS=1` so they cannot recursively start another review
- Telemetry goes to `.claude/review-loop.log` — structured, timestamped lines; `REVIEW_LOOP_DEBUG=1` additionally preserves reviewer invocation metadata and raw provider stdout/stderr in `.claude/review-loop-debug.log`
- Phase transitions use `transition_phase()` (atomic `jq` rewrite + verify), NOT fragile text parsing
- All `jq` calls that produce block decisions MUST have a `|| printf '...'` fallback — if jq fails, the ERR trap would silently approve exit and drop the review
- Claude Code does NOT set `stop_hook_active` in hook input — do not rely on it for re-entrancy detection
- The `addressing` phase verifies the current numbered review file and correction summary before allowing exit; a complete `FAIL` round advances automatically to the next review
- Correction summaries must be non-empty and contain `## Fixes`, `## Skipped findings`, and `## Quality gates`; record each verification command with a `PASS`, `FAIL`, or `NOT RUN` result before a `PASS` verdict can approve exit
- Every review finding must be actionable: file path and line number (or directory for structural issues), severity (critical/high/medium/low), explanation, and suggested fix; incomplete findings are discarded at consolidation
- Claude must verify each finding against the codebase before applying a fix in the main session: open the referenced file and line (or directory) and confirm the issue is still present by reproducing it when applicable or by inspecting the code; findings that cannot be verified, are already fixed, or are rejected are recorded under `Skipped findings` with the reason

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
- `background-rerun.sh` — rerun prompts use `run_in_background` instead of a 600000ms timeout; the hook waits for a live background rerun and then evaluates its `PASS`; a failed rerun goes through the retry gate; stale or reused PIDs are not waited on; the wait stays inside the `hooks.json` budget and blocks without consuming the retry
- `fail-open-messages.sh` — every triggerable fail-open path (retry exhausted, orphaned, malformed or inactive state, invalid review ID, unsupported reviewer, unknown phase, phase transition failure, missing prompt template, ERR trap, missing `jq`) approves with a `systemMessage` naming the cause and the log; loop-ending blocks for a missing CLI or disabled Codex multi-agent carry one too; the no-state and `PASS` approves stay silent
- `review-timeout.sh` — `resolve-review-timeout.sh` precedence, default, and rejection of invalid or too-large values (bound read from the `stop-hook.sh` entry of `hooks.json`), unreadable `hooks.json` and config files; setup state; a hung reviewer stopped by the watchdog (exit 124, log lines, no surviving processes, PID and flag files removed, partial artifact quarantined, never PASS, valid hook JSON and `systemMessage`); KILL escalation for a reviewer ignoring TERM; a reviewer's own exit 124 not reported as a timeout; the watchdog stopped when the reviewer finishes first or the runner is signalled; the `hooks.json` cap and its warning; an exhausted hook budget; the start time inherited across the re-exec; legacy state; a manual runner rerun enforcing the limit and its report at fail-open; malformed or unusual `review_timeout` and `REVIEW_LOOP_HOOK_STARTED_AT` values; `stop-process-tree.sh` (argument errors, finished processes, children forked during the grace period) and `quarantine-review-artifact.sh` (errors, numbering, no overwrite)
- `reviewer-errors.sh` — reviewer non-zero exit and an externally killed hung reviewer never report PASS: each failed attempt is preserved as a numbered `review-<round>.md.reviewer-error.<n>` artifact, the canonical review path stays vacant so the retry gate takes over, and the loop fails open while keeping history
- `runner-capture.sh` — the runner script captures reviewer output into the current round artifact
- `cancellation.sh` — `/cancel-review` stops reviewer child processes while review history remains
- `nested-worktrees.sh` — nested working directories and git worktrees keep state and artifacts in the session directory
- `concurrent-isolation.sh` — two loops in one repository (root and nested directory) keep separate state, prompts, runner scripts, logs, and review history; one loop's cleanup never touches the other's files
- `resolve-reviewer.sh` — reviewer precedence (`REVIEW_LOOP_REVIEWER` → project config → user config → default), including opt-in `claude`
- `reviewer-availability.sh` — missing CLI blocks with install instructions and leaves no generated runtime files; retry gate and cancellation instructions for all supported reviewers
- `command-construction.sh` — `run-reviewer.sh` builds the exact per-provider command (flags, prompt as argument for codex/claude vs stdin for cursor), rejects unsupported reviewers with exit 2, exports the Claude recursion guard without `CLAUDECODE`/`CLAUDE_CODE_ENTRYPOINT`, and captures or quarantines review artifacts by verdict and exit status
- `legacy-codex.sh` — Codex behavior without reviewer configuration, including legacy state files
- `main-session-handoff.sh` — a failed review hands off to the main Claude session consistently in PTY and non-PTY hook environments without invoking `claude`
- `branch-diff.sh` — current branch diff scope, upstream fallback, unborn repositories, and untracked files
- `task-diff.sh` — task-start tree snapshot excludes pre-existing staged, unstaged, and untracked worktree changes from the authoritative task diff
- `pr-scope.sh` — GitHub and Gitea pull request diff scoping with local branch fallback and warning
- `review-sections.sh` — conditional diff, architecture, framework, and UX review sections
- `spec-compliance.sh` — spec-compliance review when a specification or plan exists
- `actionable-findings.sh` — findings must carry file, line, severity, explanation, and suggested fix
- `verify-findings.sh` — Claude must verify each finding against the codebase before applying it
