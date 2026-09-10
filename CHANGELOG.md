# Changelog

All notable changes to the review-loop plugin are recorded here.

## [Unreleased]

### Added

- Opt-in Claude Code reviewer support through `reviewer = "claude"` and `REVIEW_LOOP_REVIEWER=claude`, using authenticated `claude -p` output without `--bare`.

### Changed

- Failed reviews now return findings to the main Claude session instead of starting a nested correction session.

## [2.0.0] - 2026-09-07

### Removed

- Gemini reviewer support. Google EOL'd the Gemini CLI and disabled it, so the plugin no longer advertises or invokes it.
- `REVIEW_LOOP_REVIEWER=gemini` and `reviewer = "gemini"` now fail with an explicit `unsupported reviewer 'gemini'` error instead of falling back to another reviewer.
- `REVIEW_LOOP_GEMINI_FLAGS` and all Gemini cleanup paths, prompt files, and runner scripts.

### Changed

- Breaking release: removing a supported reviewer is why this is `2.0.0`, not `1.10.0`. Only `codex` and `cursor` remain valid reviewers, with Codex and Cursor behavior unchanged.
