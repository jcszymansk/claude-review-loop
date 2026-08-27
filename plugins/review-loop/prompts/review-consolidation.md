---
CONSOLIDATION INSTRUCTIONS (after all agents complete):

1. Enforce the active diff scope before consolidating. The active scope is `__REVIEW_SCOPE__`. If it is the pull request diff, discard findings unrelated to files or behavior in that diff. If it is a local branch diff, including a pull request fetch fallback, treat the local branch artifact as the active scope. Keep surrounding-code findings only when they are required to explain or fix a scoped change.
2. Collect all findings from all agents
3. Deduplicate: if multiple agents flagged the same issue, keep the most detailed version
4. Organize all findings by severity (critical first, then high, medium, low)
5. For each finding, include:
   - File path and line number (or directory for structural issues)
   - Severity: critical / high / medium / low
   - Category: which review path found it (Diff, Holistic, Next.js, UX)
   - Description: clear explanation
   - Suggested fix: concrete, actionable recommendation
6. End with a summary: total issues, breakdown by severity, agents that ran, overall assessment
7. Write the COMPLETE consolidated review to: __REVIEW_FILE__

IMPORTANT: You MUST create the file __REVIEW_FILE__ with the full review.
