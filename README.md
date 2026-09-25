# review-loop

A Claude Code plugin that adds an automated code review loop to your workflow.

## What it does

When you use `/review-loop`, the plugin creates a bounded review lifecycle:

1. **Task phase**: you describe a task, setup initializes `summary-0.md` with task context, and Claude replaces it with the implementation summary
2. **Review phase**: the Stop hook runs the configured reviewer. On `VERDICT: FAIL`, it returns the findings to the same Claude session, which verifies and addresses them before writing the correction summary; the next stop reruns the reviewer. The loop stops on `VERDICT: PASS` or the maximum round count. A missing or malformed verdict keeps the loop from being accepted. `/cancel-review` stops active reviewer processes and preserves the review history.



A Claude reviewer is available as an opt-in same-vendor fallback. It uses
Claude Code's authenticated `claude -p` mode, so it provides less independent
review than Codex or Cursor.
Each task receives a reviewer opinion before exit, and you can watch the review
run in real time.

<img width="2284" height="1959" alt="memelord_meme_2026-02-22 (3)" src="https://github.com/user-attachments/assets/75af1351-47e6-4b70-a50a-9b3311773be7" />


## Review coverage

| **Diff Review** | Yes | Current-task changes in the selected branch or GitHub/Gitea pull request diff, plus task-relevant code quality, test coverage, and security (OWASP top 10) |
| **Task-Related Structure Review** | Yes | Project structure, documentation, AGENTS.md, agent harness, and architecture only when changed by or required for the current task |
| **Spec Compliance Review** | If `SPEC.md`, `spec.md`, `SPECIFICATION.md`, `specification.md`, `PLAN.md`, `plan.md`, or matching files under `docs/` exists | Documented requirements, acceptance criteria, plan completion, and requirement-specific test coverage for the current task |
| **Next.js Review** | If `next.config.*` or `"next"` in `package.json` | Task-changed App Router, Server Components, caching, Server Actions, React performance |
| **UX Review** | If `app/`, `pages/`, `public/`, or `index.html` exists | Browser E2E, accessibility, and responsive behavior for task-changed UI |

Each loop stores its branch and task diff artifacts and conversation history together under `reviews/<id>/`: `branch-diff.md`, `task-diff.md`, `summary-0.md`, `review-1.md`, `summary-1.md`, and numbered files for later rounds.

Set `REVIEW_LOOP_PR` to a GitHub or Gitea pull request URL to review that
pull request instead of the local branch diff. The setup script also accepts
`--pr <url>`. `GITHUB_TOKEN` and `GITEA_TOKEN` provide optional private-repository
authentication. If fetching the remote diff fails, the artifact records a
warning and the hook falls back to the local branch diff.


## Requirements

- One reviewer CLI: [Codex](https://github.com/openai/codex), [Cursor Agent](https://docs.cursor.com/en/cli), or Claude Code
- Claude Code authentication — required only for `reviewer = "claude"`; run `claude auth login` when using subscription OAuth
- `jq` — `brew install jq` (macOS) / `apt install jq` (Linux)
- `curl` — required only for GitHub or Gitea pull request scoping


### Codex multi-agent

When Codex is selected, the `/review-loop` command automatically enables [Codex multi-agent](https://developers.openai.com/codex/multi-agent/) in `~/.codex/config.toml` on first use. Cursor does not need Codex configuration.


To set it up manually instead:

```toml
# ~/.codex/config.toml
[features]
multi_agent = true
```

## Installation

From the CLI:

```bash
claude plugin marketplace add jcszymansk/claude-review-loop
claude plugin install review-loop@hamel-review
```

Or from within a Claude Code session:

```
/plugin marketplace add jcszymansk/claude-review-loop
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
2. Runs the reviewer for the current round, recording its output in `.claude/review-loop.log`
3. If the verdict is `VERDICT: FAIL`, returns the findings to the same Claude session for verification and correction
4. After the correction summary is complete, reruns the reviewer for the next round
5. Keeps each numbered review and correction summary in `reviews/<id>/`
6. Stops on `VERDICT: PASS`, or reports `MAX_ROUNDS_REACHED` when repeated failures exhaust the configured limit. A missing or malformed verdict keeps the loop blocked for correction.


### Cancel a review loop

```
/cancel-review
```

Cancellation stops the active reviewer process and its children. The
`reviews/<id>/` history remains on disk.

## How it works
The plugin uses a **Stop hook** — Claude Code's mechanism for intercepting agent exit. When Claude tries to stop:

1. The hook reads the JSON state file (`.claude/review-loop.local.json`)
2. If in `task` phase: renders the review prompt, writes a numbered reviewer runner script, runs the configured reviewer for the current round, and transitions to `addressing`
3. If the review verdict is `FAIL`, the hook returns the findings to the same Claude session
4. After that session writes the correction summary, the hook advances the round and reruns the reviewer automatically
5. A `PASS` allows exit after its correction summary is complete; repeated failures end with `MAX_ROUNDS_REACHED` and preserve the review history

The verdict is the first line of each review artifact and must be exactly `VERDICT: PASS` or `VERDICT: FAIL`; an absent or malformed verdict counts as `FAIL` and blocks exit until the review is fixed or rerun. A reviewer that exits non-zero or runs past its time limit keeps its output as a `review-<round>.md.reviewer-error.<n>` quarantine file so a failed review can never be accepted. A missing review artifact prompts one rerun of the generated runner script, which Claude runs in the background; if Claude stops while it is still running, the hook waits for it within its time budget. After that the loop fails open rather than trapping you. On any internal error the hook approves exit (fail-open), and every such approve tells you why in a message that points to `.claude/review-loop.log`, and Claude reviewer processes run with `REVIEW_LOOP_REVIEWER_PROCESS=1` so they cannot recursively start another review.

State is tracked in `.claude/review-loop.local.json` (add to `.gitignore`) with `active`, `reviewer`, `task`, `round`, `max_rounds`, `review_timeout`, `phase`, `review_id`, `started_at`, and the task-start baseline tree, plus an optional validated `pr_url`. Per-round runtime files under `.claude/` are `review-loop-<reviewer>-prompt.txt` (the rendered prompt) and `review-loop-run-<reviewer>.sh` (the runner script), with `review-loop-child.pid`, `review-loop-retries`, and `review-loop-timed-out` (written by the runner when the review limit passes) used during execution; all are removed when the loop ends. Each loop gets a directory under `reviews/` containing `branch-diff.md`, `task-diff.md`, `summary-0.md`, `review-1.md`, `summary-1.md`, and later numbered review/summary pairs, kept for every terminal outcome.

## File structure

```
claude-review-loop/
├── .claude-plugin/
│   └── marketplace.json           # Marketplace manifest
├── .github/workflows/
│   └── ci.yml                     # shellcheck + test suite
├── CHANGELOG.md                   # Release history
├── README.md
├── ROADMAP.md                     # Task roadmap
└── plugins/review-loop/
    ├── .claude-plugin/
    │   └── plugin.json            # Plugin manifest
    ├── commands/
    │   ├── review-loop.md         # /review-loop slash command
    │   └── cancel-review.md       # /cancel-review slash command
    ├── hooks/
    │   ├── hooks.json             # Stop hook registration (14400s backstop timeout)
    │   └── stop-hook.sh           # Core lifecycle engine
    ├── scripts/
    │   ├── setup-review-loop.sh   # Argument parsing, state file creation
    │   ├── capture-worktree-tree.sh # Capture the task-start worktree tree
    │   ├── resolve-reviewer.sh    # Reviewer selection and config precedence
    │   ├── resolve-max-rounds.sh  # Round-limit selection and validation
    │   ├── resolve-review-timeout.sh # Reviewer time-limit selection and validation
    │   ├── read-hook-timeout.sh   # Read the Stop hook timeout from hooks.json
    │   ├── run-reviewer.sh        # Codex, Cursor, and Claude dispatch
    │   ├── quarantine-review-artifact.sh # Move failed reviews to reviewer-error files
    │   ├── stop-process-tree.sh   # TERM, then KILL, a process tree
    │   ├── resolve-pr-url.sh      # Validate and parse pull request URLs
    │   ├── cancel-review-loop.sh  # Stop active loop child processes
    │   └── ensure-codex-config.sh # Preserve Codex multi-agent setup
    ├── prompts/
    │   ├── review-base.md              # Shared reviewer instructions
    │   ├── review-spec.md              # Conditional specification and plan review
    │   ├── review-nextjs.md            # Conditional Next.js review instructions
    │   ├── review-ux.md                # Conditional browser UX review instructions
    │   ├── review-consolidation.md     # Finding consolidation instructions
    │   ├── addressing-review.md        # Review handoff message
    │   ├── addressing-summary.md       # Incomplete summary message
    │   ├── addressing-verdict.md       # Malformed verdict message
    │   └── addressing-missing-review.md # Missing review message
    ├── tests/                     # Shell test suite, one file per lifecycle area
    ├── AGENTS.md                  # Agent operating guidelines
    └── CLAUDE.md                  # Symlink to AGENTS.md
```

## Configuration

The hook runs the selected reviewer directly and records its output in `.claude/review-loop.log`; stdout remains reserved for the hook's JSON decision.

Each review run is limited by `review_timeout` (default 1800 seconds). When the limit passes, the runner stops the reviewer and its child processes (TERM, then KILL after 5 seconds), logs `ERROR: <reviewer> review timed out after <n>s (limit <n>s)`, quarantines any partial output as `review-<round>.md.reviewer-error.<n>`, and exits with status 124. The hook then blocks with a message that names the limit, and Claude can rerun the generated script once through the retry gate. The rerun enforces the configured limit (without the cap described below). Claude runs it with the Bash tool's `run_in_background` option, so the tool's own time limit does not cut it off. If the rerun also times out, the loop ends and the message says so.

Claude Code cancels a Stop hook that exceeds the `timeout` in `hooks/hooks.json` and discards its output, so the loop would end without a message. That value can't be configured, so it is set to 14400 seconds as a backstop. At run time the hook reads it and lowers the review limit so the review finishes at least 60 seconds before the backstop, counting the time already spent in the current Stop event; the log records a warning whenever this lowers the configured value. Pull request diff downloads are limited to 60 seconds for the same reason.

### Reviewer, round limit, and time limit

The reviewer is resolved in this order:

1. `REVIEW_LOOP_REVIEWER`, when set
2. `.review-loop.toml` in the project root
3. `${XDG_CONFIG_HOME:-$HOME/.config}/review-loop/config.toml`
4. `codex`

The round limit is resolved in this order:

1. `REVIEW_LOOP_MAX_ROUNDS`, when set
2. `max_rounds` in `.review-loop.toml`
3. `max_rounds` in `${XDG_CONFIG_HOME:-$HOME/.config}/review-loop/config.toml`
4. `3`

The reviewer time limit is resolved in this order:

1. `REVIEW_LOOP_REVIEW_TIMEOUT`, when set
2. `review_timeout` in `.review-loop.toml`
3. `review_timeout` in `${XDG_CONFIG_HOME:-$HOME/.config}/review-loop/config.toml`
4. `1800`

Project and user configuration files use this format:

```toml
reviewer = "cursor"
max_rounds = 5
review_timeout = 2700
```

Supported reviewers are `codex`, `cursor`, and opt-in `claude`. Claude
reviewer runs use `claude -p` without `--bare`, preserving access to Claude
Code OAuth credentials. Because the implementer and reviewer are both Claude
Code, this mode has reduced vendor independence.

`max_rounds` must be an integer
from 1 to 10. `review_timeout` is a number of seconds: a positive integer no
larger than the Stop hook timeout in `hooks/hooks.json` minus 60 (14340 with
the shipped 14400). Setup stores both values in the loop state, so changing
them affects the next loop, not the running one. Malformed reviewer
configuration, an invalid round limit, or an invalid time limit causes setup
to fail instead of silently falling back to another source.

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `REVIEW_LOOP_REVIEWER` | `codex` | Overrides project and user reviewer configuration. Supported values: `codex`, `cursor`, `claude`. |
| `REVIEW_LOOP_MAX_ROUNDS` | `3` | Maximum review rounds, from 1 to 10. Overrides project and user configuration. |
| `REVIEW_LOOP_REVIEW_TIMEOUT` | `1800` | Reviewer time limit in seconds, at most the `hooks/hooks.json` Stop hook timeout minus 60. Overrides project and user configuration. |
| `REVIEW_LOOP_PR` | unset | Optional GitHub or Gitea pull request URL; scopes the review diff to that pull request. |
| `GITHUB_TOKEN` | unset | Optional token used to fetch private GitHub pull request diffs. |
| `GITEA_TOKEN` | unset | Optional token used to fetch private Gitea pull request diffs. |
| `REVIEW_LOOP_CODEX_FLAGS` | `--dangerously-bypass-approvals-and-sandbox` | Flags passed to `codex`. Set to `--sandbox workspace-write` for safer sandboxed reviews. |
| `REVIEW_LOOP_CURSOR_FLAGS` | `--output-format text` | Override the flags passed to `cursor-agent` after its non-interactive prompt. |
| `REVIEW_LOOP_CLAUDE_FLAGS` | `--permission-mode acceptEdits` | Override flags passed to `claude -p`; do not add `--bare` if subscription OAuth is required. |
| `REVIEW_LOOP_DEBUG` | unset | Set to `1` to append reviewer metadata and raw provider stdout/stderr to `.claude/review-loop-debug.log`. |

### Telemetry

Execution logs are written to `.claude/review-loop.log` with timestamps,
reviewer exit codes, and elapsed times. For intermittent reviewer failures,
start Claude with `REVIEW_LOOP_DEBUG=1`; the runner also appends reviewer
invocation metadata, CLI path, and raw provider stdout/stderr to
`.claude/review-loop-debug.log`. Both files survive review-loop cleanup.
Debug output can contain review content, so keep it local.

## Credits

Inspired by the [Ralph Wiggum plugin](https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum) and [Ryan Carson's compound engineering loop](https://x.com/ryancarson/article/2016520542723924279).
