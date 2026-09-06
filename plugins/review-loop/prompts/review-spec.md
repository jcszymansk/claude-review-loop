---
AGENT (SPEC): Specification and Plan Compliance Review

An explicit specification or plan exists in this repository. Read every detected file listed below before reviewing:

__SPEC_FILES__

Apply the SCOPE BOUNDARY from the base prompt. Review only whether the current task's changes satisfy requirements that apply to this task. Compare the implementation with the requirements, acceptance criteria, intended user-facing behavior, inputs, outputs, error handling, and documented edge cases. Check whether task-relevant plan steps are complete and whether task-relevant implementation deviations leave the result inconsistent with the specification.

Do not report pre-existing specification violations, missing coverage, or unrelated plan work that the current task did not change or explicitly undertake. If a requirement is outside the original task, omit it even when the repository does not satisfy it.

Check whether tests cover the documented acceptance criteria and important edge cases for the current task. Report missing coverage only when it protects a specific requirement changed or added by this task.

For each issue, return the file path and line number (the closest line for task-level issues), severity (critical/high/medium/low), category (Spec Compliance), the unmet requirement, a clear explanation, and a concrete suggested fix.
