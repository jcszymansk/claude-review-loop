# Changelog

All notable changes to the review-loop plugin are recorded here.

## [Unreleased]

### Added

- Opt-in Claude Code reviewer support through `reviewer = "claude"` and `REVIEW_LOOP_REVIEWER=claude`, using authenticated `claude -p` output without `--bare`.
- Configurable reviewer time limit through `review_timeout` in `.review-loop.toml` or the user config, or `REVIEW_LOOP_REVIEW_TIMEOUT` (default 1800 seconds). A review that runs past it is stopped (TERM, then KILL), its partial output is quarantined as `review-<round>.md.reviewer-error.<n>`, and the hook blocks with a message naming the limit instead of ending silently. Setup rejects values that are not positive integers or exceed the Stop hook timeout minus 60 seconds (#20).

### Changed

- Failed reviews now return findings to the main Claude session instead of starting a nested correction session.
- The Stop hook timeout in `hooks/hooks.json` is now 14400 seconds and acts only as a backstop. Before, a review longer than its 600 seconds made Claude Code cancel the hook and discard its output, so the loop ended with nothing logged. The hook now lowers the review limit so the review ends at least 60 seconds before the backstop, and logs a warning when it does (#20).
- A manual rerun of the generated runner script enforces the same time limit.
- Legacy state files without `review_timeout` resolve the limit when the hook runs, falling back to the default.

## [2.0.0] - 2026-09-07

### Removed

- Gemini reviewer support. Google EOL'd the Gemini CLI and disabled it, so the plugin no longer advertises or invokes it.
- `REVIEW_LOOP_REVIEWER=gemini` and `reviewer = "gemini"` now fail with an explicit `unsupported reviewer 'gemini'` error instead of falling back to another reviewer.
- `REVIEW_LOOP_GEMINI_FLAGS` and all Gemini cleanup paths, prompt files, and runner scripts.

### Changed

- Breaking release: removing a supported reviewer is why this is `2.0.0`, not `1.10.0`. Only `codex` and `cursor` remain valid reviewers, with Codex and Cursor behavior unchanged.
