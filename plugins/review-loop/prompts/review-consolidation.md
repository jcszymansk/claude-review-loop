---
CONSOLIDATION INSTRUCTIONS (after all agents complete):

1. Enforce the SCOPE BOUNDARY from the base prompt before consolidating. Discard every finding that is pre-existing, unrelated to the original task, outside the current-task changes, or supported only by a general repository audit. This rule applies to every active diff scope, including pull request and local branch scopes. Keep surrounding-code findings only when the current task's change directly creates the reported correctness, security, or regression risk.
2. Collect all findings from all agents
3. Discard any finding that is missing a required field (file, line, severity, explanation, suggested fix); do not report incomplete findings
4. Deduplicate: if multiple agents flagged the same issue, keep the most detailed version
5. Organize all findings by severity (critical first, then high, medium, low)
6. For each finding, include:
   - File path and line number (or directory for structural issues)
   - Severity: critical / high / medium / low
   - Category: which task-related review path found it (Diff, Task Structure, Spec Compliance, Next.js, UX)
   - Explanation: clear description of the task-related problem
   - Suggested fix: concrete, actionable recommendation
7. End with a summary: total issues, breakdown by severity, agents that ran, overall assessment
8. Write the COMPLETE consolidated review to: __REVIEW_FILE__

IMPORTANT: You MUST create the file __REVIEW_FILE__ with the full review.
