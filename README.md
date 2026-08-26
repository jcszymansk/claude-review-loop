# review-loop

A Claude Code plugin that adds an automated code review loop to your workflow.

## What it does

When you use `/review-loop`, the plugin creates a two-phase lifecycle:

1. **Task phase**: You describe a task, setup initializes `summary-0.md` with task context, and Claude replaces it with the implementation summary
2. **Review phase**: The stop hook prepares a runner for the selected reviewer and blocks exit. Claude runs the reviewer directly, reads `review-1.md`, addresses the findings, and writes `summary-1.md`. A missing or malformed verdict is treated as `FAIL`.


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
2. Blocks Claude's exit with instructions to run the review
3. Claude runs the generated reviewer script and sees its output
4. The reviewer writes findings to `reviews/<id>/review-1.md`
5. Claude reads the review and addresses the findings. A missing or malformed verdict is treated as `FAIL` and keeps the loop blocked; after a valid verdict, Claude writes `summary-1.md` and stops


### Cancel a review loop

```
/cancel-review
```

## How it works

The plugin uses a **Stop hook** — Claude Code's mechanism for intercepting agent exit. When Claude tries to stop:

1. The hook reads the JSON state file (`.claude/review-loop.local.json`)
2. If in `task` phase: writes a numbered reviewer runner and prompt file, transitions to `addressing`, and blocks exit with instructions for Claude to run the review
3. If in `addressing` phase: verifies the current numbered review has a valid verdict. Missing or malformed verdicts are treated as `FAIL` and keep the loop blocked; a valid review then allows exit and cleans up

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

The stop hook timeout is set to 30 seconds in `hooks/hooks.json`. The hook itself is fast (it only writes files and returns a block decision); the selected reviewer runs separately via Claude's Bash tool.

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
