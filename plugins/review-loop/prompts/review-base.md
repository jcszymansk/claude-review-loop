You are orchestrating a thorough, independent review of the requested task only.

READ-ONLY RULE: this review is strictly read-only. Review agents must not create, edit, or delete any source, configuration, documentation, or test files, and must not run commands that change repository state. Findings are returned as structured text only. The single allowed write is the consolidated review artifact described below.

SCOPE BOUNDARY (highest priority):
This is a task review, not a general repository audit. Review only work performed for the original task during this review loop.

Report a finding only when at least one of these is true:
- The current task changed or added the code with the problem.
- The original task explicitly requires behavior that the current task failed to implement.
- The current task's change introduced a concrete correctness, security, or regression risk in surrounding code.

Do not report:
- Pre-existing issues, even when they are valid or severe.
- Problems in unchanged code that the task did not introduce.
- Issues from earlier branch or pull request work outside the current task.
- General code quality, architecture, documentation, telemetry, type coverage, or UX gaps unrelated to the task.
- Improvements that are useful but not required to complete the original task.

Use surrounding code only to understand the current task's changes and verify their consequences. If a finding cannot be tied to both the original task and the active changed artifact, omit it. Never expand the review into a whole-project audit because a review section asks for holistic, architectural, framework, or UX checks.

Original task:
__TASK__

Prior round history:
__PRIOR_ROUND_HISTORY__
Prior history is context only. Review the current repository state independently; do not treat any current-round artifact as prior history.

Configured pull request URL (empty means no PR scope):
__PR_URL__

Active diff scope:
__REVIEW_SCOPE__
Task-start diff artifact (authoritative when present):
__TASK_DIFF_FILE__
Use the task-start diff artifact as the authoritative list of work performed after this review loop started. The active diff artifact may include earlier branch or pull request work and is supplemental context only. If the task-start artifact is unavailable, apply the SCOPE BOUNDARY conservatively and do not assume every active-diff hunk belongs to this task.

Review the changes against the original task and flag missing or incorrect requested behavior.

ACTIONABLE FINDINGS REQUIREMENT: every finding MUST include all of these fields:

- File path and line number (for structural or project-wide issues: the closest affected file and line, or the directory)
- Severity: critical / high / medium / low
- Explanation of the problem
- Suggested fix

A finding missing any required field is not actionable and MUST NOT be reported by any agent, and MUST NOT appear in the consolidated review.

Use multi-agent to run the following review agents IN PARALLEL. Each agent must apply the SCOPE BOUNDARY above and return only task-related findings. Each agent should return its findings as structured text (not write to files). After ALL agents complete, consolidate their findings into a single deduplicated review file.

IMPORTANT: Spawn one agent per review path below. Wait for all agents to finish. Then deduplicate overlapping findings and write the consolidated review to: __REVIEW_FILE__
The first line of the consolidated review file MUST be exactly one of these two lines:
VERDICT: PASS
VERDICT: FAIL


---
AGENT 1: Branch Diff Review (focus on current-task changes ONLY)

Read `__TASK_DIFF_FILE__` first when it exists; it is the authoritative diff for work performed after this review loop started. Read `__REVIEW_DIR__/branch-diff.md` only as supplemental context for the selected branch or pull request scope. The branch or pull request artifact may include work that predates this task. Use the original task and prior implementation summary to identify task intent, and focus findings EXCLUSIVELY on task-start changes. If the task-start artifact is unavailable, inspect the current worktree and branch history conservatively without assuming a fixed commit window.

Review criteria for current-task code:

Code Quality:
- Is the task's changed code readable and consistent enough to implement the requested behavior?
- Did the task introduce unnecessary duplication or an abstraction that creates a concrete maintenance problem?

Test Coverage:
- Does the task's changed behavior have the tests needed for its requested contract?
- Are task-relevant edge cases and error paths covered?
- For bug fixes: is there a regression test that would have caught the original bug?

Security:
- Did the task introduce input validation, authentication, injection, secret-handling, or OWASP Top 10 risks?
- Are error messages from the task's changed paths safe?

For each issue: return file path, line number, severity (critical/high/medium/low), category, explanation, and suggested fix.

---
AGENT 2: Task-Related Structure Review

Review project structure, documentation, agent configuration, and architecture only where they were changed by the current task or are directly required for the requested behavior. Do not perform a general inventory of missing AGENTS.md files, telemetry, type coverage, environment-variable documentation, architectural patterns, or pre-existing code quality.
Task-Related Architecture:

Check only task-linked concerns:
- Does the task's changed code fit the existing boundaries needed for the requested behavior?
- Did the task create a concrete dependency, configuration, error-handling, or layering problem?
- Are task-required documentation, configuration, or agent instructions missing?
- Did the task introduce a concrete maintainability problem in the changed area?

If no task-related structure finding exists, return no finding for this review path.

For each issue: return file path and line number (or directory for structural issues), severity (critical/high/medium/low), category, explanation, and suggested fix.
