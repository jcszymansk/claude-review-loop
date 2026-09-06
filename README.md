# review-loop

A Claude Code plugin that adds an automated code review loop to your workflow.

## What it does

When you use `/review-loop`, the plugin creates a bounded review lifecycle:

1. **Task phase**: you describe a task, setup initializes `summary-0.md` with task context, and Claude replaces it with the implementation summary
2. **Review phase**: the Stop hook runs the configured reviewer. On `VERDICT: FAIL`, it starts a fresh interactive Claude correction session, then reruns the reviewer for the next round after the correction summary is complete. The loop stops on `VERDICT: PASS` or the maximum round count. A missing or malformed verdict keeps the loop from being accepted. `/cancel-review` stops active reviewer or correction-session processes and preserves the review history.



The result: every task gets an independent second opinion before you accept the changes, and you can watch the review happen in real time.

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

- One reviewer CLI: [Codex](https://github.com/openai/codex), [Gemini CLI](https://github.com/google-gemini/gemini-cli), or [Cursor Agent](https://docs.cursor.com/en/cli)
- The Claude Code CLI (`claude`) — required for the fresh correction session that starts when a review returns `FAIL`
- `jq` — `brew install jq` (macOS) / `apt install jq` (Linux)
- `curl` — required only for GitHub or Gitea pull request scoping


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
3. If the verdict is `VERDICT: FAIL`, starts a fresh interactive Claude correction session
4. After the correction summary is complete, reruns the reviewer for the next round
5. Keeps each numbered review and correction summary in `reviews/<id>/`
6. Stops on `VERDICT: PASS`, or reports `MAX_ROUNDS_REACHED` when repeated failures exhaust the configured limit. A missing or malformed verdict keeps the loop blocked for correction.


### Cancel a review loop

```
/cancel-review
```

Cancellation stops the active reviewer or correction-session process and its
children. The `reviews/<id>/` history remains on disk.

## How it works
The plugin uses a **Stop hook** — Claude Code's mechanism for intercepting agent exit. When Claude tries to stop:

1. The hook reads the JSON state file (`.claude/review-loop.local.json`)
2. If in `task` phase: renders the review prompt, writes a numbered reviewer runner script, runs the configured reviewer for the current round, and transitions to `addressing`
3. If the review verdict is `FAIL`, the hook starts one fresh interactive Claude correction session with the review context
4. After the correction summary is complete, the hook advances the round and reruns the reviewer automatically
5. A `PASS` allows exit after its correction summary is complete; repeated failures end with `MAX_ROUNDS_REACHED` and preserve the review history

The verdict is the first line of each review artifact and must be exactly `VERDICT: PASS` or `VERDICT: FAIL`; an absent or malformed verdict counts as `FAIL` and blocks exit until the review is fixed or rerun. A reviewer that exits non-zero keeps its output as a `review-<round>.md.reviewer-error.<n>` quarantine file so a failed review can never be accepted. A missing review artifact prompts one rerun of the generated runner script, then the loop fails open rather than trapping you. On any internal error the hook approves exit (fail-open), and correction sessions run with `REVIEW_LOOP_CORRECTION=1` so they cannot recursively start another review.

State is tracked in `.claude/review-loop.local.json` (add to `.gitignore`) with `active`, `reviewer`, `task`, `round`, `max_rounds`, `phase`, `review_id`, `started_at`, and the task-start baseline tree, plus an optional validated `pr_url`. Per-round runtime files under `.claude/` are `review-loop-<reviewer>-prompt.txt` (the rendered prompt) and `review-loop-run-<reviewer>.sh` (the runner script), with `review-loop-child.pid` and `review-loop-retries` used during execution; all are removed when the loop ends. Each loop gets a directory under `reviews/` containing `branch-diff.md`, `task-diff.md`, `summary-0.md`, `review-1.md`, `summary-1.md`, and later numbered review/summary pairs, kept for every terminal outcome.

## File structure

```
claude-review-loop/
├── .claude-plugin/
│   └── marketplace.json           # Marketplace manifest
├── .github/workflows/
│   └── ci.yml                     # shellcheck + test suite
├── README.md
├── ROADMAP.md                     # Task roadmap
└── plugins/review-loop/
    ├── .claude-plugin/
    │   └── plugin.json            # Plugin manifest
    ├── commands/
    │   ├── review-loop.md         # /review-loop slash command
    │   └── cancel-review.md       # /cancel-review slash command
    ├── hooks/
    │   ├── hooks.json             # Stop hook registration (600s timeout)
    │   └── stop-hook.sh           # Core lifecycle engine
    ├── scripts/
    │   ├── setup-review-loop.sh   # Argument parsing, state file creation
    │   ├── capture-worktree-tree.sh # Capture the task-start worktree tree
    │   ├── resolve-reviewer.sh    # Reviewer selection and config precedence
    │   ├── resolve-max-rounds.sh  # Round-limit selection and validation
    │   ├── run-reviewer.sh        # Codex, Gemini, and Cursor dispatch
    │   ├── resolve-pr-url.sh      # Validate and parse pull request URLs
    │   ├── cancel-review-loop.sh  # Stop active loop child processes
    │   └── ensure-codex-config.sh # Preserve Codex multi-agent setup
    ├── prompts/
    │   ├── review-base.md              # Shared reviewer instructions
    │   ├── review-spec.md              # Conditional specification and plan review
    │   ├── review-nextjs.md            # Conditional Next.js review instructions
    │   ├── review-ux.md                # Conditional browser UX review instructions
    │   ├── review-consolidation.md     # Finding consolidation instructions
    │   ├── correction-session.md       # Claude correction-session instructions
    │   ├── addressing-correction.md    # Correction handoff message
    │   ├── addressing-review.md        # Review handoff message
    │   ├── addressing-summary.md       # Incomplete summary message
    │   ├── addressing-verdict.md       # Malformed verdict message
    │   └── addressing-missing-review.md # Missing review message
    ├── tests/                     # Shell test suite, one file per lifecycle area
    ├── AGENTS.md                  # Agent operating guidelines
    └── CLAUDE.md                  # Symlink to AGENTS.md
```

## Configuration

The stop hook timeout is set to 600 seconds in `hooks/hooks.json` because reviewer CLIs can take several minutes. The hook runs the selected reviewer directly and records its output in `.claude/review-loop.log`; stdout remains reserved for the hook's JSON decision.

### Reviewer and round limit

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

Project and user configuration files use this format:

```toml
reviewer = "cursor"
max_rounds = 5
```

Supported reviewers are `codex`, `gemini`, and `cursor`. `max_rounds` must be
an integer from 1 to 10. Malformed reviewer configuration or an invalid round
limit causes setup to fail instead of silently falling back to another source.

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `REVIEW_LOOP_REVIEWER` | `codex` | Overrides project and user reviewer configuration. |
| `REVIEW_LOOP_MAX_ROUNDS` | `3` | Maximum review rounds, from 1 to 10. Overrides project and user configuration. |
| `REVIEW_LOOP_PR` | unset | Optional GitHub or Gitea pull request URL; scopes the review diff to that pull request. |
| `GITHUB_TOKEN` | unset | Optional token used to fetch private GitHub pull request diffs. |
| `GITEA_TOKEN` | unset | Optional token used to fetch private Gitea pull request diffs. |
| `REVIEW_LOOP_CODEX_FLAGS` | `--dangerously-bypass-approvals-and-sandbox` | Flags passed to `codex`. Set to `--sandbox workspace-write` for safer sandboxed reviews. |
| `REVIEW_LOOP_GEMINI_FLAGS` | `--output-format text` | Override the flags passed to `gemini` after its non-interactive prompt. |
| `REVIEW_LOOP_CURSOR_FLAGS` | `--output-format text` | Override the flags passed to `cursor-agent` after its non-interactive prompt. |
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
