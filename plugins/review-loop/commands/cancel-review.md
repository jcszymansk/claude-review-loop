---
description: "Cancel an active review loop"
allowed-tools:
  - Bash(test -f .claude/review-loop.local.json *)
  - Bash(rm -f .claude/review-loop.local.json .claude/review-loop.lock .claude/review-loop-run-codex.sh .claude/review-loop-run-gemini.sh .claude/review-loop-run-cursor.sh .claude/review-loop-codex-prompt.txt .claude/review-loop-gemini-prompt.txt .claude/review-loop-cursor-prompt.txt .claude/review-loop-retries)
  - Read
---

Check if a review loop is active:

```bash
test -f .claude/review-loop.local.json && echo "ACTIVE" || echo "NONE"
```

If active, read `.claude/review-loop.local.json` to get the current phase and review ID.

Then remove the state file, lock file, and any generated reviewer files:

```bash
rm -f .claude/review-loop.local.json .claude/review-loop.lock .claude/review-loop-run-codex.sh .claude/review-loop-run-gemini.sh .claude/review-loop-run-cursor.sh .claude/review-loop-codex-prompt.txt .claude/review-loop-gemini-prompt.txt .claude/review-loop-cursor-prompt.txt .claude/review-loop-retries
```

Leave `reviews/<review_id>/` untouched. It contains the review history and must remain available after cancellation.

Report: "Review loop cancelled (was at phase: X, review ID: Y)"

If no review loop was active, report: "No active review loop found."
