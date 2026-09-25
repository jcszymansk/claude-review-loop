# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@AGENTS.md

The plugin's own conventions, security constraints, state/artifact contract and per-test coverage list live in `plugins/review-loop/AGENTS.md` (`plugins/review-loop/CLAUDE.md` is a symlink to it). Read it before touching anything under `plugins/review-loop/`.

## Commands

Everything is bash plus `jq`. Tests also need `git`, `pgrep`/`ps`, and util-linux `script` (`main-session-handoff.sh` uses `script -qefc`, which does not work with the BSD `script` on macOS).

```bash
# Lint (CI runs this exact command; test files must be shellcheck-clean too)
shellcheck -x plugins/review-loop/hooks/*.sh plugins/review-loop/scripts/*.sh plugins/review-loop/tests/*.sh

# Full suite, the way CI runs it
cd plugins/review-loop/tests && for test in *.sh; do bash "$test" || echo "FAILED: $test"; done

# Single test (any cwd works; tests locate the plugin from their own path)
bash plugins/review-loop/tests/iterative-rounds.sh
```

Several tests do not sanitize the environment. Unset `REVIEW_LOOP_*` variables and make sure no `~/.config/review-loop/config.toml` (or `$XDG_CONFIG_HOME` equivalent) is affecting results before trusting a local failure.

## Architecture

The plugin is a Stop hook driven state machine. All runtime paths (`.claude/…`, `reviews/<id>/…`) are relative to the cwd where the loop started; there is no project-root discovery. Nested directories and worktrees get independent loops for that reason, and a second loop in the same cwd is refused by the state-file check.

**Setup lives in two places.** `commands/review-loop.md` embeds its own setup logic in its first ```` ```bash ```` fence: it calls `resolve-pr-url.sh`, `resolve-reviewer.sh`, `resolve-max-rounds.sh`, `capture-worktree-tree.sh` and `ensure-codex-config.sh`, then writes the state JSON. `scripts/setup-review-loop.sh` is a parallel CLI implementation of the same logic, used by tests. Changes to setup must be made in both. `tests/pr-scope.sh` extracts and executes that first bash fence from the command file with `awk`, so restructuring the command doc can break it.

**`hooks/stop-hook.sh`** has two phases:

- `task`: computes `task-diff.md` (against the baseline tree captured at setup) and the scope diff (PR diff via `curl`, else branch diff), renders the prompt, writes a runner script `.claude/review-loop-run-<reviewer>.sh` from a heredoc, runs it synchronously (hence the 600s timeout in `hooks/hooks.json`), transitions to `addressing`, and blocks with `prompts/addressing-review.md`.
- `addressing`: checks the summary and the verdict of the current round. `PASS` cleans up and approves. `FAIL` below the round limit calls `transition_to_next_round` and then `exec`s the hook again with the saved stdin, so one Stop event can run the reviewer for a new round. `FAIL` at the limit yields `MAX_ROUNDS_REACHED`. Missing artifacts go through the retry gate, then fail open.

Any other phase cleans up and approves.

**Prompts** are plain Markdown with fixed `__PLACEHOLDER__` tokens replaced by bash string substitution (`render_prompt_template`). An unknown placeholder is left in the output silently, and templates have no conditional syntax. Conditional review sections are whole files appended by `build_review_prompt`: `review-base.md`, then `review-spec.md` / `review-nextjs.md` / `review-ux.md` when detected, then `review-consolidation.md`. Several tests (`review-sections.sh`, `actionable-findings.sh`, `verify-findings.sh`) match exact prompt and command-doc wording, so rewording prompts means updating those tests.

**Reviewer dispatch**: the generated runner records its PID and calls `scripts/run-reviewer.sh <reviewer> <prompt-file> <review-file>`, which builds the per-provider command. It adopts captured stdout as the review only when the reviewer did not write a valid artifact itself. `/cancel-review` runs `scripts/cancel-review-loop.sh`, which kills the recorded process tree and removes runtime files.

## Pitfalls when editing

- The `ERR` trap approves exit, so any unguarded failing command at hook top level silently ends the loop. Guard with `if !` / `||`.
- The runner heredoc in `stop-hook.sh` is unquoted: values are baked in at generation time, and anything meant for runtime must be escaped as `\$`.
- Adding a reviewer touches the reviewer `case` blocks in `stop-hook.sh`, `commands/review-loop.md`, `setup-review-loop.sh`, `resolve-reviewer.sh`, `run-reviewer.sh`, and the generated-file lists duplicated in `cleanup_generated_files` (hook) and `cancel-review-loop.sh`.
- The excludes in `capture-worktree-tree.sh` must match those in `compute_task_diff` in `stop-hook.sh`.
- `REVIEW_LOOP_*_FLAGS` are word-split unquoted in `run-reviewer.sh`, so quoted arguments inside them do not survive.

## Releases

The version lives only in `plugins/review-loop/.claude-plugin/plugin.json`. `.claude-plugin/marketplace.json` has no version field. When releasing, bump `plugin.json` and move the `[Unreleased]` entries in `CHANGELOG.md` together; nothing enforces this.
