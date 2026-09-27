---
description: "Cancel an active review loop"
allowed-tools:
  - Bash
  - Read
---

Run the cancellation helper:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/cancel-review-loop.sh" "${CLAUDE_SESSION_ID}"
```

The helper finds this session's review loop, in the current directory or in a
parent directory the loop was started from. It stops the active reviewer
process and its children, then removes the runtime state and generated
reviewer files, and reports the phase and review ID the loop was at.
Leave `reviews/<review_id>/` untouched. It contains the review history and
must remain available after cancellation.

Report the helper output. If no review loop was active, it reports:
"No active review loop found."
