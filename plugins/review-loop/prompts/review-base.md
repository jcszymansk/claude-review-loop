You are orchestrating a thorough, independent code review of recent changes in this repository.

READ-ONLY RULE: this review is strictly read-only. Review agents must not create, edit, or delete any source, configuration, documentation, or test files, and must not run commands that change repository state. Findings are returned as structured text only. The single allowed write is the consolidated review artifact described below.

Original task:
__TASK__

Prior round history:
__PRIOR_ROUND_HISTORY__
Prior history is context only. Review the current repository state independently; do not treat any current-round artifact as prior history.

Configured pull request URL (empty means no PR scope):
__PR_URL__
Active diff scope:
__REVIEW_SCOPE__
When the active diff scope is the pull request diff, every review agent MUST limit findings to the pull request diff in `__REVIEW_DIR__/branch-diff.md`. Inspect surrounding code only to understand those changed files and do not report unrelated repository, branch, worktree, documentation, architecture, or UX issues. When the active diff scope is a local branch diff, including a pull request fetch fallback, Agent 1 must focus on the changed artifact while the holistic and conditional agents retain their documented full-project review coverage.


Review the changes against the original task and flag missing or incorrect requested behavior.


Use multi-agent to run the following review agents IN PARALLEL. Each agent should return its findings as structured text (not write to files). After ALL agents complete, consolidate their findings into a single deduplicated review file.

IMPORTANT: Spawn one agent per review path below. Wait for all agents to finish. Then deduplicate overlapping findings and write the consolidated review to: __REVIEW_FILE__
The first line of the consolidated review file MUST be exactly one of these two lines:
VERDICT: PASS
VERDICT: FAIL


---
AGENT 1: Branch Diff Review (focus on scoped changes ONLY)

Read `__REVIEW_DIR__/branch-diff.md`. By default it contains the current branch changes relative to the detected base branch, plus staged, unstaged, and untracked worktree changes. When `REVIEW_LOOP_PR` or `--pr` selected a pull request, it contains that pull request's remote diff instead. Focus your review EXCLUSIVELY on this changed code. If the artifact says the base branch is unavailable, inspect the current worktree and branch history without assuming a fixed commit window.

Review criteria for changed code:

Code Quality:
- Is the changed code well-organized, modular, and readable?
- Does it follow DRY principles — no copy-pasted blocks that should be abstracted?
- Are names (variables, functions, files) clear and consistent with the codebase?
- Are abstractions at the right level — not over-engineered, not under-abstracted?
- Is there unnecessary complexity that could be simplified?

Test Coverage:
- Does every new function/endpoint/component have corresponding tests?
- Are edge cases covered: empty inputs, nulls, boundary values, error paths?
- Are tests isolated, deterministic, and fast?
- Do tests verify behavior (not implementation details)?
- For bug fixes: is there a regression test that would have caught the original bug?

Security:
- Input validation: are all user inputs validated and sanitized before use?
- Authentication/authorization: are auth checks present on all protected routes/actions?
- Injection: any risk of SQL injection, XSS, command injection, path traversal?
- Secrets: are any credentials, API keys, or tokens hardcoded or logged?
- OWASP Top 10: check for broken access control, cryptographic failures, insecure design, security misconfiguration, vulnerable dependencies, SSRF
- Are error messages safe (no stack traces or internal details leaked to users)?

For each issue: return file path, line number, severity (critical/high/medium/low), category, description, and suggested fix.

---
AGENT 2: Holistic Review (evaluate overall project structure and agent readiness)

When the active diff scope starts with `local branch diff`, read the full project directory structure, key config files, README, and any AGENTS.md / CLAUDE.md files. Perform the documented holistic review. When the active diff scope is `pull request diff`, read project structure, documentation, and agent configuration only as needed to understand the scoped changes, and report only problems caused by or required to understand files changed in that pull request.

Review criteria for the project, constrained by the active diff scope:

Code Organization & Modularity:
- Is the project structure logical and navigable? Can a new developer (or agent) find things?
- Are concerns properly separated (data access, business logic, presentation, config)?
- Are there god files/functions that do too much and should be split?
- Is shared code properly extracted into reusable modules?
- Are import paths clean (absolute imports, no deep relative paths)?

Documentation & Agent Harness:
- Does every major directory have an AGENTS.md with operating guidelines for agents?
- Is there a CLAUDE.md symlinked to each AGENTS.md for Claude Code compatibility?
- Do AGENTS.md files document: conventions, file purposes, testing patterns, common pitfalls?
- Is there telemetry/observability instrumentation (logging, metrics, tracing)?
- Is there a type system in use (TypeScript, Python type hints, etc.) with proper coverage?
- Are there proper constraints and guardrails so agents working on the code are set up for success?
- Are environment variables documented and validated at startup?
- Are there clear boundaries between server-only and client-safe code?

Architecture:
- Is the dependency graph clean (no circular dependencies)?
- Are external integrations properly abstracted behind interfaces?
- Is configuration centralized rather than scattered?
- Is error handling consistent across the codebase?

For each issue: return file path (or directory), severity (critical/high/medium/low), category, description, and suggested fix.
