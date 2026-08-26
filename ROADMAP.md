# Roadmap

Status: draft

## Purpose

This fork will evolve `review-loop` from a Codex-specific, one-pass workflow into a reviewer-neutral, bounded review loop:

```text
Claude implements
→ reviewer checks the changes
→ Claude corrects findings
→ reviewer checks again
→ repeat until PASS or the round limit is reached
```

Claude remains the implementer for now. The review CLI becomes configurable, with `cursor-agent` as the first priority while retaining Codex and Gemini support.

## Goals

- Run reviews through multiple CLI providers.
- Support a complete review, correction, and re-review cycle.
- Stop only when the reviewer returns `PASS`, or report a clear non-success outcome when the round limit or an infrastructure error ends the loop.
- Preserve review history and correction decisions for every round.
- Keep the workflow visible, cancellable, and safe to run from nested directories and worktrees.
- Keep reviewer prompts independent from reviewer-specific shell code.

## Non-goals

- Replacing Claude as the implementation agent.
- Automatically pushing branches or opening pull requests.
- Running multiple implementation agents concurrently.
- Allowing an unbounded loop.
- Treating a reviewer or infrastructure failure as a successful review.

## Current baseline

The current workflow is a two-phase, one-pass process:

1. Claude implements the task.
2. The Stop hook prepares a Codex prompt and runner script.
3. Claude runs Codex and addresses the findings.
4. The Stop hook approves exit when the review file exists.

The final correction is not reviewed again. Runtime state and generated files currently live under `.claude/`.

## Fork work worth reusing

- [Smiie-2](https://github.com/Smiie-2/claude-review-loop): reviewer dispatch, external prompt templates, JSON state, on-demand reviews, and shell tests.
- [BUZDOLAPCI](https://github.com/BUZDOLAPCI/claude-review-loop): per-round review history, explicit `PASS`/`FAIL` verdicts, fresh Claude correction sessions, and the orchestrator loop.
- [YukiCoco](https://github.com/YukiCoco/claude-review-loop): project-root discovery, worktree-safe paths, optional PR scope, and spec-compliance review guidance.

Do not merge any fork wholesale. Each fork makes assumptions that do not match this project exactly.

## Phase 1: Reviewer adapter

Extract reviewer-specific behavior from `stop-hook.sh` into a small dispatch layer.

- [x] Support `codex`, `gemini`, and `cursor` reviewers.
- [x] Resolve the reviewer in this order: `REVIEW_LOOP_REVIEWER`, project config, user config, default.
- [x] Add reviewer-specific availability checks and flags.
- [x] Add the Cursor headless invocation.
- [x] Keep Codex behavior working without requiring a new configuration format.
- [x] Add tests for reviewer selection, precedence, missing CLIs, and malformed configuration.

Initial Cursor invocation target:

```bash
cursor-agent -p --output-format text < "$PROMPT_FILE"
```

## Phase 2: State and review contract

Replace ad-hoc phase parsing with explicit per-loop state and artifacts.

- [x] Store state as JSON.
- [x] Track reviewer, task, round, maximum rounds, phase, and review ID.
- [x] Create one directory per loop.
- [x] Store `summary-0.md`, `review-1.md`, `summary-1.md`, and later rounds together.
- [x] Require the first review line to be exactly `VERDICT: PASS` or `VERDICT: FAIL`.
- [x] Treat an absent or malformed verdict as `FAIL`.
- [x] Make the runner capture the review result into the round artifact where possible.
- [x] Keep all review artifacts when the loop reaches `PASS`, `MAX_ROUNDS_REACHED`, `REVIEWER_ERROR`, or `CANCELLED`.

Proposed outcomes:

```text
PASS
MAX_ROUNDS_REACHED
REVIEWER_ERROR
CANCELLED
```

Only `PASS` means the changes were accepted.

## Phase 3: Iterative orchestrator

Add the review, correction, and re-review loop.

- [x] Run the configured reviewer for the current round.
- [x] Verify that the reviewer produced a usable artifact.
- [x] Parse the verdict.
- [ ] Stop immediately on `PASS`.
- [ ] On `FAIL`, start a fresh Claude correction session.
- [ ] Ask Claude to read the full round history before changing code.
- [ ] Require Claude to record fixes, skipped findings, and quality-gate results.
- [ ] Continue until `PASS` or the configured maximum round count.
- [ ] Make the round limit configurable, with a bounded default.
- [ ] Support cancellation that stops child processes without deleting review history.
- [ ] Prevent correction-session Stop hooks from recursively starting another orchestrator.

The initial implementation should remain interactive. Fresh headless Claude sessions should handle only later correction rounds.

## Phase 4: Review scope and prompt quality

Combine the useful prompt changes from the forks without forcing a pull-request workflow.

- [ ] Move prompt templates into separate Markdown files.
- [ ] Include the original task in every review.
- [ ] Include previous reviews and correction summaries in later rounds.
- [ ] Review the current branch diff by default.
- [ ] Add optional GitHub and Gitea PR scoping.
- [ ] Add spec-compliance review when a specification or plan exists.
- [ ] Keep diff, architecture, framework, and UX review sections where they apply.
- [ ] Tell reviewers not to modify source files.
- [ ] Require actionable findings with file, line, severity, explanation, and suggested fix.
- [ ] Require Claude to verify findings before applying them.

The first portable implementation should use one reviewer invocation per round. Provider-native subagents can be used where available, but the loop must not depend on Codex-only multi-agent configuration.

## Phase 5: Verification and release

Add deterministic tests around the shell lifecycle before changing the default behavior.

- [ ] Test `PASS` on the first round.
- [ ] Test `FAIL → PASS` across two rounds.
- [ ] Test repeated `FAIL` until the round limit.
- [ ] Test malformed verdicts and missing artifacts.
- [ ] Test reviewer non-zero exit and timeout behavior.
- [ ] Test cancellation and child-process cleanup.
- [ ] Test nested working directories and worktrees.
- [ ] Test concurrent loop isolation.
- [ ] Test provider selection and command construction with fake CLIs.
- [ ] Run shellcheck and the full plugin test suite in CI.
- [ ] Update README, `AGENTS.md`, configuration examples, and generated-file documentation.
- [ ] Bump the plugin version for the first released implementation.

## Acceptance criteria

The roadmap is complete when all of these hold:

1. `REVIEW_LOOP_REVIEWER=cursor` runs a real review without Codex-specific setup.
2. Codex and Gemini remain selectable through the same configuration path.
3. A `FAIL` review causes Claude to correct the code and triggers another review.
4. A later `PASS` ends the loop and preserves every round artifact.
5. Repeated failures stop at the configured limit and are reported as not accepted.
6. Reviewer errors and cancellation never report `PASS`.
7. Review prompts include task context and prior round decisions.
8. The loop works from nested directories and does not mix concurrent loop state.
9. Tests cover the state machine, reviewer dispatch, verdict parsing, cancellation, and cleanup.

## Open decisions

- Whether the orchestrator should run in the foreground inside the Stop hook or as a managed background process.
- The default maximum number of rounds.
- Whether all providers should return review text on stdout, or whether provider-specific file-writing remains supported.
- Whether Cursor should use one broad review prompt or several independent review invocations.
