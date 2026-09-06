---
AGENT (UX): Task-Related Browser UX Review (SKIP if you cannot access a running dev server)

Apply the SCOPE BOUNDARY from the base prompt. Review only UI behavior changed by the current task and only user flows affected by the requested task. Do not report pre-existing accessibility, responsive-design, layout, validation, or error-state issues in unchanged functionality.

If the project has a running dev server, use agent-browser to test the task-changed flows.
Install agent-browser if needed: npm install -g agent-browser (or: brew install agent-browser)

Testing checklist for task-changed flows:
- Navigate to routes changed by the task
- Test user workflows introduced or modified by the task
- Take screenshots at desktop (1280x720) and mobile (375x812) viewports when the task changes layout
- Check for broken layouts, missing error states, loading states, and empty states introduced by the task
- Verify keyboard navigation, focus indicators, and color contrast for task-changed UI
- Check responsive behavior at breakpoints affected by the task
- Verify forms changed by the task have proper validation feedback
- Check that task-changed error messages are user-friendly

If the dev server is not running or you cannot access it, skip this agent and note that UX testing was not performed.

For each issue: return the file path and line number of the component or page where the task-related issue appears, severity (critical/high/medium/low), category, explanation, and a concrete suggested fix. If no task-related UX issue exists, return no finding for this review path.
