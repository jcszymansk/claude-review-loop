---
description: "Cancel an active review loop"
allowed-tools:
  - Bash
  - Read
---

Check if a review loop is active:

```bash
test -f .claude/review-loop.local.json && echo "ACTIVE" || echo "NONE"
```

If active, read `.claude/review-loop.local.json` to get the current phase and review ID.

Then run the cancellation helper:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/cancel-review-loop.sh"
```

The helper stops the active reviewer process and its children, then removes the
runtime state and generated reviewer files.
Leave `reviews/<review_id>/` untouched. It contains the review history and
must remain available after cancellation.

Report the helper output. If no review loop was active, it reports:
"No active review loop found."

