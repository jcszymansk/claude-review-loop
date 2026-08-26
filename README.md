# review-loop

A Claude Code plugin that adds an automated code review loop to your workflow.

## What it does

When you use `/review-loop`, the plugin creates a two-phase lifecycle:

1. **Task phase**: You describe a task, setup initializes `summary-0.md` with task context, and Claude replaces it with the implementation summary
2. **Review phase**: The Stop hook runs the configured reviewer. On `VERDICT: FAIL`, it starts a fresh interactive Claude correction session, then blocks the original session so the reviewer can be run again. A `VERDICT: PASS`, missing verdict, or malformed verdict keeps the loop from being accepted.



The result: every task gets an independent second opinion before you accept the changes, and you can watch the review happen in real time.

<img width="2284" height="1959" alt="memelord_meme_2026-02-22 (3)" src="https://github.com/user-attachments/assets/75af1351-47e6-4b70-a50a-9b3311773be7" />


## Review coverage

The plugin runs one of `codex`, `gemini`, or `cursor-agent` for the review. Codex still uses its configured parallel sub-agents; Gemini and Cursor receive the same review prompt as a single headless invocation.


| Agent | Always runs? | Focus |
|-------|-------------|-------|
| **Diff Review** | Yes | `git diff` — code quality, test coverage, security (OWASP top 10) |
| **Holistic Review** | Yes | Project structure, documentation, AGENTS.md, agent harness, architecture |
| **Next.js Review** | If `next.config.*` or `"next"` in `package.json` | App Router, Server Components, caching, Server Actions, React performance |
| **UX Review** | If `app/`, `pages/`, `public/`, or `index.html` exists | Browser E2E via [agent-browser](https://agent-browser.dev/), accessibility, responsive design |

Each loop stores its conversation artifacts together under `reviews/<id>/`: `summary-0.md`, `review-1.md`, `summary-1.md`, and numbered files for later rounds.


## Requirements

- One reviewer CLI: [Codex](https://github.com/openai/codex), [Gemini CLI](https://github.com/google-gemini/gemini-cli), or [Cursor Agent](https://docs.cursor.com/en/cli)
- `jq` — `brew install jq` (macOS) / `apt install jq` (Linux)


### Codex multi-agent

When Codex is selected, the `/review-loop` command automatically enables [Codex multi-agent](https://developers.openai.com/codex/multi-agent/) in `~/.codex/config.toml` on first use. Gemini and Cursor do not need Codex configuration.


To set it up manually instead:

```toml
# ~/.codex/config.toml
[features]
multi_agent = true
```

## Installation

From the CLI:

```bash
claude plugin marketplace add hamelsmu/claude-review-loop
claude plugin install review-loop@hamel-review
```

Or from within a Claude Code session:

```
/plugin marketplace add hamelsmu/claude-review-loop
/plugin install review-loop@hamel-review
```


## Updating

```bash
claude plugin marketplace update hamel-review
claude plugin update review-loop@hamel-review
```

## Usage

### Start a review loop

```
/review-loop Add user authentication with JWT tokens and test coverage
```

Claude will implement the task. Setup initializes `reviews/<id>/summary-0.md` with task context; before the first stop, Claude replaces it with an implementation summary. The stop hook then:
1. Prepares the selected reviewer runner and prompt file
2. Runs the reviewer for round 1, recording its output in `.claude/review-loop.log`
3. If the verdict is `VERDICT: FAIL`, starts a fresh interactive Claude correction session
4. Blocks the original Claude session so it can inspect the correction and rerun the reviewer
5. The reviewer writes findings to `reviews/<id>/review-1.md`; if it returns review text on stdout instead, the runner captures that output when the artifact is missing
6. A `VERDICT: FAIL`, missing verdict, or malformed verdict keeps the loop blocked. A `VERDICT: PASS` allows exit only after Claude writes a non-empty `summary-1.md` containing `## Fixes`, `## Skipped findings`, and `## Quality gates`, with verification results marked `PASS`, `FAIL`, or `NOT RUN`.


### Cancel a review loop

```
/cancel-review
```

## How it works
The plugin uses a **Stop hook** — Claude Code's mechanism for intercepting agent exit. When Claude tries to stop:

1. The hook reads the JSON state file (`.claude/review-loop.local.json`)
2. If in `task` phase: writes a numbered reviewer runner and prompt file, runs the configured reviewer for the current round, and transitions to `addressing`
3. If the review verdict is `FAIL`, the hook starts one fresh interactive Claude correction session with the review context
4. The hook blocks the original Claude session. It verifies the current numbered review has a valid `VERDICT: PASS` and a complete correction summary; a `FAIL`, missing verdict, malformed verdict, or incomplete summary keeps the loop blocked until corrected.

The hook removes runtime state and generated runner files only. It never removes `reviews/<id>/`, so summaries and review output remain available after cleanup. `/cancel-review` follows the same rule; future round-limit termination must preserve the directory as well.

State is tracked in `.claude/review-loop.local.json` (add to `.gitignore`) with `active`, `reviewer`, `task`, `round`, `max_rounds`, `phase`, `review_id`, and `started_at`. Each loop gets a directory under `reviews/` containing `summary-0.md`, `review-1.md`, `summary-1.md`, and later numbered review/summary pairs.

## File structure

```
claude-review-loop/
├── .claude-plugin/
│   └── plugin.json           # Plugin manifest
├── commands/
│   ├── review-loop.md        # /review-loop slash command
│   └── cancel-review.md      # /cancel-review slash command
├── hooks/
│   ├── hooks.json            # Stop hook registration (30s timeout)
│   └── stop-hook.sh          # Core lifecycle engine
├── scripts/
│   ├── setup-review-loop.sh  # Argument parsing, state file creation
│   ├── resolve-reviewer.sh   # Reviewer selection and config precedence
│   ├── run-reviewer.sh       # Codex, Gemini, and Cursor dispatch
│   └── ensure-codex-config.sh # Preserve Codex multi-agent setup
├── AGENTS.md                  # Agent operating guidelines
├── CLAUDE.md                  # Symlink to AGENTS.md
└── README.md
```

## Configuration

The stop hook timeout is set to 600 seconds in `hooks/hooks.json` because reviewer CLIs can take several minutes. The hook runs the selected reviewer directly and records its output in `.claude/review-loop.log`; stdout remains reserved for the hook's JSON decision.

### Reviewer selection

The reviewer is resolved in this order:

1. `REVIEW_LOOP_REVIEWER`, when set
2. `.review-loop.toml` in the project root
3. `${XDG_CONFIG_HOME:-$HOME/.config}/review-loop/config.toml`
4. `codex`

Project and user configuration files use this format:

```toml
reviewer = "cursor"
```

Supported reviewers are `codex`, `gemini`, and `cursor`.
Malformed configuration causes reviewer resolution to fail instead of silently falling back to another source.

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `REVIEW_LOOP_REVIEWER` | `codex` | Overrides project and user reviewer configuration. |
| `REVIEW_LOOP_CODEX_FLAGS` | `--dangerously-bypass-approvals-and-sandbox` | Flags passed to `codex`. Set to `--sandbox workspace-write` for safer sandboxed reviews. |
| `REVIEW_LOOP_GEMINI_FLAGS` | `--output-format text` | Override the flags passed to `gemini` after its non-interactive prompt. |
| `REVIEW_LOOP_CURSOR_FLAGS` | `--output-format text` | Override the flags passed to `cursor-agent` after its non-interactive prompt. |

### Telemetry

Execution logs are written to `.claude/review-loop.log` with timestamps, reviewer exit codes, and elapsed times. This file is gitignored.

## Credits

Inspired by the [Ralph Wiggum plugin](https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum) and [Ryan Carson's compound engineering loop](https://x.com/ryancarson/article/2016520542723924279).
